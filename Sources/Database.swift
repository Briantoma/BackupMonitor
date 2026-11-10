import Foundation
import SQLite3

/// Points the app at recorded logs and a copy of a project, for replaying a job.
enum Testing {
    static let logRoot = folder("MONITOR_LOG_ROOT")
    static let dataRoot = folder("MONITOR_DATA_ROOT")

    private static func folder(_ name: String) -> URL? {
        ProcessInfo.processInfo.environment[name].map { URL(fileURLWithPath: $0) }
    }
}

/// Reads a job's task list from the Silverstack project database. Opens the file read-only,
/// once per job, and never writes to it.
enum ProjectDatabase {
    private static let finishedStatus = 65
    private static let endedStatuses: Set<Int> = [65, 577, 578]
    private static let projectsChecked = 3

    static func info(store: String, row: Int) -> JobInfo? {
        for path in projectPaths() {
            guard let database = open(path) else { continue }
            defer { sqlite3_close(database) }
            guard storeID(database) == store else { continue }
            return read(database, row: row)
        }
        return nil
    }

    /// Everything recorded for volumes with this name and size, across the recent projects.
    /// Several cards can share both, so the caller still has to compare the actual files.
    static func ingestRecord(label: String, capacity: Int64) -> IngestRecord? {
        var record = IngestRecord()
        var found = false
        for path in projectPaths().prefix(projectsChecked) {
            guard let database = open(path) else { continue }
            defer { sqlite3_close(database) }
            found = readIngest(database, label: label, capacity: capacity, into: &record) || found
        }
        return found ? record : nil
    }

