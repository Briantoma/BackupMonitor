import Foundation

enum JobState: Equatable {
    case running, paused, finishing, succeeded, failed, cancelled

    var isFinished: Bool { self == .succeeded || self == .failed || self == .cancelled }
}

/// The full size of a job, read once from the project database. The log only ever names the
/// first 20 tasks of a job, so it cannot provide this.
struct JobInfo: Equatable {
    var title: String
    var sizes: [String: Double]
    var totalBytes: Double
    var totalTasks: Int
    var alreadyDoneBytes: Double
    var alreadyDoneTasks: Int
    /// The volume each file is copied from, under both spellings like sizes.
    var sources: [String: String] = [:]
    private var counts: [String: Int] = [:]

    init(title: String = "", sizes: [String: Double] = [:], totalBytes: Double = 0, totalTasks: Int = 0,
         alreadyDoneBytes: Double = 0, alreadyDoneTasks: Int = 0) {
        self.title = title
        self.sizes = sizes
        self.totalBytes = totalBytes
        self.totalTasks = totalTasks
        self.alreadyDoneBytes = alreadyDoneBytes
        self.alreadyDoneTasks = alreadyDoneTasks
    }

    mutating func add(name: String, size: Double, isDone: Bool, source: String? = nil) {
        totalBytes += size
        totalTasks += 1
        if isDone {
            alreadyDoneBytes += size
            alreadyDoneTasks += 1
        }
        remember(name, size)
        let stem = (name as NSString).deletingPathExtension
        if stem != name { remember(stem, size) }
        if let source {
            sources[name] = source
            sources[stem] = source
        }
    }

    /// Averages repeated names: the log can't say which of them a line means, but the
    /// average still adds up to the right total once they have all finished.
    private mutating func remember(_ key: String, _ size: Double) {
        let count = counts[key, default: 0]
        sizes[key] = (sizes[key, default: 0] * Double(count) + size) / Double(count + 1)
        counts[key] = count + 1
    }

    /// The log gives some clips without their extension, as "D012C086_261030DU" for
    /// "D012C086_261030DU.MXF", so both spellings are kept.
    func size(of name: String) -> Double { sizes[name] ?? 0 }
}

struct Job: Identifiable {
    var id: String
    var url: String
    var kind: String
    var workflow: String?
    var info: JobInfo?
    var state = JobState.running
    var startedAt: Date
    var lastActivity: Date
    var endedAt: Date?
    var finishedNames: [String] = []
    var active: [String: Double] = [:]
    var phase: String?
    var speed: String?
    /// Latest copy-phase speed of each file in flight, in bytes per second.
    var copySpeeds: [String: (bytesPerSecond: Double, at: Date)] = [:]
    var filePhases: [String: String] = [:]
    var currentFile: String?
    var errors = 0
    var lastError: String?

    /// The Core Data store and row this job lives in: "x-coredata://STORE/CopyJob/p196".
    var databaseKey: (store: String, row: Int)? {
        let parts = url.replacingOccurrences(of: "x-coredata://", with: "").split(separator: "/")
        guard parts.count == 3, parts[2].hasPrefix("p"), let row = Int(parts[2].dropFirst()) else { return nil }
        return (String(parts[0]), row)
    }

    var title: String { info?.title ?? workflow ?? kindLabel }

    var kindLabel: String {
        switch kind {
        case "Copy": return "Offload"
        case "Render": return "Transcode"
        case "Verify": return "Verify"
        case "DailiesUpload": return "Upload"
        default: return kind
        }
    }

    var doneBytes: Double {
        guard let info else { return 0 }
        let finished = finishedNames.reduce(0.0) { $0 + info.size(of: $1) }
        let inFlight = active.reduce(0.0) { $0 + info.size(of: $1.key) * $1.value }
        return min(info.alreadyDoneBytes + finished + inFlight, info.totalBytes)
    }

    var doneTasks: Int {
        let done = (info?.alreadyDoneTasks ?? 0) + finishedNames.count
        return info.map { min(done, $0.totalTasks) } ?? done
    }

