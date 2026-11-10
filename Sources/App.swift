import SwiftUI
import AppKit
import ServiceManagement
import Combine
import UserNotifications
import DiskArbitration

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// One Tracker per log folder, so Lab and XT running together can't mix their lines.
final class LogSource {
    let follower: LogFollower
    let tracker = Tracker()
    var lastLookup: [String: Date] = [:]
    var lookedUpRecent: Set<String> = []

    init(folder: URL) { follower = LogFollower(folder: folder) }
}

/// Lists mounted volumes and works out their ticks. Only volumes Silverstack has on record as
/// a source are read, and only their file listing.
enum VolumeScanner {
    static func scan() -> [VolumeStatus] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeUUIDStringKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return mounted.filter { $0.path.hasPrefix("/Volumes/") && !isDiskImage($0) }.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let total = values.volumeTotalCapacity ?? 0
            let name = values.volumeName ?? url.lastPathComponent
            var status = VolumeStatus(path: url.path, name: name, key: values.volumeUUIDString ?? name,
                                      freeBytes: Double(values.volumeAvailableCapacity ?? 0), totalBytes: Double(total))
            if let record = ProjectDatabase.ingestRecord(label: status.name, capacity: Int64(total)) {
                let walk = AnySequence { files(in: url) }
                status.ingested = VolumeCheck.isIngested(record, files: walk)
                if status.ingested {
                    status.transcoded = VolumeCheck.isTranscoded(record, paths: walk.map(\.path))
                }
            }
            return status
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static let session = DASessionCreate(kCFAllocatorDefault)

    /// Mounted DMGs, like an installer, are never cards or backup drives.
    private static func isDiskImage(_ url: URL) -> Bool {
        guard let session, let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let description = DADiskCopyDescription(disk) as? [CFString: Any] else { return false }
        return description[kDADiskDescriptionDeviceModelKey] as? String == "Disk Image"
    }

    private static func files(in volume: URL) -> AnyIterator<(path: String, size: Double)> {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let walker = FileManager.default.enumerator(at: volume, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        let root = volume.resolvingSymlinksInPath().path
        return AnyIterator {
            while let file = walker?.nextObject() as? URL {
                guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                let path = String(file.resolvingSymlinksInPath().path.dropFirst(root.count))
                return (path, Double(values.fileSize ?? 0))
            }
            return nil
        }
    }
}

final class Store: ObservableObject {
    static let keepFinished: TimeInterval = 8
    static let silentAfter: TimeInterval = 20
    static let recentShown = 5
    static let settleDelay: TimeInterval = 5

    @Published var jobs: [Job] = []
    @Published var recentJobs: [Job] = []
    @Published var volumes: [VolumeStatus] = []
    @Published var hiddenVolumes = Set(UserDefaults.standard.stringArray(forKey: "hiddenVolumes") ?? [])
    @Published var isEditingVolumes = false
    @Published var demoJobs: [Job]?
    @Published var isHovering = false
    @Published var opensAtLogin = SMAppService.mainApp.status == .enabled
    @Published var now = Date()
    @Published var slow: [SlowCard] = []
    @Published var logProblem: String?

    private var sources: [LogSource] = []
    private var timer: Timer?
    private let silverstackBundles = "com.pomfort.Silverstack"
    private let scanQueue = DispatchQueue(label: "volume-scan")
    private var isScanning = false
    private var scanAgain = false
    private let speedWatch = SpeedWatch()
    private var notifiedSlow = Set<String>()
    private var seenFinished = Set<String>()

    var shown: [Job] { demoJobs ?? jobs }
    /// Finished jobs newest first, leaving out any still on show as a live row.
    var recent: [RecentRow] {
        let live = Set(shown.map(\.id))
        return Array(RecentRow.group(recentJobs.filter { !live.contains($0.id) }).prefix(Self.recentShown))
    }
    var running: [Job] { shown.filter { !$0.isWaiting } }
    var queued: [Job] { shown.filter(\.isWaiting) }
    var primary: Job? { running.first { !$0.state.isFinished } ?? queued.first ?? shown.last }

    func start() {
        findSources()
        // Common modes, so progress keeps moving while the menu bar menu is open.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refreshVolumes() }
        }
        refreshVolumes()
    }

