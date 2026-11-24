import SwiftUI
import AppKit

/// Everything chosen in Settings, saved in UserDefaults.
final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    @Published var showIsland: Bool { didSet { defaults.set(showIsland, forKey: "showIsland") } }
    @Published var showMenuBar: Bool { didSet { defaults.set(showMenuBar, forKey: "showMenuBar") } }
    @Published var menuBarOptions: MenuBarOptions { didSet { defaults.set(menuBarOptions.rawValue, forKey: "menuBarOptions") } }
    /// The slow copy warning as a whole: the notification, and the orange in the menu bar and island.
    @Published var notifySlow: Bool { didSet { defaults.set(notifySlow, forKey: "notifySlow") } }
    @Published var notifyJobs: Bool { didSet { defaults.set(notifyJobs, forKey: "notifyJobs") } }
    @Published var notifyLogs: Bool { didSet { defaults.set(notifyLogs, forKey: "notifyLogs") } }
    /// How often speed and time left change on screen, in seconds.
    @Published var refreshInterval: Double { didSet { defaults.set(refreshInterval, forKey: "refreshInterval") } }
    /// The speed shown while several jobs move bytes at once.
    @Published var speedMode: SpeedMode { didSet { defaults.set(speedMode.rawValue, forKey: "speedMode") } }
    /// Mounted volumes in the island and the menu.
    @Published var showVolumes: Bool { didSet { defaults.set(showVolumes, forKey: "showVolumes") } }
    /// Two items per side of the closed island: on the left from the outer edge in, on the right from the notch out.
    @Published var notchLeft: [NotchItem] { didSet { defaults.set(notchLeft.map(\.rawValue).joined(separator: ","), forKey: "notchLeft") } }
    @Published var notchRight: [NotchItem] { didSet { defaults.set(notchRight.map(\.rawValue).joined(separator: ","), forKey: "notchRight") } }
    /// Past jobs in the island and the menu, and how many.
    @Published var showPastJobs: Bool { didSet { defaults.set(showPastJobs, forKey: "showPastJobs") } }
    @Published var pastJobs: PastJobsShown { didSet { defaults.set(pastJobs.rawValue, forKey: "pastJobs") } }
    /// How long the pointer must rest on the notch before the island opens, in seconds.
    @Published var hoverDelay: Double { didSet { defaults.set(hoverDelay, forKey: "hoverDelay") } }
    @Published var rules: CardRules {
        didSet {
            defaults.set(Dictionary(uniqueKeysWithValues: rules.entries.map { ($0.key.rawValue, $0.value) }), forKey: "cardEntries")
            defaults.set(Dictionary(uniqueKeysWithValues: rules.minimum.map { ($0.key.rawValue, $0.value) }), forKey: "cardMinimum")
        }
    }

    private init() {
        // Without a notch the island would hang over the menu bar, so only the icon starts on there.
        let hasNotch = NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
        let defaults = UserDefaults.standard
        func flag(_ key: String, _ standard: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? standard }
        showIsland = flag("showIsland", hasNotch)
        showMenuBar = flag("showMenuBar", true)
        menuBarOptions = MenuBarOptions(rawValue: defaults.object(forKey: "menuBarOptions") as? Int
                                        ?? MenuBarOptions([.percent, .wheel]).rawValue)
        notifySlow = flag("notifySlow", true)
        notifyJobs = flag("notifyJobs", false)
        notifyLogs = flag("notifyLogs", false)
        refreshInterval = defaults.object(forKey: "refreshInterval") as? Double ?? 5
        speedMode = SpeedMode(rawValue: defaults.string(forKey: "speedMode") ?? "") ?? .total
        showVolumes = flag("showVolumes", true)
        showPastJobs = flag("showPastJobs", true)
        pastJobs = PastJobsShown(rawValue: defaults.string(forKey: "pastJobs") ?? "") ?? .last5
        hoverDelay = defaults.object(forKey: "hoverDelay") as? Double ?? 0
        notchLeft = NotchItem.list(defaults.string(forKey: "notchLeft"), [.ring, .none])
        notchRight = NotchItem.list(defaults.string(forKey: "notchRight"), [.percent, .none])
        var rules = CardRules.standard
        for (key, value) in defaults.dictionary(forKey: "cardEntries") as? [String: [String]] ?? [:] {
            if let group = CardGroup(rawValue: key) { rules.entries[group] = value }
        }
        for (key, value) in defaults.dictionary(forKey: "cardMinimum") as? [String: Double] ?? [:] {
            if let group = CardGroup(rawValue: key) { rules.minimum[group] = value }
        }
        self.rules = rules
    }
}