    /// A render task's size in the database is its frame count, which weights progress
    /// correctly but must never be displayed as bytes.
    var showsBytes: Bool { kind != "Render" && (info?.totalBytes ?? 0) > 0 }

    /// Started but nothing logged yet, like a transcode waiting for its offload to finish.
    /// Silverstack has no queued state of its own: jobs turn "started" within a second of
    /// being scheduled, then can sit for over half an hour before their first task.
    var isWaiting: Bool { state == .running && currentFile == nil }

    /// 0...1 across the whole job, or nil when the total is unknown. Stays nil rather than
    /// guessing: a wrong percentage on an offload is worse than none.
    var fraction: Double? {
        if state == .succeeded { return 1 }
        guard let info, info.totalTasks > 0 else { return nil }
        if info.totalBytes > 0 { return min(doneBytes / info.totalBytes, 1) }
        // Some jobs have no sizes in the database, so they count tasks instead.
        let inFlight = active.values.reduce(0, +)
        return min((Double(doneTasks) + inFlight) / Double(info.totalTasks), 1)
    }

    /// Needs a little history so the first small sidecar files don't produce a wild estimate.
    func remaining(at now: Date) -> TimeInterval? {
        guard state == .running, let fraction, fraction >= 0.02, fraction < 1 else { return nil }
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed >= 10 else { return nil }
        return elapsed * (1 - fraction) / fraction
    }
}

/// Follows Silverstack's log and turns it into jobs. Holds no AppKit so it can be tested on
/// recorded logs.
final class Tracker {
    private(set) var jobs: [Job] = []
    private(set) var recent: [Job] = []
    private static let recentLimit = 16
    private var pendingWorkflow: String?
    private var workflowNames: [String: String] = [:]
    private var declaredJobs: [String] = []
    /// Job lines this parser no longer understands: a sign Silverstack changed its log format.
    private(set) var unrecognised = 0

