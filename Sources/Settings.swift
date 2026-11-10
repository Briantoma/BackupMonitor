import SwiftUI
import AppKit

/// Everything chosen in Settings, saved in UserDefaults.
final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    @Published var showIsland: Bool { didSet { defaults.set(showIsland, forKey: "showIsland") } }
    @Published var showMenuBar: Bool { didSet { defaults.set(showMenuBar, forKey: "showMenuBar") } }
    @Published var menuBarOptions: MenuBarOptions { didSet { defaults.set(menuBarOptions.rawValue, forKey: "menuBarOptions") } }
    @Published var notifySlow: Bool { didSet { defaults.set(notifySlow, forKey: "notifySlow") } }
    @Published var notifyJobs: Bool { didSet { defaults.set(notifyJobs, forKey: "notifyJobs") } }
    @Published var notifyLogs: Bool { didSet { defaults.set(notifyLogs, forKey: "notifyLogs") } }
    /// How often speed and time left change on screen, in seconds.
    @Published var refreshInterval: Double { didSet { defaults.set(refreshInterval, forKey: "refreshInterval") } }
    /// Two items per side of the closed island: on the left from the outer edge in, on the right from the notch out.
    @Published var notchLeft: [NotchItem] { didSet { defaults.set(notchLeft.map(\.rawValue).joined(separator: ","), forKey: "notchLeft") } }
    @Published var notchRight: [NotchItem] { didSet { defaults.set(notchRight.map(\.rawValue).joined(separator: ","), forKey: "notchRight") } }
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

    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }

    var body: some View {
        Form {
            Section("Show") {
                // The last of the two can't be turned off, or nothing would be left to reach Settings: it
                // beeps and stays on, rather than looking greyed out.
                Toggle("Island at the top of the screen", isOn: Binding(get: { prefs.showIsland }, set: { on in
                    if on || prefs.showMenuBar { prefs.showIsland = on } else { NSSound.beep() }
                }))
                Toggle("Menu bar icon", isOn: Binding(get: { prefs.showMenuBar }, set: { on in
                    if on || prefs.showIsland { prefs.showMenuBar = on } else { NSSound.beep() }
                }))
                VStack(alignment: .leading, spacing: 8) {
                    Text("Menu bar shows")
                    HStack {
                        option("Percentage", .percent, help: "Percentage done")
                        option("Speed", .speed, help: "Copy, verify or render speed")
                        option("Time left", .remaining, help: "Time remaining")
                        option("Jobs", .jobCount, help: "Number of jobs")
                        option("Wheel", .wheel, help: "Progress wheel")
                    }
                }
                .disabled(!prefs.showMenuBar)
                Picker("Update speed and time left every", selection: $prefs.refreshInterval) {
                    ForEach([1.0, 2, 5, 10], id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
            }
            Section {
                NotchPreview(left: prefs.notchLeft, right: prefs.notchRight, hasNotch: hasNotch)
                side(hasNotch ? "Left of the notch" : "Left", \.notchLeft)
                side(hasNotch ? "Right of the notch" : "Right", \.notchRight)
            } header: {
                HStack(spacing: 4) {
                    Text("Island")
                    InfoButton("Up to two items per side, for the first running job. On the left they read from the outer edge in, on the right from the notch out. Without a notch both sides sit next to each other.")
                }
            }
            .disabled(!prefs.showIsland)
            Section {
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
                }
            } header: {
                HStack(spacing: 4) {
                    Text("Slow copy warning")
                    InfoButton("Separate entries with commas. A single letter is a camera letter, the first letter of names like A015CAZH or D902_261103; anything longer matches the start of a card name. Warns once a card's real copy speed, from file sizes and copy times, is under its minimum.")
                }
            }
            Section {
                if store.volumes.isEmpty {
                    Text("No volumes mounted").foregroundStyle(.secondary)
                }
                ForEach(store.volumes) { volume in
                    Toggle(volume.name, isOn: Binding(get: { store.hiddenVolumes.contains(volume.key) },
                                                      set: { _ in store.toggleHidden(volume) }))
                }
            } header: {
                HStack(spacing: 4) {
                    Text("Hidden volumes")
                    InfoButton("Switch on the volumes to hide from the island and the menu, such as master drives. Lists the mounted volumes; disk images are never shown.")
                }
            }
            Section("Notifications") {
                Toggle("Slow copy", isOn: $prefs.notifySlow)
                Toggle("Job finished, failed or stopped", isOn: $prefs.notifyJobs)
                Toggle("Silverstack's logs can't be read", isOn: $prefs.notifyLogs)
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
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            updater.checkIfStale()
            store.refreshVolumes()
        }
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