    /// Looked for again while none is found, as Silverstack makes its log folder on first launch.
    private func findSources() {
        let root = Testing.logRoot ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        sources = folders.filter { $0.lastPathComponent.hasPrefix("Silverstack ") }.map(LogSource.init)
        for source in sources {
            source.follower.readRecent().forEach(source.tracker.ingest)
            source.tracker.pruneAfterScan(silverstackStarted: silverstackStarted)
        }
        // Only jobs ending from now on are announced.
        seenFinished.formUnion(sources.flatMap(\.tracker.recent).map(\.id))
    }

    func slowCard(_ job: Job) -> SlowCard? { slow.first { $0.jobID == job.id } }

    /// Runs one scan at a time, off the main thread, as cards can be slow to read.
    func refreshVolumes() {
        guard !isScanning else {
            scanAgain = true
            return
        }
        isScanning = true
        scanQueue.async { [weak self] in
            let found = VolumeScanner.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isScanning = false
                if found != self.volumes { self.volumes = found }
                if self.scanAgain {
                    self.scanAgain = false
                    self.refreshVolumes()
                }
            }
        }
    }

    private var silverstackIsRunning: Bool {
        if Testing.logRoot != nil { return true }
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier?.hasPrefix(silverstackBundles) == true
        }
    }

    /// The oldest running copy, so a job belonging to either of Lab and XT is kept.
    private var silverstackStarted: Date? {
        if Testing.logRoot != nil { return nil }
        return NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier?.hasPrefix(silverstackBundles) == true }
            .compactMap(\.launchDate).min()
    }

    private func tick() {
        // Nothing on screen needs the clock, so leave the view alone between jobs.
        if !shown.isEmpty || isHovering { now = Date() }
        let running = silverstackIsRunning
        if sources.isEmpty && running { findSources() }
        for source in sources {
            source.follower.readNew().forEach(source.tracker.ingest)
            // A job can't be progressing once the app has gone; a crash writes no end state.
            if !running { source.tracker.clear() }
            source.tracker.prune(now: Date(), finishedFor: Self.keepFinished)
            lookUpSizes(source)
        }
        let combined = sources.flatMap(\.tracker.jobs)
        if combined.map(\.signature) != jobs.map(\.signature) { jobs = combined }
        let prefs = Preferences.shared
        let nowSlow = speedWatch.update(jobs: combined, rules: prefs.rules, now: Date())
        if nowSlow != slow { slow = nowSlow }
        for card in nowSlow where notifiedSlow.insert(card.key).inserted && prefs.notifySlow {
            Notifier.post(id: "slow-\(card.key)", title: "Slow copy: \(card.card)",
                          body: "\(Int(card.speed)) MB/s, under the \(Int(card.minimum)) MB/s minimum for \(card.group.label.lowercased()).")
        }
        let problem: String? = !running ? nil
            : sources.isEmpty ? "Silverstack is running but its log folder can't be found"
            : sources.map(\.tracker.unrecognised).reduce(0, +) > 50 ? "Silverstack's log has changed: progress may be missing"
            : nil
        if problem != logProblem {
            logProblem = problem
            if let problem, prefs.notifyLogs { Notifier.post(id: "logs", title: "Backup Monitor can't follow Silverstack", body: problem) }
        }
        let finished = sources.flatMap(\.tracker.recent).sorted { $0.endedAt ?? .distantPast > $1.endedAt ?? .distantPast }
        if finished.map(\.signature) != recentJobs.map(\.signature) {
            for job in finished where seenFinished.insert(job.id).inserted && prefs.notifyJobs { announce(job) }
            recentJobs = finished
            refreshVolumes()
            // The log can get ahead of the database saving the job as finished.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in self?.refreshVolumes() }
        }
    }

    private func announce(_ job: Job) {
        let outcome = job.state == .succeeded ? "finished" : job.state == .failed ? "failed" : "stopped"
        Notifier.post(id: "end-\(job.id)", title: "\(job.kindLabel) \(outcome)", body: job.title, alarm: job.state != .succeeded)
    }

    private func lookUpSizes(_ source: LogSource) {
        for job in source.tracker.jobs where job.info == nil && !job.state.isFinished {
            guard now.timeIntervalSince(source.lastLookup[job.id] ?? .distantPast) >= 2,
                  let key = job.databaseKey else { continue }
            source.lastLookup[job.id] = now
            if let info = ProjectDatabase.info(store: key.store, row: key.row) {
                source.tracker.setInfo(info, forJob: job.id)
            }
        }
        // Jobs found by the startup scan finished before anything asked for their sizes.
        for job in source.tracker.recent where job.info == nil && !source.lookedUpRecent.contains(job.id) {
            source.lookedUpRecent.insert(job.id)
            if let key = job.databaseKey, let info = ProjectDatabase.info(store: key.store, row: key.row) {
                source.tracker.setInfo(info, forJob: job.id)
            }
        }
    }

    var visibleVolumes: [VolumeStatus] { volumes.visible(hidden: hiddenVolumes) }
    /// Every volume while choosing what to hide, otherwise only the ones left showing.
    var listedVolumes: [VolumeStatus] { isEditingVolumes ? volumes : visibleVolumes }

    func toggleHidden(_ volume: VolumeStatus) {
        if hiddenVolumes.remove(volume.key) == nil { hiddenVolumes.insert(volume.key) }
        UserDefaults.standard.set(hiddenVolumes.sorted(), forKey: "hiddenVolumes")
    }

    func toggleLogin() {
        do {
            if opensAtLogin { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            NSAlert(error: error).runModal()
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    func dismiss(_ job: Job) {
        sources.forEach { $0.tracker.dismiss(job.id) }
        demoJobs = nil
        tick()
    }

    func runDemo() {
        let started = Date()
        func job(_ fraction: Double) -> Job {
            var job = Job(id: "demo", url: "", kind: "Copy", workflow: "Demo Workflow",
                          startedAt: started.addingTimeInterval(-60), lastActivity: Date())
            job.info = JobInfo(title: "DEMO_REEL_A001", sizes: ["A001C007.MOV": 80e9], totalBytes: 80e9, totalTasks: 24)
            job.active = ["A001C007.MOV": fraction]
            job.phase = fraction < 0.6 ? "copy" : "verify"
            job.speed = fraction < 0.6 ? "466.6 MB/s" : "3.21 GB/s"
            job.currentFile = "A001C007.MOV"
            if fraction >= 1 {
                job.state = .succeeded
                job.endedAt = Date()
            }
            return job
        }
        var queued = Job(id: "demo-queued", url: "", kind: "Render", startedAt: started.addingTimeInterval(-60), lastActivity: Date())
        queued.info = JobInfo(title: "DEMO_REEL_A001", totalTasks: 24)
        var fraction = 0.0
        demoJobs = [job(0), queued]
        let demo = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            fraction = min(fraction + 0.01, 1)
            self.demoJobs = fraction < 1 ? [job(fraction), queued] : [job(fraction)]
            if fraction >= 1 {
                timer.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.demoJobs = nil }
            }
        }
        RunLoop.main.add(demo, forMode: .common)
    }
}

