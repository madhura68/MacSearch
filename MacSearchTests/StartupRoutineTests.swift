import Foundation
import Testing
@testable import MacSearch

/// AC3a (seeded crash cases) and AC4: the start routine of F19, F19c and F19d. It never removes a file.
@Suite struct StartupRoutineTests {
    /// A database under `Application Support/MacSearch/` (not yet created), plus `bron/` and `doel/`.
    struct Fixture {
        let root: URL
        let databaseURL: URL
        let bron: URL
        let doel: URL
        let ops = FaultyFileOps()

        func remove() { try? FileManager.default.removeItem(at: root) }
        func doel(_ name: String) -> String { doel.appendingPathComponent(name).path }

        /// Writes a run with one action per entry, then closes the database.
        @discardableResult
        func seed(status: RunStatus, actions: [(dest: String, tempPath: String?)]) throws -> [Int64] {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let store = try HistoryStore(url: databaseURL)
            let runId = try store.insertRun(
                NewRun(
                    createdAt: iso8601(Date()), sourcePath: bron.path, keywordsRaw: "naam", destRoot: doel.path,
                    destFolder: doel.path, mode: .move, foundCount: actions.count, selectedCount: actions.count,
                    scanComplete: true, skippedCount: 0))
            if status != .running { try store.finishRun(id: runId, status: status) }
            return try actions.map { action in
                try store.insertAction(
                    runId: runId, sourcePath: bron.appendingPathComponent("naam.jpg").path, destPath: action.dest,
                    tempPath: action.tempPath, result: .pending, error: nil)
            }
        }

        func start() -> StartupState {
            StartupRoutine.run(databaseURL: databaseURL, ops: ops)
        }

        func tempPaths() throws -> [String?] {
            let store = try HistoryStore(url: databaseURL)
            return try store.recentRuns(limit: 50).flatMap { try store.actions(runId: $0.id) }.map(\.tempPath)
        }
    }