    private static let dates: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSZ"
        return formatter
    }()
    private static let transition = pattern(#"x-coredata://([^ ]*/(\w+)Job/[\w-]+) com\.pomfort\.workState\.(\w+) -> com\.pomfort\.workState\.(\w+)"#)
    private static let taskLine = pattern(#"(MSG|FIN|ERR): \w+TaskExecution <(.*?)>(?: |$)(.*)$"#)
    private static let progress = pattern(#"\[prog\s*\] (\d+)%"#)
    private static let speed = pattern(#"\[spd\s*\] ([\d.]+ \w+)"#)
    private static let exactSpeed = pattern(#"\(([\d,.]+) bytes\)/s"#)
    private static let phase = pattern(#"\[info\s*\] (\w+)"#)
    private static let errorText = pattern(#"Code=-?\d+ "(.*?)" UserInfo"#)
    private static let quoted = pattern(#""([^"]+)""#)

    private static func pattern(_ text: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: text)
    }

    private static func groups(_ regex: NSRegularExpression, _ text: String) -> [String]? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map {
            Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? ""
        }
    }

    func ingest(_ line: String) {
        if line.contains("<JBSTE>") { return handleTransition(line) }
        if line.contains("scheduling for workflow `") {
            pendingWorkflow = line.components(separatedBy: "`").dropFirst().first
            return
        }
        if line.contains("scheduled job(s) for workflow:") {
            let range = NSRange(line.startIndex..., in: line)
            for match in Self.quoted.matches(in: line, range: range) {
                if let id = Range(match.range(at: 1), in: line), let name = pendingWorkflow {
                    workflowNames[String(line[id])] = name
                }
            }
            return
        }
        guard let tag = Self.tag(in: line) else {
            if Self.isTaskMessage(line) { unrecognised += 1 }
            return
        }
        if line.contains("tasks will be executed in the following buckets") {
            declaredJobs.append(tag)
        } else if line.contains("TaskExecution <") {
            handleTask(line, jobID: tag)
        }
    }

    /// The job id from "<JBX:Z2z.dij>" or a task's own "<Z2z.dij.bN9>".
    private static func tag(in line: String) -> String? {
        guard line.count > 32, let open = line.firstIndex(of: "<"),
              let close = line[open...].firstIndex(of: ">") else { return nil }
        let tag = line[line.index(after: open)..<close]
        if tag.hasPrefix("JBX:") { return String(tag.dropFirst(4)) }
        let parts = tag.split(separator: ".")
        return parts.count == 3 ? "\(parts[0]).\(parts[1])" : nil
    }

    private static func date(_ line: String) -> Date? {
        guard line.count > 30 else { return nil }
        return dates.date(from: String(line.dropFirst(2).prefix(28)))
    }

    private static func isTaskMessage(_ line: String) -> Bool {
        line.contains("TaskExecution <") && (line.contains("MSG: ") || line.contains("FIN: ") || line.contains("ERR: "))
    }

    private func handleTransition(_ line: String) {
        guard let parts = Self.groups(Self.transition, line) else {
            if line.contains("state transition") { unrecognised += 1 }
            return
        }
        let url = "x-coredata://" + parts[1], kind = parts[2], from = parts[3], to = parts[4]
        let date = Self.date(line) ?? Date()

        if to == "started" && from == "scheduled" {
            let id = declaredJobs.isEmpty ? url : declaredJobs.removeFirst()
            jobs.removeAll { $0.url == url }
            recent.removeAll { $0.url == url }
            jobs.append(Job(id: id, url: url, kind: kind, workflow: workflowNames[id],
                            startedAt: date, lastActivity: date))
            return
        }
        guard let index = jobs.firstIndex(where: { $0.url == url }) else { return }
        jobs[index].lastActivity = date
        switch to {
        case "started": jobs[index].state = .running
        case "willSuspend", "suspended": jobs[index].state = .paused
        case "execCompl": jobs[index].state = .finishing
        case "finishedSuccessfully": finish(index, .succeeded, date)
        case "finishedUnsuccessfully": finish(index, .failed, date)
        case "aborted": finish(index, .cancelled, date)
        default: break
        }
    }

    private func finish(_ index: Int, _ state: JobState, _ date: Date) {
        jobs[index].state = state
        jobs[index].endedAt = date
        jobs[index].active = [:]
        recent.insert(jobs[index], at: 0)
        recent = Array(recent.prefix(Self.recentLimit))
    }

    private func handleTask(_ line: String, jobID: String) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard let parts = Self.groups(Self.taskLine, line) else {
            if Self.isTaskMessage(line) { unrecognised += 1 }
            return
        }
        let verb = parts[1], name = parts[2], rest = parts[3]
        let date = Self.date(line)
        if let date { jobs[index].lastActivity = date }
        if verb != "MSG" {
            jobs[index].copySpeeds[name] = nil
            jobs[index].filePhases[name] = nil
        }

        switch verb {
        case "FIN":
            jobs[index].active[name] = nil
            jobs[index].finishedNames.append(name)
        case "ERR":
            jobs[index].active[name] = nil
            jobs[index].errors += 1
            jobs[index].lastError = Self.groups(Self.errorText, rest)?[1]
        default:
            jobs[index].currentFile = name
            // Threads log independently, so a progress line can arrive after its file's FIN.
            if let percent = Self.groups(Self.progress, rest).flatMap({ Double($0[1]) }),
               !jobs[index].finishedNames.contains(name) {
                jobs[index].active[name] = percent / 100
            }
            if let phase = Self.groups(Self.phase, rest)?[1] {
                jobs[index].phase = phase
                jobs[index].filePhases[name] = phase
            }
            if let speed = Self.groups(Self.speed, rest)?[1] {
                jobs[index].speed = speed.hasSuffix("FPS") ? speed : speed + "/s"
            }
            if jobs[index].filePhases[name] == "copy", let date,
               let exact = Self.groups(Self.exactSpeed, rest).flatMap({ Double($0[1].replacingOccurrences(of: ",", with: "")) }) {
                jobs[index].copySpeeds[name] = (exact, date)
            }
        }
    }

    func setInfo(_ info: JobInfo, forJob id: String) {
        if let index = recent.firstIndex(where: { $0.id == id }) { recent[index].info = info }
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        // The database already marks tasks finished in this run as done; those are counted
        // from the log, so only tasks done by an earlier attempt stay in the "already" figures.
        var info = info
        let names = jobs[index].finishedNames
        info.alreadyDoneBytes = max(0, info.alreadyDoneBytes - names.reduce(0.0) { $0 + info.size(of: $1) })
        info.alreadyDoneTasks = max(0, info.alreadyDoneTasks - names.count)
        jobs[index].info = info
    }

    /// Removes finished jobs once they have been on show for a while. Failures stay.
    func prune(now: Date, finishedFor keep: TimeInterval) {
        jobs.removeAll { job in
            guard job.state != .failed, let ended = job.endedAt else { return false }
            return now.timeIntervalSince(ended) >= keep
        }
    }

    /// After reading old logs: anything finished is history, and a job from before this run of
    /// Silverstack was cut off by a crash or quit. Silence proves nothing, as a queued job
    /// can wait a long time without logging.
    func pruneAfterScan(silverstackStarted: Date?) {
        jobs.removeAll { job in
            if job.state.isFinished { return true }
            if let silverstackStarted { return job.startedAt < silverstackStarted }
            return false
        }
    }

    func dismiss(_ id: String) { jobs.removeAll { $0.id == id } }
    func clear() { jobs.removeAll() }
}

struct VolumeStatus: Identifiable, Equatable {
    var id: String { path }
    var path: String
    var name: String
    /// Remembers a volume between mounts. The disk UUID rather than the name, so hiding one
    /// "Untitled" card can't hide every other card that happens to share the name.
    var key: String
    var freeBytes: Double
    var totalBytes: Double
    var ingested = false
    var transcoded = false
}

/// One line of the recent list. A reel's offload and transcode share a line, so its two
/// ticks sit side by side. Anything that went wrong keeps a line of its own.
struct RecentRow: Identifiable {
    var jobs: [Job]

    var id: String { jobs[0].id }
    var title: String { jobs[0].title }
    var hasGreenTick: Bool { jobs.contains { $0.state == .succeeded && $0.kind != "Render" } }
    var hasBlueTick: Bool { jobs.contains { $0.state == .succeeded && $0.kind == "Render" } }
    var offload: Job? { jobs.first { $0.kind == "Copy" } }

    private static func canShare(_ job: Job) -> Bool {
        job.state == .succeeded && (job.kind == "Copy" || job.kind == "Render")
    }

    /// Keeps the order given, so a reel sits where its newest job would.
    static func group(_ jobs: [Job]) -> [RecentRow] {
        var rows: [RecentRow] = []
        for job in jobs {
            if canShare(job), let index = rows.firstIndex(where: { canShare($0.jobs[0]) && $0.title == job.title }) {
                rows[index].jobs.append(job)
            } else {
                rows.append(RecentRow(jobs: [job]))
            }
        }
        return rows
    }
}

extension Array where Element == VolumeStatus {
    func visible(hidden: Set<String>) -> [VolumeStatus] { filter { !hidden.contains($0.key) } }
}

/// What Silverstack has on record for a card: files from successful copy jobs, and the
/// transcodes that belong to those jobs.
struct IngestRecord: Equatable {
    var copied: [String: Double] = [:]
    var rendered: Set<String> = []
    var renderPending = false
}

/// Decides the volume ticks. A green tick reads as "safe to format", and Silverstack can't
/// tell apart two cards with the same name and size, so the files actually on the card are
/// what count: one that Silverstack didn't copy, at that path and size, means no tick.
enum VolumeCheck {
    private static let clipExtensions: Set<String> = ["mov", "mp4", "mxf", "r3d", "braw", "ari", "arx", "mts"]
    private static let sequence = try! NSRegularExpression(pattern: #"^(.*?)(\d+)-(\d+)(#+)(\.[^.]*)?$"#)

    /// Silverstack records a numbered run of files as one task, like "C0012T1-1##.JPG" for
    /// "C0012T01.JPG", with the size of the whole run.
    private static func expand(_ path: String) -> [String]? {
        let range = NSRange(path.startIndex..., in: path)
        guard path.contains("#"), let match = sequence.firstMatch(in: path, range: range) else { return nil }
        func group(_ index: Int) -> String { Range(match.range(at: index), in: path).map { String(path[$0]) } ?? "" }
        guard let first = Int(group(2)), let last = Int(group(3)), first <= last, last - first < 100_000 else { return nil }
        let width = group(4).count
        return (first...last).map {
            let digits = String($0)
            return group(1) + String(repeating: "0", count: max(0, width - digits.count)) + digits + group(5)
        }
    }

    /// Files are checked as they are read so a large drive can stop at the first mismatch.
    /// Pass paths relative to the volume, starting with "/".
    static func isIngested(_ record: IngestRecord, files: AnySequence<(path: String, size: Double)>) -> Bool {
        var runs: [String: String] = [:]
        var runSizes: [String: Double] = [:]
        for (path, size) in record.copied {
            guard let names = expand(path) else { continue }
            names.forEach { runs[$0] = path }
            runSizes[path] = size
        }
        var sawFile = false
        var found: [String: Double] = [:]
        for file in files {
            sawFile = true
            if let run = runs[file.path] {
                found[run, default: 0] += file.size
            } else if record.copied[file.path] != file.size {
                return false
            }
        }
        return sawFile && found.allSatisfy { runSizes[$0.key] == $0.value }
    }

    static func isTranscoded(_ record: IngestRecord, paths: [String]) -> Bool {
        guard !record.rendered.isEmpty, !record.renderPending else { return false }
        let done = Set(record.rendered.map { stem($0) })
        return paths.filter(isClip).allSatisfy { done.contains(stem($0)) }
    }

    private static func isClip(_ path: String) -> Bool {
        clipExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    private static func stem(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
    }
}

enum Format {
    static func bytes(_ value: Double) -> String {
        if value >= 1e12 { return String(format: "%.2f TB", value / 1e12) }
        if value >= 1e9 { return String(format: "%.1f GB", value / 1e9) }
        return String(format: "%.0f MB", value / 1e6)
    }

    static func ago(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds) / 60)m ago" }
        if seconds < 86400 { return "\(Int(seconds) / 3600)h ago" }
        return "\(Int(seconds) / 86400)d ago"
    }

    /// Rounds down, so nothing shows 100% until Silverstack reports the job finished.
    static func percent(_ fraction: Double) -> Int { min(Int(fraction * 100), 99) }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \(total % 3600 / 60)m"
    }
}

/// What the menu bar item shows while a job runs, picked in its menu.
struct MenuBarOptions: OptionSet {
    let rawValue: Int
    static let percent = MenuBarOptions(rawValue: 1 << 0)
    static let remaining = MenuBarOptions(rawValue: 1 << 1)
    static let jobCount = MenuBarOptions(rawValue: 1 << 2)
    static let wheel = MenuBarOptions(rawValue: 1 << 3)
    static let speed = MenuBarOptions(rawValue: 1 << 4)
}

enum MenuBarStatus {
    /// The job the menu bar follows: the first one actually copying or rendering.
    static func active(_ jobs: [Job]) -> Job? { jobs.first { !$0.state.isFinished && !$0.isWaiting } }

    static func text(for jobs: [Job], options: MenuBarOptions, now: Date) -> String {
        guard let job = active(jobs) else { return "" }
        var parts: [String] = []
        if options.contains(.percent), let fraction = job.fraction { parts.append("\(Format.percent(fraction))%") }
        if options.contains(.speed), job.state == .running, let speed = job.speed { parts.append(speed) }
        if options.contains(.remaining), let remaining = job.remaining(at: now) { parts.append(Format.duration(remaining)) }
        if options.contains(.jobCount) {
            let count = jobs.filter { !$0.state.isFinished }.count
            parts.append("\(count) job\(count == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }
}

enum CardGroup: String, CaseIterable {
    case camera, audio, other

    var label: String {
        switch self {
        case .camera: return "Camera cards"
        case .audio: return "Audio cards"
        case .other: return "Other sources"
        }
    }
}

/// Which camera letters belong to which group, and each group's minimum copy speed in MB/s.
struct CardRules: Equatable {
    var letters: [CardGroup: String]
    var minimum: [CardGroup: Double]

    static let standard = CardRules(letters: [.camera: "ABCDEFGH", .audio: "S"],
                                    minimum: [.camera: 500, .audio: 40, .other: 150])

    /// The camera letter is the first letter of a reel-style name: A015CAZH, D902_261103, E004.
    /// Anything else (SSD_01, DJI, A6MT3_20TB) is another source.
    func group(of volume: String) -> CardGroup {
        let start = Array(volume.prefix(4))
        guard start.count == 4, start[0].isASCII, start[0].isLetter,
              start.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) else { return .other }
        let letter = start[0].uppercased()
        if letters[.camera, default: ""].contains(letter) { return .camera }
        if letters[.audio, default: ""].contains(letter) { return .audio }
        return .other
    }

    /// Keeps letters only, upper case, once, and takes them away from the other group.
    mutating func setLetters(_ text: String, for group: CardGroup) {
        var seen = Set<Character>()
        let clean = String(text.uppercased().filter { $0.isASCII && $0.isLetter && seen.insert($0).inserted })
        letters[group] = clean
        for other in [CardGroup.camera, .audio] where other != group {
            letters[other] = letters[other, default: ""].filter { !clean.contains($0) }
        }
    }
}

struct SlowCard: Equatable {
    var jobID: String
    var card: String
    var group: CardGroup
    var speed: Double
    var minimum: Double

    var key: String { "\(jobID)|\(card)" }
    var text: String { "Slow: \(Int(speed)) MB/s (min \(Int(minimum))) · \(card)" }
}

/// Averages each card's copy speed over the last 30 seconds, so a dip at the start of a clip
/// or on a small sidecar file never warns.
final class SpeedWatch {
    static let window: TimeInterval = 30
    static let fresh: TimeInterval = 2
    private var samples: [String: [(at: Date, mbps: Double)]] = [:]

    func update(jobs: [Job], rules: CardRules, now: Date) -> [SlowCard] {
        var slow: [SlowCard] = []
        var live = Set<String>()
        for job in jobs where !job.state.isFinished {
            guard let info = job.info else { continue }
            // Files copying from the same card add up, as Silverstack can read several at once.
            var perCard: [String: Double] = [:]
            for (name, sample) in job.copySpeeds where now.timeIntervalSince(sample.at) <= Self.fresh {
                guard let card = info.sources[name] else { continue }
                perCard[card, default: 0] += sample.bytesPerSecond / 1e6
            }
            for (card, mbps) in perCard {
                let key = "\(job.id)|\(card)"
                live.insert(key)
                var history = samples[key, default: []].filter { now.timeIntervalSince($0.at) <= Self.window }
                history.append((now, mbps))
                samples[key] = history
                let average = history.map(\.mbps).reduce(0, +) / Double(history.count)
                let group = rules.group(of: card)
                let minimum = rules.minimum[group] ?? 0
                guard let first = history.first, now.timeIntervalSince(first.at) >= Self.window * 0.8,
                      average < minimum else { continue }
                slow.append(SlowCard(jobID: job.id, card: card, group: group, speed: average, minimum: minimum))
            }
        }
        samples = samples.filter { live.contains($0.key) }
        return slow.sorted { $0.key < $1.key }
    }
}