enum Notifier {
    static func post(id: String, title: String, body: String, alarm: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if alarm { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

extension Job {
    /// Enough to tell whether the island needs redrawing.
    var signature: String {
        "\(id)|\(state)|\(Int(lastActivity.timeIntervalSince1970 * 2))|\(info != nil)|\(errors)|\(isWaiting)"
    }
}

struct IslandMetrics {
    var notchWidth: CGFloat
    var height: CGFloat
    var earWidth: CGFloat = 64
    var expandedWidth: CGFloat = 460
    var collapsedWidth: CGFloat { notchWidth + earWidth * 2 }

    static func expandedHeight(running: Int, queued: Int, recent: Int, volumes: Int?, hovering: Bool, warning: Bool,
                               top: CGFloat) -> CGFloat {
        func list(_ rows: Int) -> CGFloat { rows > 0 ? 26 + CGFloat(rows) * 26 : 0 }
        let controls: CGFloat = hovering ? 34 + (warning ? 34 : 0) : 0
        let volumeHeight = volumes.map { 26 + CGFloat($0) * 26 } ?? 0
        return top + 8 + CGFloat(min(running, 3)) * 92 + list(queued) + list(recent) + volumeHeight + controls + 12
    }
}

/// The island's colours, and the menu's: the same rows show in both.
struct Palette {
    var text, detail, dim, faint, track, button: Color

    static let island = Palette(text: .white, detail: .white.opacity(0.72), dim: .white.opacity(0.6),
                                faint: .white.opacity(0.5), track: .white.opacity(0.18), button: .white.opacity(0.75))
    static let menu = Palette(text: .primary, detail: .secondary, dim: .secondary,
                              faint: Color(nsColor: .tertiaryLabelColor), track: .primary.opacity(0.12), button: .secondary)
}

struct IslandView: View {
    @ObservedObject var store: Store
    let metrics: IslandMetrics
    /// The job rows alone, for the menu bar menu.
    var inMenu = false
    private var palette: Palette { inMenu ? .menu : .island }

    private var expanded: Bool {
        store.isHovering || store.shown.contains { $0.state == .failed }
    }

    var body: some View {
        if inMenu { menuContent } else { island }
    }

    private var menuContent: some View {
        VStack(spacing: 8) {
            ForEach(store.running.prefix(3)) { row($0).frame(height: 84) }
            if !store.queued.isEmpty { queuedList }
            if !store.recent.isEmpty { recentList }
        }
        .foregroundColor(palette.text)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(width: 400)
    }

    private var island: some View {
        VStack(spacing: 0) {
            Group {
                if expanded { expandedContent } else { collapsedContent }
            }
            .frame(width: expanded ? metrics.expandedWidth : metrics.collapsedWidth, alignment: .top)
            .background(Color.black)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: expanded ? 22 : 12,
                                              bottomTrailingRadius: expanded ? 22 : 12))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .foregroundColor(.white)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: expanded)
    }

    private func tint(_ job: Job) -> Color {
        switch job.state {
        case .succeeded: return job.kind == "Render" ? .blue : .green
        case .failed: return .red
        case .paused, .cancelled: return .orange
        default:
            if isSilent(job) || job.errors > 0 || store.slowCard(job) != nil { return .orange }
            return job.phase == "verify" ? .cyan : .blue
        }
    }

    private func isSilent(_ job: Job) -> Bool {
        job.state == .running && !job.isWaiting && store.now.timeIntervalSince(job.lastActivity) >= Store.silentAfter
    }

    @ViewBuilder private var collapsedContent: some View {
        if let job = store.primary {
            HStack(spacing: 0) {
                ring(job, size: 20).frame(width: metrics.earWidth)
                Spacer(minLength: metrics.notchWidth)
                Text(shortStatus(job))
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(job.state == .running ? .white : tint(job))
                    .frame(width: metrics.earWidth)
            }
            .frame(height: metrics.height)
        }
    }

    private func shortStatus(_ job: Job) -> String {
        switch job.state {
        case .succeeded: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Stopped"
        case .paused: return "Paused"
        case _ where job.isWaiting: return "Queued"
        default: return job.fraction.map { "\(Format.percent($0))%" } ?? "…"
        }
    }

    private func ring(_ job: Job, size: CGFloat) -> some View {
        ZStack {
            Circle().stroke(palette.track, lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(job.fraction ?? 0))
                .stroke(tint(job), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if job.state == .succeeded {
                Image(systemName: "checkmark").font(.system(size: size * 0.45, weight: .bold)).foregroundColor(.green)
            }
            if job.state == .failed {
                Image(systemName: "exclamationmark").font(.system(size: size * 0.5, weight: .bold)).foregroundColor(.red)
            }
        }
        .frame(width: size, height: size)
    }

    private var expandedContent: some View {
        VStack(spacing: 8) {
            ForEach(store.running.prefix(3)) { row($0).frame(height: 84) }
            if !store.queued.isEmpty { queuedList }
            if store.isHovering {
                if let problem = store.logProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium)).foregroundColor(.orange)
                        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                }
                if !store.recent.isEmpty { recentList }
                if !store.volumes.isEmpty { volumeList }
                controls
            }
        }
        .padding(.top, metrics.height + 8)
        .padding(.bottom, 12)
        .padding(.horizontal, 18)
    }

    private var volumeList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Mounted volumes")
                Spacer()
                let hidden = store.volumes.count - store.visibleVolumes.count
                if hidden > 0 && !store.isEditingVolumes { Text("\(hidden) hidden") }
                Button(store.isEditingVolumes ? "Done" : "Edit") { store.isEditingVolumes.toggle() }
                    .buttonStyle(.plain)
                    .foregroundColor(.white.opacity(0.85))
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white.opacity(0.5))
            .frame(height: 18, alignment: .top)
            ForEach(store.listedVolumes) { volumeRow($0).frame(height: 26) }
        }
    }

    private func volumeRow(_ volume: VolumeStatus) -> some View {
        let isHidden = store.hiddenVolumes.contains(volume.key)
        return HStack(spacing: 8) {
            HStack(spacing: 3) {
                tick(.green, shown: volume.ingested)
                tick(.blue, shown: volume.transcoded)
            }
            Text(volume.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if store.isEditingVolumes {
                Button(isHidden ? "Show" : "Hide") { store.toggleHidden(volume) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
            } else {
                Text("\(Format.bytes(volume.freeBytes)) free").font(.system(size: 11.5).monospacedDigit())
                    .foregroundColor(.white.opacity(0.6)).lineLimit(1).fixedSize()
            }
        }
        .opacity(isHidden ? 0.45 : 1)
    }

    /// Keeps its slot when not shown, so volume names line up.
    private func tick(_ color: Color, shown: Bool) -> some View {
        Image(systemName: "checkmark.circle")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(color)
            .frame(width: 16)
            .opacity(shown ? 1 : 0)
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button("Settings…") { SettingsWindow.show(store: store) }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.white.opacity(0.75))
        .frame(height: 26)
    }

    private var queuedList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Queued")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(palette.faint)
                .frame(height: 18, alignment: .top)
            ForEach(store.queued) { queuedRow($0).frame(height: 26) }
        }
    }

    private func queuedRow(_ job: Job) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(palette.dim)
                .frame(width: 16)
            Text(job.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(queuedDetail(job)).font(.system(size: 11.5).monospacedDigit())
                .foregroundColor(palette.dim).lineLimit(1).fixedSize()
        }
    }

    private func queuedDetail(_ job: Job) -> String {
        var parts = [job.kindLabel]
        if let info = job.info {
            parts.append(job.showsBytes ? Format.bytes(info.totalBytes) : "\(info.totalTasks) files")
        }
        parts.append("waiting \(Format.duration(store.now.timeIntervalSince(job.startedAt)))")
        return parts.joined(separator: " · ")
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recently completed")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(palette.faint)
                .frame(height: 18, alignment: .top)
            ForEach(store.recent) { recentRow($0).frame(height: 26) }
        }
    }

    private func recentRow(_ row: RecentRow) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                if row.jobs[0].state == .failed || row.jobs[0].state == .cancelled {
                    Image(systemName: recentIcon(row.jobs[0]))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(tint(row.jobs[0]))
                        .frame(width: 16)
                    tick(.blue, shown: false)
                } else {
                    tick(.green, shown: row.hasGreenTick)
                    tick(.blue, shown: row.hasBlueTick)
                }
            }
            Text(row.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(recentDetail(row)).font(.system(size: 11.5).monospacedDigit())
                .foregroundColor(palette.dim).lineLimit(1).fixedSize()
        }
    }

    private func recentIcon(_ job: Job) -> String {
        switch job.state {
        case .failed: return "xmark.circle.fill"
        default: return "stop.circle.fill"
        }
    }

    private func recentDetail(_ row: RecentRow) -> String {
        let job = row.jobs[0]
        var parts = [row.hasGreenTick && row.hasBlueTick ? "Offload + Transcode" : job.kindLabel]
        if job.state == .failed { parts.append("Failed") }
        if job.state == .cancelled { parts.append("Stopped") }
        let sized = row.offload ?? job
        if job.state == .succeeded, let info = sized.info {
            parts.append(sized.showsBytes ? Format.bytes(info.totalBytes) : "\(info.totalTasks) files")
        }
        if let ended = job.endedAt { parts.append(Format.ago(store.now.timeIntervalSince(ended))) }
        return parts.joined(separator: " · ")
    }

    private func row(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(job.title).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if job.state == .failed {
                    Button("Dismiss") { store.dismiss(job) }.buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium)).foregroundColor(palette.button)
                }
                Text(shortStatus(job))
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(tint(job))
            }
            // Drawn by hand because the system bar turns grey in a window that isn't key.
            GeometryReader { bar in
                Capsule().fill(palette.track)
                    .overlay(alignment: .leading) {
                        Capsule().fill(tint(job)).frame(width: bar.size.width * CGFloat(job.fraction ?? 0))
                    }
            }
            .frame(height: 6)
            Text(detailLine(job)).font(.system(size: 11.5).monospacedDigit())
                .foregroundColor(palette.detail).lineLimit(1)
            Text(fileLine(job)).font(.system(size: 11.5))
                .foregroundColor(job.lastError == nil && store.slowCard(job) == nil ? palette.faint : .orange)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private func detailLine(_ job: Job) -> String {
        var parts = [job.phase.map { $0.capitalized } ?? job.kindLabel]
        if job.state == .finishing { parts = ["Finishing"] }
        if let info = job.info {
            if job.showsBytes && !job.state.isFinished {
                parts.append("\(Format.bytes(job.doneBytes)) of \(Format.bytes(info.totalBytes))")
            }
            parts.append("\(job.doneTasks)/\(info.totalTasks) files")
        }
        if job.state == .running, let speed = job.speed { parts.append(speed) }
        if let remaining = job.remaining(at: store.now) { parts.append("\(Format.duration(remaining)) left") }
        return parts.joined(separator: " · ")
    }

    private func fileLine(_ job: Job) -> String {
        if let error = job.lastError { return "\(job.errors) error\(job.errors == 1 ? "" : "s"): \(error)" }
        if let slow = store.slowCard(job) { return slow.text }
        if isSilent(job) {
            return "No update for \(Format.duration(store.now.timeIntervalSince(job.lastActivity)))"
        }
        return job.currentFile ?? ""
    }
}

