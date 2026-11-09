import Foundation

/// Follows the newest log in one Silverstack log folder, carrying across rotations. Silverstack
/// starts a new file about every 3 MB, which can land in the middle of a job.
final class LogFollower {
    let folder: URL
    private var path: String?
    private var offset: UInt64 = 0
    private var partial = Data()
    private var newest: URL?
    private var readsSinceListing = 0
    private static let readsPerListing = 10

    init(folder: URL) { self.folder = folder }

    private func logsOldestFirst() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let names = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
        }
        return names
            .filter { $0.lastPathComponent.hasPrefix("com.pomfort.Silverstack") && $0.pathExtension == "log" }
            .sorted { modified($0) < modified($1) }
    }

    /// Starts two files back so a job that began before the last rotation is still found.
    func readRecent() -> [String] {
        var lines: [String] = []
        for log in logsOldestFirst().suffix(2) { lines += read(log) }
        return lines
    }

    func readNew() -> [String] {
        // Listing the folder is the costly part and rotations are rare.
        readsSinceListing += 1
        if newest == nil || readsSinceListing >= Self.readsPerListing {
            newest = logsOldestFirst().last
            readsSinceListing = 0
        }
        guard let newest else { return [] }
        var lines: [String] = []
        if let path, path != newest.path { lines += read(URL(fileURLWithPath: path)) }
        return lines + read(newest)
    }

    private func read(_ url: URL) -> [String] {
        if path != url.path {
            path = url.path
            offset = 0
            partial = Data()
        }
        guard let file = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? file.close() }
        guard (try? file.seek(toOffset: offset)) != nil, let data = try? file.readToEnd(), !data.isEmpty else { return [] }
        offset += UInt64(data.count)
        partial.append(data)
        guard let end = partial.lastIndex(of: 10) else { return [] }
        let complete = partial[partial.startIndex...end]
        partial = Data(partial[partial.index(after: end)...])
        return String(decoding: complete, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}