enum SettingsWindow {
    private static var window: NSWindow?

    /// The window changes height as sections fold; its title bar stays where it is, and it moves up
    /// only as far as needed to stay on screen.
    private static func keepTop(of window: NSWindow) {
        var top = window.frame.maxY
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { _ in
            top = window.frame.maxY
        }
        center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { _ in
            var origin = NSPoint(x: window.frame.minX, y: top - window.frame.height)
            if let screen = window.screen?.visibleFrame, origin.y < screen.minY {
                origin.y = min(screen.minY, screen.maxY - window.frame.height)
            }
            if origin != window.frame.origin { window.setFrameOrigin(origin) }
        }
    }

    static func show(store: Store) {
        if window == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Backup Monitor Settings"
            window.isReleasedWhenClosed = false
            let content = NSHostingController(rootView: SettingsView(store: store))
            // Follows the volume list as cards are mounted and ejected.
            content.sizingOptions = .preferredContentSize
            window.contentViewController = content
            window.setContentSize(content.view.fittingSize)
            window.center()
            keepTop(of: window)
            DockPresence.track(window)
            // A click anywhere outside the field being edited ends the edit, as in System Settings.
            NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                if event.window === window, let editor = window.firstResponder as? NSText,
                   let field = editor.delegate as? NSView,
                   !field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
                    window.makeFirstResponder(nil)
                }
                return event
            }
            self.window = window
        }
        DockPresence.show()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil)
    }
}

/// Puts the app in the Dock and Cmd-Tab while one of its windows is open, and takes it out again
/// when the last one closes.
enum DockPresence {
    static func show() {
        // An app that starts without a Dock icon can show a blank one once it gains it, so it is set by hand.
        if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:)) {
            NSApp.applicationIconImage = icon
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func track(_ window: NSWindow) {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            DispatchQueue.main.async {
                if !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }
}

/// A field that can be cleared and retyped freely: what's typed is only read and kept when
/// editing ends, so a half-typed number or list is never reformatted under the cursor.
struct CommitField: View {
    let value: String
    var prompt = ""
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(prompt))
            .labelsHidden()
            .focused($focused)
            .onAppear { text = value }
            .onChange(of: value) { if !focused { text = $0 } }
            .onChange(of: focused) { if !$0 { finish() } }
            .onSubmit(finish)
    }

    private func finish() {
        commit(text)
        // Shows the cleaned-up value, or the old one when what was typed made no sense.
        DispatchQueue.main.async { text = value }
    }
}

