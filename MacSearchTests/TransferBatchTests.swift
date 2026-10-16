import Darwin
import Foundation
import Testing
@testable import MacSearch

/// AC4 and F0d: the run bookkeeping around `FileTransfer` (F14, F17, F19a–F19c).
@Suite struct TransferBatchTests {
    /// `bron/` with `a.jpg`, `b.jpg` and `c.jpg`, an empty destination `uit/`, and a context for them.
    struct Fixture {
        let root: URL
        let context: SearchContext
        let files: [FoundFile]
        let store: RecordingStore
        let ops: FaultyFileOps

        func remove() { try? FileManager.default.removeItem(at: root) }

        func status() throws -> RunStatus? {
            try store.inner.recentRuns(limit: 1).first?.status
        }

        func rows(_ summary: BatchSummary) throws -> [ActionRow] {
            try store.actions(runId: try #require(summary.runId))
        }
    }

    static let names = ["a.jpg", "b.jpg", "c.jpg"]

    /// 2001-02-03 23:59:59 in the local time zone: never today, so a batch that reads the clock fails.
    static let confirmedAt: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2001, month: 2, day: 3, hour: 23, minute: 59, second: 59))!
    }()

    func makeFixture(ops: FaultyFileOps = FaultyFileOps()) throws -> Fixture {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: realPath(NSTemporaryDirectory()))
            .appendingPathComponent("TransferBatchTests-\(UUID().uuidString)")
        let bron = root.appendingPathComponent("bron")
        let uit = root.appendingPathComponent("uit")
        try fm.createDirectory(at: bron, withIntermediateDirectories: true)
        try fm.createDirectory(at: uit, withIntermediateDirectories: true)
        let files = try Self.names.map { name in
            let url = bron.appendingPathComponent(name)
            let data = Data("inhoud \(name)".utf8)
            try data.write(to: url)
            return FoundFile(url: url, size: Int64(data.count))
        }
        let context = try SearchContext.make(source: bron, keywordsRaw: "jan visser", destRoot: uit)
        return Fixture(root: root, context: context, files: files, store: try RecordingStore(), ops: ops)
    }

    func run(
        _ f: Fixture, mode: TransferMode = .copy, stop: StopFlag = StopFlag(),
        isUsable: @escaping @Sendable (URL) -> Bool = destinationUsable,
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async -> BatchSummary {
        let batch = TransferBatch(store: f.store, ops: f.ops, uuids: SystemUUIDSource(), isUsable: isUsable)
        return await batch.run(
            context: f.context, files: f.files, mode: mode, confirmedAt: Self.confirmedAt, foundCount: f.files.count,
            scanComplete: true, skippedCount: 0, stop: stop, progress: progress)
    }

    func published(_ summary: BatchSummary, _ name: String) -> Data? {
        FileManager.default.contents(atPath: summary.destFolder + "/" + name)
    }

    // MARK: Before the first file

    @Test func aFailingRunInsertTransfersNothing() async throws {
        let f = try makeFixture(); defer { f.remove() }
        f.store.fail(.insertRun)
        let summary = await run(f)
        #expect(summary.runId == nil)
        #expect(summary.fatalError != nil)
        #expect(summary.fatalCause == .runInsertFailed)
        #expect(f.ops.count(.createDirectories) == 0)
        #expect(f.ops.count(.createExclusive) == 0)
        #expect(f.ops.count(.renameExclusive) == 0)
    }

    @Test func anUnusableDestinationTransfersNothing() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let summary = await run(f, isUsable: { _ in false })
        #expect(summary.runId == nil)
        #expect(summary.fatalError != nil)
        #expect(summary.fatalCause == .destinationUnusable)
        #expect(f.store.count(.insertRun) == 0)
        #expect(f.ops.count(.createDirectories) == 0)
        #expect(f.ops.count(.createExclusive) == 0)
    }

    @Test func theDateComesFromTheMomentOfOK() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let summary = await run(f)
        #expect(summary.destFolder == f.context.destRoot.path + "/jan visser/2001-02-03")
        let run = try #require(try f.store.inner.recentRuns(limit: 1).first)
        #expect(run.createdAt == iso8601(Self.confirmedAt))
        #expect(published(summary, "a.jpg") == Data("inhoud a.jpg".utf8))
    }

    @Test func failingToCreateTheFolderAborts() async throws {
        let f = try makeFixture(); defer { f.remove() }
        f.ops.fail(.createDirectories, errno: EACCES)
        let summary = await run(f)
        #expect(summary.runId != nil)
        #expect(summary.status == .aborted)
        #expect(summary.fatalCause == .aborted)
        #expect(summary.fatalError != nil)
        #expect(try f.status() == .aborted)
        #expect(f.ops.count(.createExclusive) == 0)
        #expect(f.store.count(.insertAction) == 0)
    }

    // MARK: Progress and results

    @Test func progressIsReportedAfterEveryFile() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let calls = Locked<[String]>([])
        let summary = await run(f, progress: { processed, total in calls.set(calls.get() + ["\(processed)/\(total)"]) })
        #expect(calls.get() == ["1/3", "2/3", "3/3"])
        #expect(summary.status == .completed)
        #expect(summary.counts == [.copied: 3])
        #expect(summary.fatalError == nil)
        #expect(try f.status() == .completed)
    }

    @Test func anUnreadableFileDoesNotStopTheBatch() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let first = f.files[0].url.path
        #expect(chmod(first, 0) == 0)
        defer { _ = chmod(first, 0o644) }
        let summary = await run(f)
        try expectContinued(f, summary)
    }

    @Test func aFullDiskOnOneFileDoesNotStopTheBatch() async throws {
        let f = try makeFixture(); defer { f.remove() }
        f.ops.fail(.copyData, errno: ENOSPC, onCall: 1)
        let summary = await run(f)
        try expectContinued(f, summary)
    }

    /// AC3: records `failed`, `copied`, `copied`; files 2 and 3 published, file 1 intact.
    func expectContinued(_ f: Fixture, _ summary: BatchSummary, sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(summary.status == .completed, sourceLocation: sourceLocation)
        #expect(summary.counts == [.failed: 1, .copied: 2], sourceLocation: sourceLocation)
        let results = try f.rows(summary).map(\.result)
        #expect(results == [.failed, .copied, .copied], sourceLocation: sourceLocation)
        #expect(published(summary, "a.jpg") == nil, sourceLocation: sourceLocation)
        #expect(published(summary, "b.jpg") == Data("inhoud b.jpg".utf8), sourceLocation: sourceLocation)
        #expect(published(summary, "c.jpg") == Data("inhoud c.jpg".utf8), sourceLocation: sourceLocation)
        _ = chmod(f.files[0].url.path, 0o644)
        #expect(
            FileManager.default.contents(atPath: f.files[0].url.path) == Data("inhoud a.jpg".utf8),
            sourceLocation: sourceLocation)
        #expect(try f.status() == .completed, sourceLocation: sourceLocation)
    }

    // MARK: History writes (F19b)

    @Test func aFailingPendingInsertOfTheFirstFileAborts() async throws {
        let f = try makeFixture(); defer { f.remove() }
        f.store.fail(.insertAction, onCall: 1)
        let summary = await run(f)
        #expect(summary.runId != nil)
        #expect(summary.status == .aborted)
        #expect(summary.fatalCause == .aborted)
        #expect(summary.fatalError?.contains("geen bestand verwerkt") == true)
        #expect(f.ops.count(.copyData) == 0)
        #expect(try f.status() == .aborted)
    }

    @Test func aFailingResultUpdateStopsAfterOneTransfer() async throws {
        let f = try makeFixture(); defer { f.remove() }
        f.store.fail(.updateAction, onCall: 1)
        let summary = await run(f)
        #expect(summary.status == .aborted)
        #expect(summary.fatalCause == .aborted)
        #expect(f.ops.count(.copyData) == 1)
        #expect(try f.rows(summary).map(\.result) == [.pending])
        #expect(try f.status() == .aborted)
    }

    @Test func whenTheAbortedWriteFailsTooTheRunBecomesInterruptedAtTheNextStart() async throws {
        let f = try makeFixture(); defer { f.remove() }
        f.store.fail(.updateAction, onCall: 1)
        f.store.fail(.finishRun)
        let summary = await run(f)
        #expect(summary.status == .running)
        #expect(summary.fatalCause == .aborted)
        #expect(try f.status() == .running)
        #expect(try f.store.inner.markRunningInterrupted() == 1)
        #expect(try f.status() == .interrupted)
    }

    @Test func abortedWinsOverStop() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let stop = StopFlag()
        f.ops.before(.copyData) { _ in stop.stop() }
        f.store.fail(.updateAction, onCall: 1)
        let summary = await run(f, stop: stop)
        #expect(summary.status == .aborted)
        #expect(try f.status() == .aborted)
    }

    @Test func stopAfterTheFirstFileCancelsTheRest() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let stop = StopFlag()
        let summary = await run(f, stop: stop, progress: { processed, _ in if processed == 1 { stop.stop() } })
        #expect(summary.status == .cancelled)
        #expect(summary.fatalError == nil)
        #expect(summary.counts == [.copied: 1])
        #expect(try f.rows(summary).count == 1)
        #expect(published(summary, "b.jpg") == nil)
        #expect(published(summary, "c.jpg") == nil)
        #expect(FileManager.default.fileExists(atPath: f.files[1].url.path))
        #expect(FileManager.default.fileExists(atPath: f.files[2].url.path))
        #expect(try f.status() == .cancelled)
    }

    @Test func aFailingFinalStatusWriteLeavesTheRunRunning() async throws {
        let f = try makeFixture(); defer { f.remove() }
        f.store.fail(.finishRun)
        let summary = await run(f)
        #expect(summary.status == .running)
        #expect(summary.counts == [.copied: 3])
        #expect(try f.status() == .running)
    }

    @Test func aProcessedFileIsNamedWhenItsResultWriteFails() async throws {
        let f = try makeFixture(); defer { f.remove() }
        f.store.fail(.updateAction, onCall: 2)
        let summary = await run(f)
        let message = try #require(summary.fatalError)
        #expect(message.contains("b.jpg"))
        #expect(summary.counts == [.copied: 2])
    }

    @Test func anUnprocessedFileNamesThePreviousOne() async throws {
        let f = try makeFixture(); defer { f.remove() }
        f.store.fail(.insertAction, onCall: 2)
        let summary = await run(f)
        let message = try #require(summary.fatalError)
        #expect(message.contains("a.jpg"))
        #expect(!message.contains("b.jpg"))
        #expect(summary.counts == [.copied: 1])
    }

    // MARK: Volume capability (F15)

    @Test func theCapabilityIsQueriedOncePerRun() async throws {
        let f = try makeFixture(); defer { f.remove() }
        _ = await run(f)
        #expect(f.ops.count(.supportsRenameExclusive) == 1)
    }

    @Test func theRealCapabilityOfTheCreatedFolderSelectsRouteB() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let renamedFrom = Locked<[String]>([])
        f.ops.before(.renameExclusive) { call in
            if case .paths(let from, _) = call { renamedFrom.set(renamedFrom.get() + [from]) }
        }
        let summary = await run(f)
        #expect(summary.counts == [.copied: 3])
        #expect(renamedFrom.get().count == 3)
        #expect(renamedFrom.get().allSatisfy { ($0 as NSString).lastPathComponent.hasPrefix(".macsearch-") })
    }

    @Test func movingOnTheSameVolumeRenamesTheSource() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let summary = await run(f, mode: .move)
        #expect(summary.counts == [.moved: 3])
        #expect(f.ops.count(.createExclusive) == 0)
        #expect(published(summary, "a.jpg") == Data("inhoud a.jpg".utf8))
        #expect(!FileManager.default.fileExists(atPath: f.files[0].url.path))
    }

    @Test func noCapabilityMeansRouteC() async throws {
        let forced = FaultyFileOps()
        forced.forceRenameExclusive(false)
        let failing = FaultyFileOps(
            base: PosixFileOps(capabilityQuery: { _ throws(POSIXFailure) in throw POSIXFailure(errno: EIO) }))
        for ops in [forced, failing] {
            let f = try makeFixture(ops: ops); defer { f.remove() }
            let summary = await run(f)
            #expect(summary.counts == [.copied: 3])
            #expect(ops.count(.renameExclusive) == 0)
            let entries = try FileManager.default.contentsOfDirectory(atPath: summary.destFolder)
            #expect(!entries.contains { $0.hasPrefix(".macsearch-") })
            #expect(published(summary, "a.jpg") == Data("inhoud a.jpg".utf8))
        }
    }

    @Test func aForcedCapabilityPublishesByRename() async throws {
        let ops = FaultyFileOps()
        ops.forceRenameExclusive(true)
        let f = try makeFixture(ops: ops); defer { f.remove() }
        let summary = await run(f)
        #expect(summary.counts == [.copied: 3])
        #expect(ops.count(.renameExclusive) >= 1)
    }
}
