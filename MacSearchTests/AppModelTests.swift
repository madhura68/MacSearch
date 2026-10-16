import Foundation
import GRDB
import Testing
@testable import MacSearch

/// Injected collaborators for `AppModel`; nonisolated so `@Sendable` closures can use them.
enum Fakes {
    typealias Scanner = @Sendable (SearchContext) -> AsyncThrowingStream<ScanEvent, Error>
    typealias ContextMaker = @Sendable (URL, String, URL) async throws(SearchValidationError) -> SearchContext

    /// 2001-02-03 23:59:59 local: the moment of OK.
    static let okMoment: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2001, month: 2, day: 3, hour: 23, minute: 59, second: 59))!
    }()

    static func stream(_ events: [ScanEvent], error: Error? = nil) -> AsyncThrowingStream<ScanEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish(throwing: error)
        }
    }

    static let realContext: ContextMaker = {
        (source: URL, keywords: String, dest: URL) async throws(SearchValidationError) -> SearchContext in
        try SearchContext.make(source: source, keywordsRaw: keywords, destRoot: dest)
    }

    static func gatedContext(_ gate: Gate) -> ContextMaker {
        { (source: URL, keywords: String, dest: URL) async throws(SearchValidationError) -> SearchContext in
            await gate.pass()
            return try SearchContext.make(source: source, keywordsRaw: keywords, destRoot: dest)
        }
    }
}

struct ScanFailure: Error {}

/// AC4a and F18: the state model of F0b–F0d with real files, a real in-memory history and the real batch.
@MainActor
@Suite struct AppModelTests {
    /// `bron/` with `a.jpg`, `b.jpg`, `c.jpg`, an empty `uit/`, and an in-memory history.
    struct Env {
        let root: URL
        let bron: URL
        let uit: URL
        let files: [FoundFile]
        let store: HistoryStore
        let ops = FaultyFileOps()

        func remove() { try? FileManager.default.removeItem(at: root) }

        func runs() throws -> [Row] {
            try store.dbQueue.read { try Row.fetchAll($0, sql: "SELECT * FROM search_run ORDER BY id") }
        }

        func actionSources() throws -> [String] {
            try store.dbQueue.read { try String.fetchAll($0, sql: "SELECT source_path FROM file_action ORDER BY id") }
        }

        /// Holds the n-th file of the batch in `copyData` until the gate opens.
        func hold(file n: Int, _ gate: Gate) {
            let ops = ops
            ops.before(.copyData) { _ in if ops.count(.copyData) == n { gate.passBlocking() } }
        }
    }

