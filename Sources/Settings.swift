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
            defaults.set(Dictionary(uniqueKeysWithValues: rules.letters.map { ($0.key.rawValue, $0.value) }), forKey: "cardLetters")
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
        for (key, value) in defaults.dictionary(forKey: "cardLetters") as? [String: String] ?? [:] {
            if let group = CardGroup(rawValue: key) { rules.letters[group] = value }
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

/// A number field that can be cleared and retyped: the value is only checked and kept when
/// editing ends, so a half-typed number is never snapped to the limits.
struct SpeedField: View {
    @Binding var value: Double
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .labelsHidden()
            .focused($focused)
            .onAppear { text = Self.format(value) }
            .onChange(of: value) { if !focused { text = Self.format($0) } }
            .onChange(of: focused) { if !$0 { commit() } }
            .onSubmit(commit)
    }

    private func commit() {
        if let number = Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) {
            value = number
        }
        text = Self.format(value)
    }

    private static func format(_ value: Double) -> String { String(Int(value)) }
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
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(group.label)
                            Spacer()
                            if group == .other {
                                Text("Other letters and drives").foregroundStyle(.secondary)
                            } else {
                                TextField("Letters", text: letters(group), prompt: Text("Letters"))
                                    .labelsHidden().frame(width: 150).multilineTextAlignment(.trailing)
                            }
                        }
                        HStack {
                            Slider(value: minimum(group), in: 10...2000, step: 10)
                            SpeedField(value: minimum(group))
                                .frame(width: 60).multilineTextAlignment(.trailing)
                            Text("MB/s").foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Slow copy warning")
            } footer: {
                Text("A card's group is its camera letter, the first letter of names like A015CAZH or D902_261103. Warns when a card copies under its minimum for 30 seconds.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if store.volumes.isEmpty {
                    Text("No volumes mounted").foregroundStyle(.secondary)
                }
                ForEach(store.volumes) { volume in
                    Toggle(volume.name, isOn: Binding(get: { !store.hiddenVolumes.contains(volume.key) },
                                                      set: { _ in store.toggleHidden(volume) }))
                }
            } header: {
                Text("Mounted volumes")
            } footer: {
                Text("Unchecked volumes, such as master drives, are hidden from the island and the menu. Disk images are never listed.")
                    .font(.caption).foregroundStyle(.secondary)
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

    private func letters(_ group: CardGroup) -> Binding<String> {
        Binding(get: { prefs.rules.letters[group] ?? "" }, set: { prefs.rules.setLetters($0, for: group) })
    }

    private func minimum(_ group: CardGroup) -> Binding<Double> {
        Binding(get: { prefs.rules.minimum[group] ?? 0 },
                set: { prefs.rules.minimum[group] = min(max($0.rounded(), 10), 2000) })
    }
}