/// Takes a click straight away, as this window never becomes key.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Stays above fullscreen apps and never takes focus away from Silverstack.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let store = Store()
    private let prefs = Preferences.shared
    private var prefsUpdates: Any?
    private var panel: IslandPanel!
    private var statusItem: NSStatusItem!
    private var metrics = IslandMetrics(notchWidth: 190, height: 37)
    private var refresh: Any?
    private var hoverTimer: Timer?
    private let menu = NSMenu()
    private static let idleIcon = NSImage(systemSymbolName: "externaldrive.badge.checkmark",
                                          accessibilityDescription: "Backup Monitor")

    func applicationDidFinishLaunching(_ notification: Notification) {
        metrics = Self.measure(Self.screen)
        setUpMainMenu()
        setUpMenu()
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.contentView = IslandHostingView(rootView: IslandView(store: store, metrics: metrics))

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        refresh = store.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                self?.layoutPanel()
                self?.updateStatusItem()
            }
        }
        prefsUpdates = prefs.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusItem.isVisible = self.prefs.showMenuBar
                self.layoutPanel()
                self.updateStatusItem()
            }
        }
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Updater.shared.start()
        store.start()
        layoutPanel()
        // Reads the cursor directly: a panel that never activates doesn't reliably get hover events.
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }
        if !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            SettingsWindow.show(store: store)
        }
    }

    /// Opening the app again from Finder is the way back in when its icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.show(store: store)
        return false
    }

    /// Shows banners even while the Settings window has the app in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// The notched display if there is one, otherwise the display with the menu bar.
    private static var screen: NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens[0]
    }

    private static func measure(_ screen: NSScreen) -> IslandMetrics {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            return IslandMetrics(notchWidth: 110, height: NSStatusBar.system.thickness + 6)
        }
        return IslandMetrics(notchWidth: screen.frame.width - left.width - right.width,
                             height: screen.safeAreaInsets.top)
    }

    @objc private func screensChanged() {
        metrics = Self.measure(Self.screen)
        panel.contentView = IslandHostingView(rootView: IslandView(store: store, metrics: metrics))
        layoutPanel()
    }

    private func updateHover() {
        guard prefs.showIsland else {
            if store.isHovering { store.isHovering = false }
            return
        }
        // While hidden the notch itself is the target, so the island can be opened between
        // jobs without menu bar items beside it setting it off. Grown slightly because the
        // cursor can rest on the very top edge of the screen.
        let target = panel.isVisible ? panel.frame : notchFrame
        let inside = target.insetBy(dx: 0, dy: -2).contains(NSEvent.mouseLocation)
        if inside && !store.isHovering { store.refreshVolumes() }
        if inside != store.isHovering { store.isHovering = inside }
        if !inside && store.isEditingVolumes { store.isEditingVolumes = false }
    }

    private var notchFrame: NSRect {
        topCentered(NSSize(width: metrics.notchWidth, height: metrics.height))
    }

    private func topCentered(_ size: NSSize) -> NSRect {
        let screen = Self.screen.frame
        return NSRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height,
                      width: size.width, height: size.height)
    }

    /// Sized to the island so the rest of the menu bar stays clickable.
    private func layoutPanel() {
        let jobs = store.shown
        let recent = store.isHovering ? store.recent.count : 0
        guard prefs.showIsland, !jobs.isEmpty || store.isHovering else {
            panel.orderOut(nil)
            return
        }
        let expanded = store.isHovering || jobs.contains { $0.state == .failed }
        let size = expanded
            ? NSSize(width: metrics.expandedWidth,
                     height: IslandMetrics.expandedHeight(running: store.running.count, queued: store.queued.count,
                                                          recent: recent,
                                                          volumes: store.isHovering && !store.volumes.isEmpty ? store.listedVolumes.count : nil,
                                                          hovering: store.isHovering, warning: store.logProblem != nil,
                                                          top: metrics.height))
            : NSSize(width: metrics.collapsedWidth, height: metrics.height)
        let frame = topCentered(size)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Shown while Settings or About is open. Without it the windows get no Cmd-W, and the text
    /// fields no Cmd-C, Cmd-V or Cmd-A.
    private func setUpMainMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        }
        func item(_ title: String, _ action: Selector?, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command,
                  target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            return item
        }
        submenu("Backup Monitor", [
            item("About Backup Monitor", #selector(showAbout), "", target: self),
            item("Settings…", #selector(showSettings), ",", target: self),
            .separator(),
            item("Hide Backup Monitor", #selector(NSApplication.hide), "h"),
            item("Quit Backup Monitor", #selector(NSApplication.terminate), "q"),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut), "x"),
            item("Copy", #selector(NSText.copy), "c"),
            item("Paste", #selector(NSText.paste), "v"),
            item("Select All", #selector(NSText.selectAll), "a"),
        ])
        submenu("Window", [
            item("Close", #selector(NSWindow.performClose), "w"),
            item("Minimize", #selector(NSWindow.performMiniaturize), "m"),
        ])
        NSApp.mainMenu = main
    }

    private func setUpMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        // With a fixed width, the wheel stays put and the numbers change beside it.
        statusItem.button?.alignment = .left
        statusItem.autosaveName = "BackupMonitor"
        statusItem.isVisible = prefs.showMenuBar
        updateStatusItem()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) { store.refreshVolumes() }

    /// Built just before the menu opens and never while it is open: removing items from an open
    /// menu leaves it at its old height, with a blank space at the bottom.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let update = Updater.shared.available {
            menu.addItem(withTitle: "Download Backup Monitor \(update.version)…", action: #selector(downloadUpdate), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        if let problem = store.logProblem {
            let warning = menu.addItem(withTitle: problem, action: nil, keyEquivalent: "")
            warning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
            warning.isEnabled = false
            menu.addItem(.separator())
        }
        // The island's job rows, live while the menu is open. Jobs starting meanwhile show at the next opening.
        if !store.shown.isEmpty || !store.recent.isEmpty {
            let rows = NSHostingView(rootView: IslandView(store: store, metrics: metrics, inMenu: true))
            rows.frame.size = rows.fittingSize
            let item = NSMenuItem()
            item.view = rows
            menu.addItem(item)
            menu.addItem(.separator())
        }
        let header = menu.addItem(withTitle: "Mounted Volumes", action: nil, keyEquivalent: "")
        header.isEnabled = false
        if store.visibleVolumes.isEmpty {
            menu.addItem(withTitle: "No volumes to show", action: nil, keyEquivalent: "").isEnabled = false
        }
        for volume in store.visibleVolumes { menu.addItem(item(for: volume)) }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "About Backup Monitor", action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Backup Monitor", action: #selector(NSApplication.terminate), keyEquivalent: "q")
    }

    private func item(for volume: VolumeStatus) -> NSMenuItem {
        let item = NSMenuItem(title: volume.name, action: #selector(reveal), keyEquivalent: "")
        item.target = self
        item.representedObject = volume.path
        item.image = Self.ticks(ingested: volume.ingested, transcoded: volume.transcoded)
        let title = NSMutableAttributedString(string: volume.name, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        title.append(NSAttributedString(string: "   \(Format.bytes(volume.freeBytes)) free", attributes: [
            .font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        item.attributedTitle = title
        if volume.transcoded {
            item.toolTip = "Ingest and transcoding complete"
        } else if volume.ingested {
            item.toolTip = "Ingest complete"
        }
        return item
    }

    /// Two fixed slots, so names line up whichever ticks a volume has.
    private static func ticks(ingested: Bool, transcoded: Bool) -> NSImage {
        let slot: CGFloat = 18
        return NSImage(size: NSSize(width: slot * 2, height: slot), flipped: false) { _ in
            for (index, color) in [(0, NSColor.systemGreen), (1, NSColor.systemBlue)] {
                guard index == 0 ? ingested : transcoded else { continue }
                let shape = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
                let tint = NSImage.SymbolConfiguration(paletteColors: [color])
                let symbol = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)?
                    .withSymbolConfiguration(shape.applying(tint))
                symbol?.draw(in: NSRect(x: CGFloat(index) * slot + 1, y: 1, width: slot - 2, height: slot - 2))
            }
            return true
        }
    }

    @objc private func reveal(_ item: NSMenuItem) {
        guard let path = item.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func showSettings() { SettingsWindow.show(store: store) }

    @objc private func showAbout() { About.show() }

    @objc private func downloadUpdate() { Updater.shared.download() }

    /// The drive icon between jobs, the chosen readouts while one runs.
    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let jobs = store.shown
        let text = MenuBarStatus.text(for: jobs, options: prefs.menuBarOptions, now: Date())
        let job = MenuBarStatus.active(jobs)
        let image = job != nil && prefs.menuBarOptions.contains(.wheel) ? Self.wheel(job?.fraction ?? 0) : Self.idleIcon
        let tint: NSColor? = store.slow.isEmpty ? nil : .systemOrange
        let length = job == nil ? NSStatusItem.variableLength : runningLength(button)
        if button.title != text || button.contentTintColor != tint {
            var attributes: [NSAttributedString.Key: Any] = [.font: Self.readoutFont]
            if let tint { attributes[.foregroundColor] = tint }
            button.attributedTitle = NSAttributedString(string: text, attributes: attributes)
            button.contentTintColor = tint
        }
        if button.image !== image { button.image = image }
        if length != targetLength { animateLength(to: length, button) }
    }

    private var targetLength: CGFloat?
    private var shownLength: CGFloat?
    private var lengthAnimation: Timer?

    /// Grows and shrinks over a quarter of a second instead of jumping, easing out.
    private func animateLength(to target: CGFloat, _ button: NSStatusBarButton) {
        targetLength = target
        lengthAnimation?.invalidate()
        // Between jobs the item sizes itself to the drive icon, which is also where a shrink ends.
        let end = target == NSStatusItem.variableLength ? ceil(button.intrinsicContentSize.width) : target
        guard let start = shownLength, abs(end - start) >= 1 else {
            statusItem.length = target
            shownLength = end
            return
        }
        let began = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                let progress = min(Date().timeIntervalSince(began) / 0.25, 1)
                let width = start + (end - start) * (1 - pow(1 - progress, 3))
                self.shownLength = width
                self.statusItem.length = progress < 1 ? width : target
                if progress >= 1 { timer.invalidate() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        lengthAnimation = timer
    }

    private static let readoutFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    private var measured: (options: MenuBarOptions, length: CGFloat)?

    /// One width for the whole job, so the icons beside it don't shift as the numbers change.
    private func runningLength(_ button: NSStatusBarButton) -> CGFloat {
        let options = prefs.menuBarOptions
        if let measured, measured.options == options { return measured.length }
        let title = button.attributedTitle, image = button.image
        button.image = options.contains(.wheel) ? Self.wheel(0) : Self.idleIcon
        let width = MenuBarStatus.widest(options: options).map { sample -> CGFloat in
            button.attributedTitle = NSAttributedString(string: sample, attributes: [.font: Self.readoutFont])
            return button.intrinsicContentSize.width
        }.max() ?? 0
        button.attributedTitle = title
        button.image = image
        let length = ceil(width) + 4
        measured = (options, length)
        return length
    }

    private static func wheel(_ fraction: Double) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let ring = rect.insetBy(dx: 2, dy: 2)
            NSColor.black.withAlphaComponent(0.25).setStroke()
            let track = NSBezierPath(ovalIn: ring)
            track.lineWidth = 2.5
            track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: ring.width / 2,
                          startAngle: 90, endAngle: 90 - 360 * CGFloat(fraction), clockwise: true)
            arc.lineWidth = 2.5
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "\(Format.percent(fraction))% done"
        return image
    }
}
