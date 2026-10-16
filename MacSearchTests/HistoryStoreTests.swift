import Foundation
import GRDB
import Testing
@testable import MacSearch

@Suite struct HistoryStoreTests {
    func newRun(createdAt: String = "2026-10-16T10:00:00Z", scanComplete: Bool = true, skipped: Int = 0) -> NewRun {
        NewRun(
            createdAt: createdAt, sourcePath: "/bron", keywordsRaw: "janpeter visser", destRoot: "/uit",
            destFolder: "/uit/janpeter visser/2026-10-16", mode: .copy, foundCount: 3, selectedCount: 2,
            scanComplete: scanComplete, skippedCount: skipped)
    }

    func status(_ store: HistoryStore, _ id: Int64) throws -> String? {
        try store.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM search_run WHERE id = ?", arguments: [id])
        }
    }

    @Test func migrationRunsOnEmptyDatabase() throws {
        let store = try HistoryStore.inMemory()
        let tables = try store.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        }
        #expect(tables.contains("search_run"))
        #expect(tables.contains("file_action"))
    }

    @Test func runWithTwoActionsRoundTrips() throws {
        let store = try HistoryStore.inMemory()
        let runId = try store.insertRun(newRun())
        let first = try store.insertAction(
            runId: runId, sourcePath: "/bron/a.jpg", destPath: "/uit/a.jpg", tempPath: "/uit/.macsearch-1.tmp",
            result: .pending, error: nil)
        _ = try store.insertAction(
            runId: runId, sourcePath: "/bron/b.jpg", destPath: nil, tempPath: nil, result: .failed, error: "EIO")
        try store.updateAction(id: first, result: .copied, destPath: "/uit/a.jpg", tempPath: .clear, error: nil)
        try store.finishRun(id: runId, status: .completed)

        let actions = try store.actions(runId: runId)
        #expect(actions.count == 2)
        #expect(actions[0].result == .copied)
        #expect(actions[0].tempPath == nil)
        #expect(actions[0].destPath == "/uit/a.jpg")
        #expect(actions[1].result == .failed)
        #expect(actions[1].error == "EIO")

        let runs = try store.recentRuns(limit: 10)
        #expect(runs.count == 1)
        #expect(runs[0].id == runId)
        #expect(runs[0].keywordsRaw == "janpeter visser")
        #expect(runs[0].mode == .copy)
        #expect(runs[0].status == .completed)
        #expect(runs[0].processedCount == 2)
        #expect(!runs[0].isIncomplete)
    }

    @Test func markRunningInterruptedOnlyTouchesRunningRuns() throws {
        let store = try HistoryStore.inMemory()
        let running = try store.insertRun(newRun())
        let done = try store.insertRun(newRun())
        try store.finishRun(id: done, status: .completed)

        #expect(try store.markRunningInterrupted() == 1)
        #expect(try status(store, running) == "interrupted")
        #expect(try status(store, done) == "completed")
    }

    @Test(arguments: [RunStatus.interrupted, .aborted, .cancelled])
    func unfinishedStatusesAreIncomplete(_ runStatus: RunStatus) throws {
        let store = try HistoryStore.inMemory()
        let id = try store.insertRun(newRun())
        if runStatus == .interrupted {
            _ = try store.markRunningInterrupted()
        } else {
            try store.finishRun(id: id, status: runStatus)
        }
        #expect(try store.recentRuns(limit: 1)[0].isIncomplete)
    }

    @Test func incompleteScanOrSkippedItemsMarkTheRunIncomplete() throws {
        let store = try HistoryStore.inMemory()
        let partial = try store.insertRun(newRun(createdAt: "2026-10-16T10:00:01Z", scanComplete: false))
        let skipped = try store.insertRun(newRun(createdAt: "2026-10-16T10:00:02Z", skipped: 1))
        let clean = try store.insertRun(newRun(createdAt: "2026-10-16T10:00:03Z"))
        for id in [partial, skipped, clean] { try store.finishRun(id: id, status: .completed) }

        let byId = Dictionary(uniqueKeysWithValues: try store.recentRuns(limit: 10).map { ($0.id, $0) })
        #expect(byId[partial]?.isIncomplete == true)
        #expect(byId[skipped]?.isIncomplete == true)
        #expect(byId[clean]?.isIncomplete == false)
    }

    @Test func recentRunsAreNewestFirst() throws {
        let store = try HistoryStore.inMemory()
        let old = try store.insertRun(newRun(createdAt: "2026-10-15T10:00:00Z"))
        let new = try store.insertRun(newRun(createdAt: "2026-10-16T10:00:00Z"))
        #expect(try store.recentRuns(limit: 10).map(\.id) == [new, old])
        #expect(try store.recentRuns(limit: 1).map(\.id) == [new])
    }

    @Test func leftoverCandidatesSkipRunningRuns() throws {
        let store = try HistoryStore.inMemory()
        let running = try store.insertRun(newRun())
        _ = try store.insertAction(
            runId: running, sourcePath: "/bron/a.jpg", destPath: "/uit/a.jpg", tempPath: "/uit/.macsearch-a.tmp",
            result: .pending, error: nil)
        let aborted = try store.insertRun(newRun())
        let leftover = try store.insertAction(
            runId: aborted, sourcePath: "/bron/b.jpg", destPath: "/uit/b.jpg", tempPath: "/uit/.macsearch-b.tmp",
            result: .pending, error: nil)
        _ = try store.insertAction(
            runId: aborted, sourcePath: "/bron/c.jpg", destPath: "/uit/c.jpg", tempPath: nil, result: .copied, error: nil)
        try store.finishRun(id: aborted, status: .aborted)

        let candidates = try store.leftoverCandidates()
        #expect(candidates.map(\.actionId) == [leftover])
        #expect(candidates.map(\.path) == ["/uit/.macsearch-b.tmp"])

        try store.clearTempPath(actionId: leftover)
        #expect(try store.leftoverCandidates().isEmpty)
    }

    @Test func corruptDatabaseFailsToOpen() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("corrupt-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<8192).map { _ in UInt8.random(in: 0...255, using: &generator) }
        try Data(bytes).write(to: url)
        #expect(throws: (any Error).self) { try HistoryStore(url: url) }
    }

    @Test func fileDatabaseSurvivesReopen() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let id = try HistoryStore(url: url).insertRun(newRun())
        #expect(try HistoryStore(url: url).recentRuns(limit: 1).map(\.id) == [id])
    }

    @Test func checkConstraintsRejectInvalidModeAndStatus() throws {
        let store = try HistoryStore.inMemory()
        let insert = """
            INSERT INTO search_run (created_at, source_path, keywords_raw, dest_root, dest_folder, mode,
                found_count, selected_count, scan_complete, skipped_count, status)
            VALUES ('2026-10-16T10:00:00Z', '/b', 'k', '/u', '/u/k/d', ?, 1, 1, 1, 0, ?)
            """
        #expect(throws: DatabaseError.self) {
            try store.dbQueue.write { db in try db.execute(sql: insert, arguments: ["teleport", "running"]) }
        }
        #expect(throws: DatabaseError.self) {
            try store.dbQueue.write { db in try db.execute(sql: insert, arguments: ["copy", "exploded"]) }
        }
    }

    @Test func indexesExist() throws {
        let store = try HistoryStore.inMemory()
        let indexes = try store.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
        }
        #expect(indexes.contains("file_action_run"))
        #expect(indexes.contains("search_run_created"))
    }

    @Test func deletingARunCascadesToItsActions() throws {
        let store = try HistoryStore.inMemory()
        let runId = try store.insertRun(newRun())
        _ = try store.insertAction(
            runId: runId, sourcePath: "/bron/a.jpg", destPath: nil, tempPath: nil, result: .failed, error: nil)
        try store.dbQueue.write { db in
            #expect(try Bool.fetchOne(db, sql: "PRAGMA foreign_keys") == true)
            try db.execute(sql: "DELETE FROM search_run WHERE id = ?", arguments: [runId])
        }
        #expect(try store.actions(runId: runId).isEmpty)
    }

    @Test func finishedAtIsNullWhileRunning() throws {
        let store = try HistoryStore.inMemory()
        let runId = try store.insertRun(newRun())
        let finishedAt = { () throws -> String? in
            try store.dbQueue.read { db in
                try String.fetchOne(db, sql: "SELECT finished_at FROM search_run WHERE id = ?", arguments: [runId])
            }
        }
        #expect(try finishedAt() == nil)
        try store.finishRun(id: runId, status: .completed)
        #expect(try finishedAt() != nil)
    }
}
