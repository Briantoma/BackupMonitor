import AppKit
import UserNotifications

/// Asks GitHub for the latest release once a day, and when Settings opens (at most hourly).
/// A newer version shows in Settings and the menu, with one notification per version, and can be
/// installed in place, with a browser download when that isn't possible.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let latestRelease = URL(string: "https://api.github.com/repos/Briantoma/BackupMonitor/releases/latest")!

    struct Release: Equatable {
        let version: String
        let download: URL
    }

    @Published private(set) var available: Release?
    /// The outcome of the last check, shown in Settings: nil while checking or before the first one.
    @Published private(set) var result: String?
    @Published private(set) var installing = false
    @Published private(set) var installProblem: String?
    var canInstall: Bool { UpdateInstaller.canReplaceSelf }
    private var lastCheck = Date.distantPast
    private var timer: Timer?

    private var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.check() }
        }
        Task { await check() }
    }

    func checkIfStale() {
        if Date().timeIntervalSince(lastCheck) > 3600 { Task { await check() } }
    }

    func check() async {
        lastCheck = Date()
        result = nil
        var request = URLRequest(url: Self.latestRelease)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("BackupMonitor", forHTTPHeaderField: "User-Agent")
        // Offline, rate-limited or no release yet: try again at the next check.
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = Self.parse(data) else {
            result = "Couldn't check for updates"
            return
        }
        available = Self.isNewer(release.version, than: current) ? release : nil
        result = available == nil ? "Up to date" : nil
        if let available { notifyOnce(available) }
    }

    /// Downloads, checks and swaps in the new version, then quits so the helper can open it.
    func install() {
        guard let release = available, !installing else { return }
        guard canInstall else { return download() }
        installing = true
        installProblem = nil
        Task {
            do {
                try await UpdateInstaller.install(from: release.download, newerThan: current)
                NSApp.terminate(nil)
            } catch {
                installing = false
                installProblem = "Couldn't install: \(error.localizedDescription). Use Download instead."
            }
        }
    }

    /// The browser downloads the DMG, so macOS checks the notarized app when it is first opened.
    func download() {
        if let url = available?.download { NSWorkspace.shared.open(url) }
    }

    /// Version and DMG link of a GitHub "latest release" answer (the release page if it has no DMG).
    nonisolated static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let dmg = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }?["browser_download_url"] as? String
        guard let link = dmg ?? json["html_url"] as? String, let url = URL(string: link) else { return nil }
        return Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), download: url)
    }

    /// Compares numerically: 1.10 is newer than 1.9.
    nonisolated static func isNewer(_ version: String, than other: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = other.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func notifyOnce(_ release: Release) {
        guard UserDefaults.standard.string(forKey: "notifiedUpdate") != release.version else { return }
        UserDefaults.standard.set(release.version, forKey: "notifiedUpdate")
        let content = UNMutableNotificationContent()
        content.title = "Backup Monitor \(release.version) is available"
        content.body = "Open Backup Monitor Settings or its menu to install it."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "update-\(release.version)", content: content, trigger: nil))
    }
}
