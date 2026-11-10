import AppKit
import Security

/// Installs a release in place of the running app. Nothing is touched until the new app has been
/// checked: Backup Monitor's bundle ID, a newer version, signed by Oz Color's Developer ID and
/// accepted by Gatekeeper, which includes Apple's notarisation. Then a small helper waits for this
/// app to quit, swaps the two copies (putting the old one back if that fails) and opens the new one.
enum UpdateInstaller {
    static let team = "8HMFSMY38P"

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Not run from a disk image or a temporary copy macOS made, and in a folder the app may write to.
    static var canReplaceSelf: Bool {
        let app = Bundle.main.bundleURL
        return !app.path.contains("/AppTranslocation/") && !app.path.hasPrefix("/Volumes/")
            && FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
    }

    /// Returns once the helper is waiting; the caller then quits.
    static func install(from dmg: URL, newerThan current: String) async throws {
        let (download, response) = try await URLSession.shared.download(from: dmg)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Failure("the download failed") }
        try await Task.detached { try stageAndSwap(download, newerThan: current) }.value
    }

    private static func stageAndSwap(_ download: URL, newerThan current: String) throws {
        let files = FileManager.default
        let work = files.temporaryDirectory.appendingPathComponent("BackupMonitorUpdate-\(UUID().uuidString)")
        let image = work.appendingPathComponent("update.dmg"), mount = work.appendingPathComponent("mount")
        try files.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: work) }
        try files.moveItem(at: download, to: image)
        try run("/usr/bin/hdiutil", "attach", image.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path)
        defer { try? run("/usr/bin/hdiutil", "detach", mount.path, "-force") }

        let candidates = (try? files.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []
        guard let app = candidates.first(where: { Bundle(url: $0)?.bundleIdentifier == Bundle.main.bundleIdentifier }) else {
            throw Failure("the download doesn't contain Backup Monitor")
        }
        let version = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        guard Updater.isNewer(version, than: current) else { throw Failure("the download isn't a newer version") }
        try verify(app)
        try run("/usr/sbin/spctl", "--assess", "--type", "execute", app.path)

        // Copied next to the app first, so the swap itself is a quick rename on the same disk.
        let destination = Bundle.main.bundleURL
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).update")
        try? files.removeItem(at: staged)
        try run("/usr/bin/ditto", app.path, staged.path)
        try verify(staged)

        let script = """
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
            rm -rf "$1.old"
            if mv "$1" "$1.old"; then
              if mv "$2" "$1"; then rm -rf "$1.old"; else mv "$1.old" "$1"; fi
            fi
            open "$1"
            """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "sh", destination.path, staged.path]
        try helper.run()
    }

    /// Signed by Oz Color, intact, for every architecture.
    private static func verify(_ app: URL) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let rule = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(rule, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate),
                                         requirement) == errSecSuccess else {
            throw Failure("the new version isn't signed by Oz Color")
        }
    }

    private static func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(tool.hasSuffix("spctl") ? "macOS didn't accept the new version" : "\(URL(fileURLWithPath: tool).lastPathComponent) failed")
        }
    }
}
