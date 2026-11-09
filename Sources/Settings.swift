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
                // The last of the two can't be turned off, or nothing would be left to reach Settings.
                Toggle("Island at the top of the screen", isOn: $prefs.showIsland).disabled(prefs.showIsland && !prefs.showMenuBar)
                Toggle("Menu bar icon", isOn: $prefs.showMenuBar).disabled(prefs.showMenuBar && !prefs.showIsland)
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
            }
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
                Toggle("Open at Login", isOn: Binding(get: { store.opensAtLogin }, set: { _ in store.toggleLogin() }))
                HStack {
                    if let update = updater.available {
                        Text("Version \(update.version) is available")
                        Spacer()
                        Button("Download") { updater.download() }
                    } else {
                        Text("Version \(version)").foregroundStyle(.secondary)
                        Spacer()
                    }
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