    private static func readIngest(_ database: OpaquePointer, label: String, capacity: Int64,
                                   into record: inout IngestRecord) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let copies = """
            select r.ZRELATIVEPATH, r.ZFILESIZE, j.ZSOURCEFOLDER, j.ZWORKFLOW
            from ZACTIVITYTASK t
            join \(resourceTable(database)) r on r.Z_PK = t.ZSOURCERESOURCE
            join ZVOLUME v on v.Z_PK = r.ZVOLUME
            join ZACTIVITYJOB j on j.Z_PK = t.ZJOB
            where t.Z_ENT = (select Z_ENT from Z_PRIMARYKEY where Z_NAME = 'CopyTask')
              and t.ZEXECUTIONSTATUS = ? and j.ZEXECUTIONSTATUS = ?
              and v.ZLABEL = ? and v.ZTOTALCAPACITY = ?
            """
        guard sqlite3_prepare_v2(database, copies, -1, &statement, nil) == SQLITE_OK else { return false }
        sqlite3_bind_int(statement, 1, Int32(finishedStatus))
        sqlite3_bind_int(statement, 2, Int32(finishedStatus))
        sqlite3_bind_text(statement, 3, label, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(statement, 4, capacity)

        var folders: Set<Int64> = []
        var workflows: Set<Int64> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let path = text(statement, 0) { record.copied[path] = sqlite3_column_double(statement, 1) }
            if sqlite3_column_type(statement, 2) != SQLITE_NULL { folders.insert(sqlite3_column_int64(statement, 2)) }
            if sqlite3_column_type(statement, 3) != SQLITE_NULL { workflows.insert(sqlite3_column_int64(statement, 3)) }
        }
        guard !folders.isEmpty || !workflows.isEmpty else { return !record.copied.isEmpty }
        readRenders(database, folders: folders, workflows: workflows, into: &record)
        return true
    }

    private static func readRenders(_ database: OpaquePointer, folders: Set<Int64>, workflows: Set<Int64>,
                                    into record: inout IngestRecord) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        func list(_ values: Set<Int64>) -> String { values.map(String.init).joined(separator: ",") }
        let query = """
            select t.ZNAME, t.ZEXECUTIONSTATUS, j.ZEXECUTIONSTATUS
            from ZACTIVITYTASK t join ZACTIVITYJOB j on j.Z_PK = t.ZJOB
            where t.Z_ENT = (select Z_ENT from Z_PRIMARYKEY where Z_NAME = 'RenderTask')
              and (j.ZSOURCEFOLDER in (\(list(folders))) or j.ZWORKFLOW in (\(list(workflows))))
            """
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return }
        while sqlite3_step(statement) == SQLITE_ROW {
            let task = Int(sqlite3_column_int(statement, 1)), job = Int(sqlite3_column_int(statement, 2))
            if task == finishedStatus && job == finishedStatus, let name = text(statement, 0) {
                record.rendered.insert(name)
            } else if !endedStatuses.contains(job) {
                record.renderPending = true
            }
        }
    }

    /// Most recently used project first, so the usual lookup opens a single file.
    private static func projectPaths() -> [String] {
        let files = FileManager.default
        let root = Testing.dataRoot ?? files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Pomfort")
        let apps = (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let databases = apps.filter { $0.lastPathComponent.hasPrefix("Silverstack") }.flatMap { app in
            ((try? files.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("Project-") }
                .map { $0.appendingPathComponent("Silverstack.psdb") }
        }
        func used(_ url: URL) -> Date {
            let log = URL(fileURLWithPath: url.path + "-wal")
            return (try? log.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return databases.sorted { used($0) > used($1) }.map(\.path)
    }

    private static func open(_ path: String) -> OpaquePointer? {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil)
        guard result == SQLITE_OK else {
            sqlite3_close(database)
            return nil
        }
        sqlite3_busy_timeout(database, 200)
        return database
    }

    private static func storeID(_ database: OpaquePointer) -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "select Z_UUID from Z_METADATA", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, 0)
    }

    private static func read(_ database: OpaquePointer, row: Int) -> JobInfo? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let resources = resourceTable(database)
        let query = """
            select t.ZNAME, t.ZSIZE, t.ZEXECUTIONSTATUS, j.ZNAME, v.ZLABEL
            from ZACTIVITYTASK t join ZACTIVITYJOB j on j.Z_PK = t.ZJOB
            left join \(resources) r on r.Z_PK = t.ZSOURCERESOURCE
            left join ZVOLUME v on v.Z_PK = r.ZVOLUME
            where t.ZJOB = ?
            """
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int64(statement, 1, Int64(row))

        var info = JobInfo()
        while sqlite3_step(statement) == SQLITE_ROW {
            info.title = text(statement, 3) ?? info.title
            info.add(name: text(statement, 0) ?? "", size: sqlite3_column_double(statement, 1),
                     isDone: Int(sqlite3_column_int(statement, 2)) == finishedStatus, source: text(statement, 4))
        }
        info.verified = verifiedVolumes(database, row: row, resources: resources)
        return info.totalTasks > 0 ? info : nil
    }

    /// Silverstack 9 keeps files in ZVIDEORESOURCE, Lab 8 in ZFILERESOURCE.
    private static func resourceTable(_ database: OpaquePointer) -> String {
        names(database, "select name from sqlite_master where type = 'table' and name = 'ZVIDEORESOURCE'").isEmpty
            ? "ZFILERESOURCE" : "ZVIDEORESOURCE"
    }

    /// The volumes a verify job reads back. The link table is numbered by entity, which differs
    /// between Silverstack versions (Z_17VERIFYRESOURCES in XT 9, Z_20VERIFYRESOURCES in Lab 8).
    private static func verifiedVolumes(_ database: OpaquePointer, row: Int, resources: String) -> [String] {
        let query = "select name from sqlite_master where type = 'table' and name like 'Z\\_%VERIFYRESOURCES' escape '\\'"
        guard let link = names(database, query).first else { return [] }
        let columns = names(database, "select name from pragma_table_info('\(link)')")
        guard let task = columns.first(where: { $0.hasSuffix("VERIFYTASKS") }),
              let resource = columns.first(where: { $0.hasSuffix("VERIFYRESOURCES") }) else { return [] }
        return names(database, """
            select distinct v.ZLABEL from ZACTIVITYTASK t
            join \(link) l on l.\(task) = t.Z_PK
            join \(resources) r on r.Z_PK = l.\(resource)
            join ZVOLUME v on v.Z_PK = r.ZVOLUME
            where t.ZJOB = \(row) and v.ZLABEL is not null order by v.ZLABEL
            """)
    }

    /// The first column of every row.
    private static func names(_ database: OpaquePointer, _ query: String) -> [String] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        var found: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { if let name = text(statement, 0) { found.append(name) } }
        return found
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}