    func makeFixture() throws -> Fixture {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: realPath(NSTemporaryDirectory()))
            .appendingPathComponent("StartupRoutineTests-\(UUID().uuidString)")
        let bron = root.appendingPathComponent("bron")
        let doel = root.appendingPathComponent("doel")
        try fm.createDirectory(at: bron, withIntermediateDirectories: true)
        try fm.createDirectory(at: doel, withIntermediateDirectories: true)
        try Data("ABCDEF".utf8).write(to: bron.appendingPathComponent("naam.jpg"))
        return Fixture(
            root: root,
            databaseURL: root.appendingPathComponent("Application Support/MacSearch/macsearch.sqlite"),
            bron: bron, doel: doel)
    }

    func ready(_ state: StartupState, sourceLocation: SourceLocation = #_sourceLocation) throws
        -> (store: HistoryStore, leftovers: [Leftover], history: [RunSummary])
    {
        guard case .ready(let store, let leftovers, let history) = state else {
            Issue.record("expected .ready, got \(state)", sourceLocation: sourceLocation)
            throw CancellationError()
        }
        return (store, leftovers, history)
    }

    @Test func aFreshStartCreatesTheFolderAndAnEmptyDatabase() throws {
        let f = try makeFixture(); defer { f.remove() }
        let (_, leftovers, history) = try ready(f.start())
        #expect(leftovers.isEmpty)
        #expect(history.isEmpty)
        #expect(FileManager.default.fileExists(atPath: f.databaseURL.path))
    }

    @Test func aHalfCopyInRouteCIsReportedAndKept() throws {
        let f = try makeFixture(); defer { f.remove() }
        let half = f.doel("naam.jpg")
        TransferFixture.plant(half, Data("ABC".utf8))
        TransferFixture.plant(f.doel("ander.jpg"), Data("vreemd".utf8))
        let ids = try f.seed(status: .running, actions: [(dest: half, tempPath: half)])
        let (_, leftovers, history) = try ready(f.start())
        #expect(leftovers == [Leftover(actionId: ids[0], path: half)])
        #expect(history.first?.status == .interrupted)
        #expect(FileManager.default.contents(atPath: half) == Data("ABC".utf8))
        #expect(FileManager.default.contents(atPath: f.doel("ander.jpg")) == Data("vreemd".utf8))
        #expect(FileManager.default.contents(atPath: f.bron.appendingPathComponent("naam.jpg").path) == Data("ABCDEF".utf8))
        #expect(f.ops.count(.unlink) == 0)
        #expect(try f.tempPaths() == [half])
    }

    @Test func aHalfFileTheUserRemovedIsClearedWithoutReport() throws {
        let f = try makeFixture(); defer { f.remove() }
        let gone = f.doel("naam.jpg")
        try f.seed(status: .interrupted, actions: [(dest: gone, tempPath: gone)])
        let (_, leftovers, _) = try ready(f.start())
        #expect(leftovers.isEmpty)
        #expect(try f.tempPaths() == [nil])
    }

    @Test func aCrashAfterTheCompletionWriteReportsNothing() throws {
        let f = try makeFixture(); defer { f.remove() }
        let complete = f.doel("naam.jpg")
        TransferFixture.plant(complete, Data("ABCDEF".utf8))
        try f.seed(status: .running, actions: [(dest: complete, tempPath: nil)])
        let (_, leftovers, _) = try ready(f.start())
        #expect(leftovers.isEmpty)
        #expect(FileManager.default.contents(atPath: complete) == Data("ABCDEF".utf8))
        #expect(FileManager.default.fileExists(atPath: f.bron.appendingPathComponent("naam.jpg").path))
    }

    @Test func aCrashBetweenPublicationAndTheFinalWriteInRouteBIsCleared() throws {
        let f = try makeFixture(); defer { f.remove() }
        let published = f.doel("naam.jpg")
        TransferFixture.plant(published, Data("ABCDEF".utf8))
        try f.seed(status: .running, actions: [(dest: published, tempPath: f.doel(".macsearch-\(UUID().uuidString).tmp"))])
        let (_, leftovers, _) = try ready(f.start())
        #expect(leftovers.isEmpty)
        #expect(try f.tempPaths() == [nil])
        #expect(FileManager.default.contents(atPath: published) == Data("ABCDEF".utf8))
    }

    @Test func aLeftoverIsReportedAtEveryStartUntilHandled() throws {
        let f = try makeFixture(); defer { f.remove() }
        let temp = f.doel(".macsearch-\(UUID().uuidString).tmp")
        TransferFixture.plant(temp, Data("ABC".utf8))
        let ids = try f.seed(status: .interrupted, actions: [(dest: f.doel("naam.jpg"), tempPath: temp)])
        #expect(try ready(f.start()).leftovers.map(\.path) == [temp])
        let (store, leftovers, _) = try ready(f.start())
        #expect(leftovers.map(\.actionId) == ids)
        try store.clearTempPath(actionId: ids[0])
        #expect(try ready(f.start()).leftovers.isEmpty)
        #expect(FileManager.default.fileExists(atPath: temp))
    }

    @Test func aRunningRunBecomesInterrupted() throws {
        let f = try makeFixture(); defer { f.remove() }
        try f.seed(status: .running, actions: [])
        let (_, _, history) = try ready(f.start())
        #expect(history.map(\.status) == [.interrupted])
        #expect(history.first?.isIncomplete == true)
    }

    @Test func aDatabaseThatCannotBeOpenedFailsWithItsPath() throws {
        let f = try makeFixture(); defer { f.remove() }
        try FileManager.default.createDirectory(
            at: f.databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 4096).write(to: f.databaseURL)
        guard case .failed(let path, let message) = f.start() else {
            Issue.record("expected .failed")
            return
        }
        #expect(path == f.databaseURL.path)
        #expect(!message.isEmpty)
    }
}