    func makeEnv() throws -> Env {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: realPath(NSTemporaryDirectory()))
            .appendingPathComponent("AppModelTests-\(UUID().uuidString)")
        let bron = root.appendingPathComponent("bron")
        let uit = root.appendingPathComponent("uit")
        try fm.createDirectory(at: bron, withIntermediateDirectories: true)
        try fm.createDirectory(at: uit, withIntermediateDirectories: true)
        let files = try ["a.jpg", "b.jpg", "c.jpg"].map { name in
            let url = bron.appendingPathComponent(name)
            let data = Data("inhoud \(name)".utf8)
            try data.write(to: url)
            return FoundFile(url: url, size: Int64(data.count))
        }
        return Env(root: root, bron: bron, uit: uit, files: files, store: try HistoryStore.inMemory())
    }

    func makeModel(
        _ env: Env, startup: StartupState? = nil, writer: HistoryWriting? = nil, scanner: Fakes.Scanner? = nil,
        checkDestination: @escaping @Sendable (URL) async -> Bool = { _ in true },
        isUsable: @escaping @Sendable (URL) -> Bool = destinationUsable,
        makeContext: @escaping Fakes.ContextMaker = Fakes.realContext,
        loadHistory: @escaping @Sendable (HistoryStore) async -> [RunSummary]? = { try? $0.recentRuns(limit: 50) }
    ) -> AppModel {
        let files = env.files
        let ops = env.ops
        return AppModel(
            startup: startup ?? .ready(store: env.store, leftovers: [], history: []),
            scanner: scanner ?? { _ in Fakes.stream([.found(files), .progress(scanned: 5, skipped: 1)]) },
            batch: { store in
                TransferBatch(store: writer ?? store, ops: ops, uuids: SystemUUIDSource(), isUsable: isUsable)
            },
            checkDestination: checkDestination, makeContext: makeContext, loadHistory: loadHistory,
            now: { Fakes.okMoment })
    }

    func fill(_ m: AppModel, _ env: Env, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(m.setField(.source, env.bron.path) == .applied, sourceLocation: sourceLocation)
        #expect(m.setField(.destination, env.uit.path) == .applied, sourceLocation: sourceLocation)
        #expect(m.setField(.keywords, "jan") == .applied, sourceLocation: sourceLocation)
    }

    /// Filled in, searched and reviewed with all three files.
    func reviewed(_ m: AppModel, _ env: Env) async {
        fill(m, env)
        await m.search()?.value
        #expect(m.phase == .reviewing(incomplete: false))
    }

    func sampleRun(_ env: Env) -> RunSummary {
        RunSummary(
            id: 99, createdAt: "2001-01-01T00:00:00Z", keywordsRaw: "piet", sourcePath: env.bron.path,
            destRoot: env.uit.path, mode: .move, status: .completed, processedCount: 2, isIncomplete: false)
    }

    /// Re-reads the state after every `Task.yield()` until it holds, or fails after the deadline.
    func eventually(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while !condition() {
            if clock.now > deadline {
                Issue.record("condition not reached within 2 s", sourceLocation: sourceLocation)
                return
            }
            await Task.yield()
        }
    }

    // MARK: Form and state

    @Test func canSearchNeedsSourceAndDestination() throws {
        let env = try makeEnv(); defer { env.remove() }
        let m = makeModel(env)
        #expect(!m.canSearch)
        #expect(m.setField(.source, env.bron.path) == .applied)
        #expect(!m.canSearch)
        #expect(m.setField(.destination, env.uit.path) == .applied)
        #expect(m.canSearch)
        #expect(m.search() != nil)
    }

    @Test func aStartupErrorBlocksSearchAndOK() throws {
        let env = try makeEnv(); defer { env.remove() }
        let m = makeModel(env, startup: .failed(path: "/db.sqlite", message: "kapot"))
        fill(m, env)
        #expect(m.startupError?.path == "/db.sqlite")
        #expect(!m.canSearch)
        #expect(!m.canConfirm)
        #expect(m.search() == nil)
    }

    @Test func duringScanningTheFormIsReadOnlyAndOKIsOff() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let gate = Gate()
        let m = makeModel(env, makeContext: Fakes.gatedContext(gate))
        fill(m, env)
        let task = m.search()
        #expect(m.phase == .scanning)
        await gate.reached()
        #expect(!m.canConfirm)
        #expect(!m.formEditable)
        #expect(m.modeEditable)
        gate.open()
        await task?.value
        #expect(m.formEditable)
    }

    @Test func searchIsAtomic() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let gate = Gate()
        let scans = Locked(0)
        let files = env.files
        let m = makeModel(
            env,
            scanner: { _ in
                scans.set(scans.get() + 1)
                return Fakes.stream([.found(files)])
            },
            makeContext: Fakes.gatedContext(gate))
        fill(m, env)
        let task = m.search()
        #expect(task != nil)
        await gate.reached()
        #expect(m.search() == nil)
        #expect(m.setField(.keywords, "piet") == .refused)
        #expect(m.requestHistory(sampleRun(env)) == .refused)
        #expect(m.keywordsRaw == "jan")
        gate.open()
        await task?.value
        #expect(scans.get() == 1)
        #expect(m.phase == .reviewing(incomplete: false))
    }

    @Test func cancellingWhileTheContextIsMadeStartsNoScan() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let gate = Gate()
        let scans = Locked(0)
        let m = makeModel(
            env,
            scanner: { _ in
                scans.set(scans.get() + 1)
                return Fakes.stream([])
            },
            makeContext: Fakes.gatedContext(gate))
        fill(m, env)
        let task = m.search()
        await gate.reached()
        m.cancelScan()
        gate.open()
        await task?.value
        #expect(scans.get() == 0)
        #expect(m.phase == .idle)
    }

    @Test func aStreamingScanShowsHitsAndCanBeCancelled() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ScanEvent.self, throwing: Error.self)
        let m = makeModel(env, scanner: { _ in stream })
        fill(m, env)
        let task = m.search()
        continuation.yield(.found(Array(env.files.prefix(2))))
        continuation.yield(.progress(scanned: 10, skipped: 1))
        await eventually { m.scanned == 10 }
        #expect(m.results.count == 2)
        #expect(m.selected.count == 2)
        #expect(m.skipped == 1)
        #expect(!m.canConfirm)
        m.cancelScan()
        await task?.value
        #expect(m.phase == .reviewing(incomplete: true))
        #expect(m.results.count == 2)
        #expect(m.canConfirm)
        continuation.finish()
    }

    @Test func aCancelledScanWithAHitCanStillBeProcessedAsIncomplete() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ScanEvent.self, throwing: Error.self)
        let m = makeModel(env, scanner: { _ in stream })
        fill(m, env)
        let task = m.search()
        continuation.yield(.found([env.files[0]]))
        await eventually { m.results.count == 1 }
        m.cancelScan()
        await task?.value
        #expect(m.phase == .reviewing(incomplete: true))
        #expect(m.canConfirm)
        await m.confirm()?.value
        #expect(try env.runs().first?["scan_complete"] == 0)
        continuation.finish()
    }

    @Test func aLateCancelLeavesTheScanComplete() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let gate = Gate()
        let m = makeModel(
            env,
            checkDestination: { _ in
                await gate.pass()
                return true
            })
        fill(m, env)
        let task = m.search()
        await gate.reached()
        m.cancelScan()
        gate.open()
        await task?.value
        #expect(m.phase == .reviewing(incomplete: false))
        await m.confirm()?.value
        #expect(try env.runs().first?["scan_complete"] == 1)
    }

    @Test func aScannerErrorAfterOneHitIsIncompleteWithAMessage() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let first = env.files[0]
        let m = makeModel(env, scanner: { _ in Fakes.stream([.found([first])], error: ScanFailure()) })
        fill(m, env)
        await m.search()?.value
        #expect(m.phase == .reviewing(incomplete: true))
        #expect(m.message != nil)
        #expect(m.canConfirm)
    }

    @Test func searchingAgainInReviewingStartsANewScan() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let gate = Gate()
        let contexts = Locked(0)
        let m = makeModel(
            env,
            makeContext: { (source: URL, keywords: String, dest: URL) async throws(SearchValidationError) -> SearchContext in
                contexts.set(contexts.get() + 1)
                if contexts.get() == 2 { await gate.pass() }
                return try SearchContext.make(source: source, keywordsRaw: keywords, destRoot: dest)
            })
        await reviewed(m, env)
        let task = m.search()
        #expect(m.phase == .scanning)
        #expect(m.results.isEmpty)
        #expect(m.selected.isEmpty)
        gate.open()
        await task?.value
        #expect(contexts.get() == 2)
        #expect(m.results.count == 3)
    }

    @Test func sameFolderIsRefusedWithTheSpecMessage() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let m = makeModel(env)
        #expect(m.setField(.source, env.bron.path) == .applied)
        #expect(m.setField(.destination, env.bron.path) == .applied)
        #expect(m.setField(.keywords, "jan") == .applied)
        await m.search()?.value
        #expect(m.message == "Kies een andere bestemming of een submap")
        #expect(m.phase == .idle)
    }

    @Test func aDestinationInsideTheSourceIsReported() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let inside = env.bron.appendingPathComponent("uitvoer")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let m = makeModel(env)
        #expect(m.setField(.source, env.bron.path) == .applied)
        #expect(m.setField(.destination, inside.path) == .applied)
        #expect(m.setField(.keywords, "jan") == .applied)
        await m.search()?.value
        #expect(m.containment == .destInsideSource)
    }

    @Test func selectionFollowsToggleSelectAllAndSelectNone() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let m = makeModel(env)
        await reviewed(m, env)
        #expect(m.selected.count == 3)
        m.selectNone()
        #expect(m.selected.isEmpty)
        #expect(!m.canConfirm)
        m.toggle(env.files[1].url)
        #expect(m.selected == [env.files[1].url])
        #expect(m.canConfirm)
        m.selectAll()
        #expect(m.selected.count == 3)
        m.toggle(env.files[1].url)
        #expect(m.selected.count == 2)
    }

    @Test func discardResultsReturnsToIdle() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let m = makeModel(env)
        await reviewed(m, env)
        m.discardResults()
        #expect(m.phase == .idle)
        #expect(m.results.isEmpty)
        #expect(m.selected.isEmpty)
    }

    @Test func changingAFieldWithResultsNeedsConfirmation() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let m = makeModel(env)
        await reviewed(m, env)
        #expect(m.setField(.keywords, "piet") == .needsConfirmation)
        #expect(m.keywordsRaw == "jan")
        #expect(m.results.count == 3)
        m.confirmFormChange(.keywords, "piet")
        #expect(m.phase == .idle)
        #expect(m.results.isEmpty)
        #expect(m.keywordsRaw == "piet")
    }

    @Test func changesInReviewingWithoutResultsApplyAtOnce() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let m = makeModel(env, scanner: { _ in Fakes.stream([]) })
        fill(m, env)
        await m.search()?.value
        #expect(m.phase == .reviewing(incomplete: false))
        #expect(m.setField(.keywords, "piet") == .applied)
        #expect(m.phase == .idle)
        await m.search()?.value
        #expect(m.requestHistory(sampleRun(env)) == .applied)
        #expect(m.phase == .idle)
        #expect(m.keywordsRaw == "piet")
    }

    @Test func historyInIdleFillsTheFormAndStartsNothing() throws {
        let env = try makeEnv(); defer { env.remove() }
        let m = makeModel(env)
        #expect(m.requestHistory(sampleRun(env)) == .applied)
        #expect(m.sourcePath == env.bron.path)
        #expect(m.destPath == env.uit.path)
        #expect(m.keywordsRaw == "piet")
        #expect(m.mode == .move)
        #expect(m.phase == .idle)
        #expect(m.results.isEmpty)
    }

    @Test func historyInReviewingWithResultsNeedsConfirmation() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let m = makeModel(env)
        await reviewed(m, env)
        #expect(m.requestHistory(sampleRun(env)) == .needsConfirmation)
        #expect(m.keywordsRaw == "jan")
        #expect(m.results.count == 3)
        #expect(m.selected.count == 3)
        m.confirmHistory(sampleRun(env))
        #expect(m.phase == .idle)
        #expect(m.results.isEmpty)
        #expect(m.keywordsRaw == "piet")
        #expect(m.mode == .move)
    }

    @Test func doneReturnsToIdleOnAChangeOrClose() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let m = makeModel(env)
        await reviewed(m, env)
        await m.confirm()?.value
        #expect(m.phase == .done)
        #expect(m.requestHistory(sampleRun(env)) == .applied)
        #expect(m.phase == .idle)
        #expect(m.summary == nil)

        await reviewed(m, env)
        await m.confirm()?.value
        #expect(m.setField(.keywords, "piet") == .applied)
        #expect(m.phase == .idle)
        #expect(m.summary == nil)

        await reviewed(m, env)
        await m.confirm()?.value
        m.closeSummary()
        #expect(m.phase == .idle)
        #expect(m.summary == nil)
    }

    // MARK: Destination (F26)

    @Test func anUnusableDestinationAfterTheScanBlocksOK() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let m = makeModel(env, checkDestination: { _ in false })
        await reviewed(m, env)
        #expect(!m.destinationOK)
        #expect(!m.canConfirm)
        #expect(m.confirm() == nil)
    }

    @Test func aDestinationThatBecameUnusableReturnsToReviewing() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let checks = Locked(0)
        let m = makeModel(
            env,
            checkDestination: { _ in
                checks.set(checks.get() + 1)
                return checks.get() == 1
            },
            isUsable: { _ in false })
        await reviewed(m, env)
        m.toggle(env.files[2].url)
        await m.confirm()?.value
        #expect(m.phase == .reviewing(incomplete: false))
        #expect(m.results.count == 3)
        #expect(m.selected.count == 2)
        #expect(m.message != nil)
        #expect(!m.destinationOK)
        #expect(!m.canConfirm)
        #expect(try env.runs().isEmpty)
    }

    @Test func aStaleRecheckDoesNotOverwriteANewerSearch() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let other = env.root.appendingPathComponent("ander-uit")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let gate = Gate()
        let checksOfA = Locked(0)
        let m = makeModel(
            env,
            checkDestination: { url in
                if url.lastPathComponent == "ander-uit" { return false }
                checksOfA.set(checksOfA.get() + 1)
                if checksOfA.get() == 2 { await gate.pass() }
                return true
            },
            isUsable: { _ in false })
        await reviewed(m, env)
        let batch = m.confirm()
        await gate.reached()
        #expect(m.setField(.destination, other.path) == .needsConfirmation)
        m.confirmFormChange(.destination, other.path)
        await m.search()?.value
        #expect(!m.destinationOK)
        gate.open()
        await batch?.value
        #expect(!m.destinationOK)
        #expect(!m.canConfirm)
    }

    // MARK: OK and the batch (F0d, F18)

    @Test func confirmIsAtomic() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let m = makeModel(env)
        await reviewed(m, env)
        let first = m.confirm()
        #expect(first != nil)
        #expect(m.confirm() == nil)
        #expect(m.phase == .processing)
        await first?.value
        #expect(try env.runs().count == 1)
    }

    @Test func theRunFollowsTheSnapshotAtOK() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let m = makeModel(env)
        await reviewed(m, env)
        m.toggle(env.files[1].url)
        await m.confirm()?.value
        let run = try #require(try env.runs().first)
        #expect((run["dest_folder"] as String).hasSuffix("/jan/2001-02-03"))
        #expect(run["found_count"] == 3)
        #expect(run["selected_count"] == 2)
        #expect(run["scan_complete"] == 1)
        #expect(run["skipped_count"] == 1)
        #expect(run["mode"] == "copy")
        #expect(try env.actionSources() == [env.files[0].url.path, env.files[2].url.path])
    }

    @Test func theModeIsLockedWhileProcessing() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let gate = Gate()
        env.hold(file: 1, gate)
        let m = makeModel(env)
        await reviewed(m, env)
        let task = m.confirm()
        await gate.reached()
        #expect(!m.modeEditable)
        #expect(!m.formEditable)
        m.setMode(.move)
        #expect(m.mode == .copy)
        #expect(m.setField(.keywords, "piet") == .refused)
        #expect(m.requestHistory(sampleRun(env)) == .refused)
        gate.open()
        await task?.value
        #expect(try env.runs().first?["mode"] == "copy")
    }

    @Test func progressIsShownWhileProcessing() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let gate = Gate()
        env.hold(file: 2, gate)
        let m = makeModel(env)
        await reviewed(m, env)
        let task = m.confirm()
        await eventually { m.processed == 1 }
        #expect(m.total == 3)
        gate.open()
        await task?.value
        #expect(m.phase == .done)
        #expect(m.processed == 3)
    }

    @Test func progressAfterStopMatchesTheProcessedFiles() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let gate = Gate()
        env.hold(file: 1, gate)
        let m = makeModel(env)
        await reviewed(m, env)
        let task = m.confirm()
        await gate.reached()
        m.stop()
        gate.open()
        await task?.value
        let summary = try #require(m.summary)
        #expect(m.phase == .done)
        #expect(summary.status == .cancelled)
        #expect(m.processed == 1)
        #expect(m.processed == summary.counts.values.reduce(0, +))
        #expect(m.total == 3)
    }

    @Test func progressAfterAnAbortMatchesTheProcessedFiles() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let writer = try RecordingStore(inner: env.store)
        writer.fail(.updateAction, onCall: 2)
        let m = makeModel(env, writer: writer)
        await reviewed(m, env)
        await m.confirm()?.value
        let summary = try #require(m.summary)
        #expect(m.phase == .done)
        #expect(summary.status == .aborted)
        #expect(m.processed == summary.counts.values.reduce(0, +))
        #expect(m.processed <= m.total)
        #expect(m.message != nil)
    }

    @Test func aFinishedBatchShowsTheSummaryAndFreshHistory() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let m = makeModel(env)
        await reviewed(m, env)
        await m.confirm()?.value
        #expect(m.phase == .done)
        #expect(m.summary?.status == .completed)
        #expect(m.summary?.counts == [.copied: 3])
        #expect(m.history.count == 1)
        #expect(m.message == nil)
    }

    @Test func theHistoryIsRefreshedBeforeDone() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let gate = Gate()
        let m = makeModel(
            env,
            loadHistory: { store in
                await gate.pass()
                return try? store.recentRuns(limit: 50)
            })
        await reviewed(m, env)
        let task = m.confirm()
        await gate.reached()
        #expect(m.phase == .processing)
        #expect(m.setField(.keywords, "piet") == .refused)
        gate.open()
        await task?.value
        #expect(m.phase == .done)
        #expect(m.history.count == 1)
        #expect(m.setField(.keywords, "piet") == .applied)
        #expect(m.history.count == 1)
    }

    @Test func aFailedHistoryRefreshKeepsTheOldListAndWarns() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let old = [sampleRun(env)]
        let m = makeModel(
            env, startup: .ready(store: env.store, leftovers: [], history: old), loadHistory: { _ in nil })
        await reviewed(m, env)
        await m.confirm()?.value
        #expect(m.phase == .done)
        #expect(m.summary != nil)
        #expect(m.history == old)
        #expect(m.message?.contains("De geschiedenis kon niet worden ververst") == true)
    }

    @Test func aFatalErrorWithARunEndsInDoneWithAMessage() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let writer = try RecordingStore(inner: env.store)
        writer.fail(.updateAction, onCall: 1)
        let m = makeModel(env, writer: writer)
        await reviewed(m, env)
        await m.confirm()?.value
        #expect(m.phase == .done)
        #expect(m.summary?.runId != nil)
        #expect(m.message != nil)
    }

    @Test func aFailedRunInsertReturnsToReviewing() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let writer = try RecordingStore(inner: env.store)
        writer.fail(.insertRun, onCall: 1)
        let m = makeModel(env, writer: writer)
        await reviewed(m, env)
        await m.confirm()?.value
        #expect(m.phase == .reviewing(incomplete: false))
        #expect(m.results.count == 3)
        #expect(m.selected.count == 3)
        #expect(m.message != nil)
        #expect(m.canConfirm)
        #expect(try env.runs().isEmpty)
    }

    @Test func aRetriedOKAfterACancelledScanWritesAnIncompleteScan() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let writer = try RecordingStore(inner: env.store)
        writer.fail(.insertRun, onCall: 1)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ScanEvent.self, throwing: Error.self)
        let m = makeModel(env, writer: writer, scanner: { _ in stream })
        fill(m, env)
        let scan = m.search()
        continuation.yield(.found([env.files[0]]))
        await eventually { m.results.count == 1 }
        m.cancelScan()
        await scan?.value
        await m.confirm()?.value
        #expect(m.phase == .reviewing(incomplete: true))
        await m.confirm()?.value
        #expect(m.phase == .done)
        #expect(try env.runs().first?["scan_complete"] == 0)
        continuation.finish()
    }

    // MARK: Leftovers (F19d)

    @Test func acknowledgingALeftoverClearsItsTempPath() async throws {
        let env = try makeEnv(); defer { env.remove() }
        let runId = try env.store.insertRun(
            NewRun(
                createdAt: iso8601(Date()), sourcePath: env.bron.path, keywordsRaw: "jan", destRoot: env.uit.path,
                destFolder: env.uit.path, mode: .copy, foundCount: 1, selectedCount: 1, scanComplete: true,
                skippedCount: 0))
        let half = env.uit.appendingPathComponent("a.jpg").path
        let actionId = try env.store.insertAction(
            runId: runId, sourcePath: env.files[0].url.path, destPath: half, tempPath: half, result: .pending,
            error: nil)
        try env.store.finishRun(id: runId, status: .interrupted)
        let leftover = Leftover(actionId: actionId, path: half)
        let m = makeModel(env, startup: .ready(store: env.store, leftovers: [leftover], history: []))
        await m.acknowledgeLeftover(leftover)
        #expect(m.leftovers.isEmpty)
        #expect(try env.store.actions(runId: runId).first?.tempPath == nil)
    }
}
