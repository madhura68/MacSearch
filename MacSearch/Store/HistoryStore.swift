import Foundation
import GRDB

/// SQLite history and action log (spec §5, F19–F19c).
final class HistoryStore: HistoryWriting, Sendable {
    let dbQueue: DatabaseQueue

    /// Opens and migrates the database; throws when it cannot be opened, is corrupt or not writable (F19).
    init(url: URL) throws {
        dbQueue = try DatabaseQueue(path: url.path)
        try Self.migrator.migrate(dbQueue)
    }

    private init(queue: DatabaseQueue) throws {
        dbQueue = queue
        try Self.migrator.migrate(dbQueue)
    }

    static func inMemory() throws -> HistoryStore {
        try HistoryStore(queue: DatabaseQueue())
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE search_run (
                  id            INTEGER PRIMARY KEY AUTOINCREMENT,
                  created_at    TEXT NOT NULL,
                  source_path   TEXT NOT NULL,
                  keywords_raw  TEXT NOT NULL,
                  dest_root     TEXT NOT NULL,
                  dest_folder   TEXT NOT NULL,
                  mode          TEXT NOT NULL CHECK (mode IN ('copy','move')),
                  found_count   INTEGER NOT NULL,
                  selected_count INTEGER NOT NULL,
                  scan_complete INTEGER NOT NULL CHECK (scan_complete IN (0,1)),
                  skipped_count INTEGER NOT NULL DEFAULT 0,
                  status        TEXT NOT NULL CHECK (status IN ('running','completed','cancelled','aborted','interrupted')),
                  finished_at   TEXT
                );
                CREATE TABLE file_action (
                  id            INTEGER PRIMARY KEY AUTOINCREMENT,
                  run_id        INTEGER NOT NULL REFERENCES search_run(id) ON DELETE CASCADE,
                  source_path   TEXT NOT NULL,
                  dest_path     TEXT,
                  temp_path     TEXT,
                  result        TEXT NOT NULL CHECK (result IN ('pending','copied','moved','renamed','skipped_identical','failed')),
                  error         TEXT
                );
                CREATE INDEX file_action_run ON file_action(run_id);
                CREATE INDEX search_run_created ON search_run(created_at DESC);
                """)
        }
        return migrator
    }

    // MARK: HistoryWriting

    func insertRun(_ run: NewRun) throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO search_run (created_at, source_path, keywords_raw, dest_root, dest_folder, mode,
                        found_count, selected_count, scan_complete, skipped_count, status)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'running')
                    """,
                arguments: [
                    run.createdAt, run.sourcePath, run.keywordsRaw, run.destRoot, run.destFolder, run.mode.rawValue,
                    run.foundCount, run.selectedCount, run.scanComplete ? 1 : 0, run.skippedCount,
                ])
            return db.lastInsertedRowID
        }
    }

    func finishRun(id: Int64, status: RunStatus) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE search_run SET status = ?, finished_at = ? WHERE id = ?",
                arguments: [status.rawValue, iso8601(Date()), id])
        }
    }

    func insertAction(
        runId: Int64, sourcePath: String, destPath: String?, tempPath: String?, result: ActionResult, error: String?
    ) throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO file_action (run_id, source_path, dest_path, temp_path, result, error)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [runId, sourcePath, destPath, tempPath, result.rawValue, error])
            return db.lastInsertedRowID
        }
    }

    func updateAction(id: Int64, result: ActionResult, destPath: String?, tempPath: TempPathChange, error: String?) throws {
        try dbQueue.write { db in
            switch tempPath {
            case .keep:
                try db.execute(
                    sql: "UPDATE file_action SET result = ?, dest_path = ?, error = ? WHERE id = ?",
                    arguments: [result.rawValue, destPath, error, id])
            case .set(let path):
                try db.execute(
                    sql: "UPDATE file_action SET result = ?, dest_path = ?, error = ?, temp_path = ? WHERE id = ?",
                    arguments: [result.rawValue, destPath, error, path, id])
            case .clear:
                try db.execute(
                    sql: "UPDATE file_action SET result = ?, dest_path = ?, error = ?, temp_path = NULL WHERE id = ?",
                    arguments: [result.rawValue, destPath, error, id])
            }
        }
    }

    // MARK: Startup and history

    /// F19c: runs still `running` at startup become `interrupted`. Returns the number changed.
    func markRunningInterrupted() throws -> Int {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE search_run SET status = 'interrupted' WHERE status = 'running'")
            return db.changesCount
        }
    }

    /// F19d: actions whose `temp_path` is set, in runs that are no longer running.
    func leftoverCandidates() throws -> [Leftover] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT fa.id, fa.temp_path FROM file_action fa
                    JOIN search_run sr ON sr.id = fa.run_id
                    WHERE fa.temp_path IS NOT NULL AND sr.status != 'running'
                    ORDER BY fa.id
                    """
            ).map { Leftover(actionId: $0["id"], path: $0["temp_path"]) }
        }
    }

    func clearTempPath(actionId: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE file_action SET temp_path = NULL WHERE id = ?", arguments: [actionId])
        }
    }

    func recentRuns(limit: Int) throws -> [RunSummary] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT sr.*,
                        (SELECT COUNT(*) FROM file_action fa WHERE fa.run_id = sr.id AND fa.result != 'pending') AS processed
                    FROM search_run sr
                    ORDER BY sr.created_at DESC, sr.id DESC
                    LIMIT ?
                    """,
                arguments: [limit]
            ).map { row in
                let status = RunStatus(rawValue: row["status"]) ?? .interrupted
                let scanComplete: Int = row["scan_complete"]
                let skipped: Int = row["skipped_count"]
                return RunSummary(
                    id: row["id"], createdAt: row["created_at"], keywordsRaw: row["keywords_raw"],
                    sourcePath: row["source_path"], destRoot: row["dest_root"],
                    mode: TransferMode(rawValue: row["mode"]) ?? .copy, status: status,
                    processedCount: row["processed"],
                    isIncomplete: [.interrupted, .aborted, .cancelled].contains(status) || scanComplete == 0 || skipped > 0)
            }
        }
    }

    func actions(runId: Int64) throws -> [ActionRow] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM file_action WHERE run_id = ? ORDER BY id", arguments: [runId]).map {
                ActionRow(
                    id: $0["id"], runId: $0["run_id"], sourcePath: $0["source_path"], destPath: $0["dest_path"],
                    tempPath: $0["temp_path"], result: ActionResult(rawValue: $0["result"]) ?? .failed,
                    error: $0["error"])
            }
        }
    }
}