struct SettingsView: View {
    @ObservedObject var store: Store
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var updater = Updater.shared
    /// The Menu bar and Island sections fold shut to keep the window short.
    @AppStorage("settings.menuBarOpen") private var menuBarOpen = false
    @AppStorage("settings.islandOpen") private var islandOpen = false
    @AppStorage("settings.slowCopyOpen") private var slowCopyOpen = false
    @AppStorage("settings.hiddenVolumesOpen") private var hiddenVolumesOpen = false

    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }

    /// Measured on a copy laid out at full height, so the window fits its open sections exactly.
    @State private var contentHeight: CGFloat = 600
    private var maxHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 900) - 40 }

    var body: some View {
        form
            // Taller than the screen, as with every section open on a 1080p display, it scrolls.
            .frame(width: 440, height: min(contentHeight, maxHeight))
            .background(alignment: .top) {
                // Inert: never focused, clicked or read out, only laid out.
                form.fixedSize(horizontal: false, vertical: true).frame(width: 440)
                    .disabled(true).allowsHitTesting(false).accessibilityHidden(true).hidden()
                    .background(GeometryReader { Color.clear.preference(key: FormHeight.self, value: $0.size.height) })
            }
            .onPreferenceChange(FormHeight.self) { height in
                if abs(height - contentHeight) > 0.5 { contentHeight = height }
            }
            .onAppear {
                updater.checkIfStale()
                store.refreshVolumes()
            }
    }

    private var form: some View {
        Form {
            Section("Show") {
                Picker("Update speed and time left every", selection: $prefs.refreshInterval) {
                    ForEach([1.0, 2, 5, 10], id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                HStack(spacing: 4) {
                    Text("Speed with several jobs")
                    InfoButton("For the menu bar and the closed island while several offloads or verifies run at once. Copies and verifies are counted apart: the menu bar shows both, the island the kind of the job it follows. Each row in the open island keeps its own speed.")
                    Spacer()
                    Picker("", selection: $prefs.speedMode) {
                        ForEach(SpeedMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                HStack {
                    Toggle("Show past jobs", isOn: $prefs.showPastJobs)
                    Spacer()
                    Picker("", selection: $prefs.pastJobs) {
                        ForEach(PastJobsShown.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .disabled(!prefs.showPastJobs)
                }
                Toggle("Notify when a job finishes, fails or stops", isOn: $prefs.notifyJobs)
                Toggle("Notify when Silverstack's logs can't be read", isOn: $prefs.notifyLogs)
            }
            Section {
                Fold(title: "Menu bar", open: $menuBarOpen,
                     info: "What the menu bar icon shows during a job. With nothing chosen, the drive icon itself takes the job's colour. If it would be hidden by the notch or a full menu bar, it leaves out the number of jobs, then the wheel, the percentage and the speed.",
                     detail: prefs.showMenuBar ? nil : "Off")
                // Only the settings grey out when the icon is off, so the section still folds.
                if menuBarOpen {
                    Toggle("Show in the menu bar", isOn: showMenuBar)
                    Group {
                        MenuBarPreview(options: prefs.menuBarOptions)
                        HStack {
                            option("Percentage", .percent, help: "Percentage done")
                            option("Speed", .speed, help: "Copy, verify or render speed")
                            option("Time left", .remaining, help: "Time remaining")
                            option("Jobs", .jobCount, help: "Number of jobs")
                            option("Wheel", .wheel, help: "Progress wheel")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(!prefs.showMenuBar)
                }
            }
            Section {
                Fold(title: "Island", open: $islandOpen,
                     info: "Up to two items per side, for the first running job. On the left they read from the outer edge in, on the right from the notch out. Without a notch both sides sit next to each other.",
                     detail: prefs.showIsland ? nil : "Off")
                if islandOpen {
                    Toggle("Show at the top of the screen", isOn: showIsland)
                    Group {
                        NotchPreview(left: prefs.notchLeft, right: prefs.notchRight, hasNotch: hasNotch)
                        side(hasNotch ? "Left of the notch" : "Left", \.notchLeft)
                        side(hasNotch ? "Right of the notch" : "Right", \.notchRight)
                        Picker("Open when the pointer rests on it for", selection: $prefs.hoverDelay) {
                            Text("No delay").tag(0.0)
                            ForEach([0.1, 0.3, 0.5, 1], id: \.self) { Text("\($0.formatted()) s").tag($0) }
                        }
                    }
                    .disabled(!prefs.showIsland)
                }
            }
            Section {
                Fold(title: "Slow copy warning", open: $slowCopyOpen, info: "Separate entries with commas. A single letter is a camera letter, the first letter of names like A015CAZH or D902_261103; anything longer matches the start of a card name. Warns once a card's real copy speed, from file sizes and copy times, is under its minimum: a notification, and the job in orange in the menu bar and the island. Switched off, there is neither.",
                     isOn: $prefs.notifySlow)
                if slowCopyOpen {
                    ForEach(CardGroup.allCases, id: \.self) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(group == .other ? group.label : "\(group.label) starting with:")
                                Spacer()
                                if group == .other {
                                    Text("Everything else").foregroundStyle(.secondary)
                                }
                            }
                            if group != .other {
                                CommitField(value: prefs.rules.text(for: group), prompt: "Letters or card names, e.g. A, B, CANTAR_SD") {
                                    prefs.rules.setEntries($0, for: group)
                                }
                                .textFieldStyle(.roundedBorder)
                            }
                            HStack {
                                Slider(value: minimum(group), in: 10...2000)
                                CommitField(value: String(Int(prefs.rules.minimum[group] ?? 0))) { typed in
                                    if let number = Double(typed.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) {
                                        prefs.rules.minimum[group] = min(max(number.rounded(), 10), 2000)
                                    }
                                }
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 64).multilineTextAlignment(.trailing)
                                Text("MB/s").foregroundStyle(.secondary)
                            }
                        }
                        .disabled(!prefs.notifySlow)
                    }
                }
            }
            Section {
                let hidden = store.volumes.filter { store.hiddenVolumes.contains($0.key) }.count
                Fold(title: "Volumes", open: $hiddenVolumesOpen,
                     info: "The mounted volumes in the island and the menu, with their free space and ticks for ingest and transcode. Below, switch on the ones to hide, such as master drives. Disk images are never shown.",
                     detail: !prefs.showVolumes ? "Not shown" : hidden > 0 ? "\(hidden) hidden" : nil)
                if hiddenVolumesOpen {
                    Toggle("Show in the island and the menu", isOn: $prefs.showVolumes)
                    Group {
                        Text("Hide").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        if store.volumes.isEmpty {
                            Text("No volumes mounted").foregroundStyle(.secondary)
                        }
                        ForEach(store.volumes) { volume in
                            Toggle(volume.name, isOn: Binding(get: { store.hiddenVolumes.contains(volume.key) },
                                                              set: { _ in store.toggleHidden(volume) }))
                        }
                    }
                    .disabled(!prefs.showVolumes)
                }
            }
            Section {
                if let problem = updater.installProblem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
                Toggle("Open at Login", isOn: Binding(get: { store.opensAtLogin }, set: { _ in store.toggleLogin() }))
                HStack {
                    if let update = updater.available {
                        Text("Version \(update.version) is available")
                        Spacer()
                        if updater.canInstall {
                            Button(updater.installing ? "Installing…" : "Install and Relaunch") { updater.install() }
                                .disabled(updater.installing)
                        }
                        Button("Download") { updater.download() }
                    } else {
                        Text("Version \(version) · \(updater.result ?? "Checking…")").foregroundStyle(.secondary)
                        Spacer()
                        Button("Check for Updates") { Task { await updater.check() } }
                            .disabled(updater.result == nil)
                    }
                }
                HStack {
                    Spacer()
                    Button("Show Demo") { store.runDemo() }
                    Button("About") { About.show() }
                }
            }
        }
        .formStyle(.grouped)
    }

    // The last of the two can't be turned off, or nothing would be left to reach Settings: it
    // beeps and stays on, rather than looking greyed out.
    private var showIsland: Binding<Bool> {
        Binding(get: { prefs.showIsland }, set: { on in
            if on || prefs.showMenuBar { prefs.showIsland = on } else { NSSound.beep() }
        })
    }

    private var showMenuBar: Binding<Bool> {
        Binding(get: { prefs.showMenuBar }, set: { on in
            if on || prefs.showIsland { prefs.showMenuBar = on } else { NSSound.beep() }
        })
    }

    private var hasNotch: Bool { NSScreen.screens.contains { $0.safeAreaInsets.top > 0 } }

    private func side(_ title: String, _ items: ReferenceWritableKeyPath<Preferences, [NotchItem]>) -> some View {
        HStack {
            Text(title)
            Spacer()
            ForEach(0..<2, id: \.self) { index in
                Picker("", selection: Binding(get: { prefs[keyPath: items][index] },
                                              set: { prefs[keyPath: items][index] = $0 })) {
                    ForEach(NotchItem.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
        }
    }

    private func option(_ title: String, _ option: MenuBarOptions, help: String) -> some View {
        Toggle(title, isOn: Binding(get: { prefs.menuBarOptions.contains(option) },
                                    set: { on in
                                        if on { prefs.menuBarOptions.insert(option) } else { prefs.menuBarOptions.remove(option) }
                                    }))
            .toggleStyle(.button).help(help)
    }

    private func minimum(_ group: CardGroup) -> Binding<Double> {
        Binding(get: { prefs.rules.minimum[group] ?? 0 },
                // Steps of 10 on the slider; drawn without step ticks, which crowd a 10...2000 range.
                set: { prefs.rules.minimum[group] = min(max(($0 / 10).rounded() * 10, 10), 2000) })
    }
}

private struct FormHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The first row of a section that folds open and shut, with a chevron like a disclosure group.
struct Fold: View {
    let title: String
    @Binding var open: Bool
    let info: String
    /// Grey text on the right, such as how many volumes are hidden.
    var detail: String? = nil
    /// A switch on the right that turns the whole section on or off.
    var isOn: Binding<Bool>? = nil

    var body: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 12)
                    Text(title).fontWeight(.semibold)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            InfoButton(info)
            Spacer()
            if let detail { Text(detail).foregroundStyle(.secondary) }
            if let isOn { Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small) }
        }
    }
}

/// The closed island as set, with sample figures, shrunk to fit when both sides are full.
struct NotchPreview: View {
    let left: [NotchItem]
    let right: [NotchItem]
    let hasNotch: Bool
    private static let texts: [NotchItem: String] = [.percent: "42%", .remaining: "1m 05s", .speed: "466.6 MB/s", .jobCount: "2 jobs"]

    var body: some View {
        let metrics = IslandMetrics(notchWidth: 90, height: 32, hasNotch: hasNotch, left: left, right: right)
        let scale = min(1, 380 / max(metrics.collapsedWidth, 1))
        HStack(spacing: 0) {
            NotchSide(items: left, texts: Self.texts, color: .white, leading: true) { ring }
                .frame(width: metrics.leftWidth, alignment: .leading)
            // The notch itself, outlined so it shows against the black island.
            RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3]))
                .frame(width: metrics.gap, height: 24).opacity(hasNotch ? 1 : 0)
            NotchSide(items: right, texts: Self.texts, color: .white, leading: false) { ring }
                .frame(width: metrics.rightWidth, alignment: .trailing)
        }
        .frame(height: metrics.height)
        .background(Color.black)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
        .scaleEffect(scale)
        .frame(maxWidth: .infinity)
        .frame(height: 40)
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: 3)
            Circle().trim(from: 0, to: 0.42).stroke(.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}


/// The menu bar pill as set, drawn by the pill's own code with sample figures.
struct MenuBarPreview: View {
    let options: MenuBarOptions

    var body: some View {
        Group {
            if text.isEmpty && !options.contains(.wheel) {
                Image(systemName: "externaldrive.badge.checkmark").font(.system(size: 15))
            } else {
                Image(nsImage: PillPicture.still(text: text, fraction: 0.42, wheel: options.contains(.wheel)))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 40)
    }

    private var text: String {
        var job = Job(id: "preview", url: "", kind: "Copy", startedAt: Date(), lastActivity: Date())
        job.info = JobInfo(title: "A001", totalBytes: 100, totalTasks: 2, alreadyDoneBytes: 42)
        job.currentFile = "A001C001.MOV"
        let queued = Job(id: "queued", url: "", kind: "Render", startedAt: Date(), lastActivity: Date())
        return MenuBarStatus.text(for: [job, queued], options: options,
                                  readouts: ["preview": Readout(speed: "466.6 MB/s", remaining: "1m 05s")])
    }
}
