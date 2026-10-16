import Foundation
import Observation

enum Phase: Equatable, Sendable {
    case idle, scanning, reviewing(incomplete: Bool), processing, done
}

enum FormField: Sendable {
    case source, destination, keywords
}

enum ChangeResult: Sendable {
    case applied, needsConfirmation, refused
}

/// The state model of F0b–F0d. All I/O goes through the injected closures and runs off the main actor.
///
/// Every entry point that starts work (`search`, `confirm`) does its guard, phase change and snapshot
/// synchronously. `generation` grows with every search, OK and form change; an async continuation only
/// writes state while the generation it started with is still current. Cancelling does not change it,
/// so a cancelled scan still delivers its partial results (F0c).
@MainActor
@Observable
final class AppModel {
    private(set) var sourcePath: String?
    private(set) var destPath: String?
    private(set) var keywordsRaw = ""
    private(set) var mode: TransferMode = .copy
    private(set) var phase: Phase = .idle
    private(set) var results: [FoundFile] = []
    private(set) var selected: Set<URL> = []
    private(set) var scanned = 0
    private(set) var skipped = 0
    private(set) var summary: BatchSummary?
    private(set) var startupError: (path: String, message: String)?
    private(set) var leftovers: [Leftover] = []
    /// From the start routine; refreshed as the last step of a batch, still in `processing`.
    private(set) var history: [RunSummary] = []
    /// False when a scan starts and after the batch found the destination unusable; set by `checkDestination`.
    private(set) var destinationOK = false
    private(set) var processed = 0
    private(set) var total = 0
    /// Of the last search context (F27 warning).
    private(set) var containment: Containment = .none
    private(set) var message: String?

    @ObservationIgnored private let store: HistoryStore?
    @ObservationIgnored private let scanner: @Sendable (SearchContext) -> AsyncThrowingStream<ScanEvent, Error>
    @ObservationIgnored private let makeBatch: @Sendable (HistoryStore) -> TransferBatch
    @ObservationIgnored private let checkDestination: @Sendable (URL) async -> Bool
    @ObservationIgnored private let makeContext:
        @Sendable (URL, String, URL) async throws(SearchValidationError) -> SearchContext
    @ObservationIgnored private let loadHistory: @Sendable (HistoryStore) async -> [RunSummary]?
    @ObservationIgnored private let now: @Sendable () -> Date

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var batchTask: Task<Void, Never>?
    @ObservationIgnored private var context: SearchContext?
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var streamFinished = false
    @ObservationIgnored private var scanComplete = true
    @ObservationIgnored private var stopFlag: StopFlag?

    init(
        startup: StartupState,
        scanner: @escaping @Sendable (SearchContext) -> AsyncThrowingStream<ScanEvent, Error>,
        batch: @escaping @Sendable (HistoryStore) -> TransferBatch,
        checkDestination: @escaping @Sendable (URL) async -> Bool,
        makeContext: @escaping @Sendable (URL, String, URL) async throws(SearchValidationError) -> SearchContext,
        loadHistory: @escaping @Sendable (HistoryStore) async -> [RunSummary]?,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        switch startup {
        case .ready(let store, let leftovers, let history):
            self.store = store
            self.leftovers = leftovers
            self.history = history
        case .failed(let path, let message):
            store = nil
            startupError = (path, message)
        }
        self.scanner = scanner
        makeBatch = batch
        self.checkDestination = checkDestination
        self.makeContext = makeContext
        self.loadHistory = loadHistory
        self.now = now
    }

    // MARK: Derived state

    private var isReviewing: Bool {
        if case .reviewing = phase { true } else { false }
    }

    var canSearch: Bool {
        startupError == nil && sourcePath != nil && destPath != nil && (phase == .idle || isReviewing)
    }

    /// F13 and F26; no I/O.
    var canConfirm: Bool {
        startupError == nil && isReviewing && !selected.isEmpty && destinationOK
    }

    var formEditable: Bool {
        phase != .scanning && phase != .processing
    }

    var modeEditable: Bool {
        phase != .processing
    }

    // MARK: Form

    func setField(_ field: FormField, _ value: String) -> ChangeResult {
        let result = changeResult()
        if result == .applied {
            leaveForIdle()
            assign(field, value)
        }
        return result
    }

    func confirmFormChange(_ field: FormField, _ value: String) {
        guard formEditable else { return }
        leaveForIdle()
        assign(field, value)
    }

    func setMode(_ mode: TransferMode) {
        guard modeEditable else { return }
        self.mode = mode
    }

    func requestHistory(_ run: RunSummary) -> ChangeResult {
        let result = changeResult()
        if result == .applied { fill(from: run) }
        return result
    }

    func confirmHistory(_ run: RunSummary) {
        guard formEditable else { return }
        fill(from: run)
    }

    /// F0b: a change applies in idle and done, needs confirmation while there are results to lose, and
    /// is refused while a scan or batch runs.
    private func changeResult() -> ChangeResult {
        switch phase {
        case .scanning, .processing: .refused
        case .reviewing: results.isEmpty ? .applied : .needsConfirmation
        case .idle, .done: .applied
        }
    }

    private func assign(_ field: FormField, _ value: String) {
        switch field {
        case .source: sourcePath = value.isEmpty ? nil : value
        case .destination: destPath = value.isEmpty ? nil : value
        case .keywords: keywordsRaw = value
        }
    }

    private func fill(from run: RunSummary) {
        leaveForIdle()
        sourcePath = run.sourcePath
        destPath = run.destRoot
        keywordsRaw = run.keywordsRaw
        mode = run.mode
    }

    /// Drops the results and the summary of the current context and invalidates its continuations.
    private func leaveForIdle() {
        generation += 1
        phase = .idle
        results = []
        selected = []
        scanned = 0
        skipped = 0
        summary = nil
        context = nil
        containment = .none
        destinationOK = false
    }

    // MARK: Selection (F12)

    func toggle(_ url: URL) {
        guard phase != .processing else { return }
        if selected.contains(url) { selected.remove(url) } else { selected.insert(url) }
    }

    func selectAll() {
        guard phase != .processing else { return }
        selected = Set(results.map(\.url))
    }

    func selectNone() {
        guard phase != .processing else { return }
        selected = []
    }

    func discardResults() {
        guard isReviewing else { return }
        leaveForIdle()
    }

    // MARK: Search

    @discardableResult
    func search() -> Task<Void, Never>? {
        guard canSearch, let sourcePath, let destPath else { return nil }
        generation += 1
        let gen = generation
        let source = URL(fileURLWithPath: sourcePath)
        let destination = URL(fileURLWithPath: destPath)
        let keywords = keywordsRaw
        phase = .scanning
        results = []
        selected = []
        scanned = 0
        skipped = 0
        message = nil
        summary = nil
        context = nil
        destinationOK = false
        cancelRequested = false
        streamFinished = false
        let task = Task {
            await scan(gen: gen, source: source, keywords: keywords, destination: destination)
            if generation == gen { scanTask = nil }
        }
        scanTask = task
        return task
    }

    func cancelScan() {
        guard phase == .scanning, !streamFinished else { return }
        cancelRequested = true
        scanTask?.cancel()
    }

    private func scan(gen: Int, source: URL, keywords: String, destination: URL) async {
        let made: SearchContext
        do throws(SearchValidationError) {
            made = try await makeContext(source, keywords, destination)
        } catch {
            guard generation == gen else { return }
            message = Self.validationMessage(error)
            phase = .idle
            return
        }
        guard generation == gen else { return }
        // Cancelled before the scan began: as if Search was never pressed.
        if cancelRequested || Task.isCancelled {
            phase = .idle
            return
        }
        context = made
        containment = made.containment

        var scannerFailed = false
        do {
            for try await event in scanner(made) {
                guard generation == gen else { return }
                switch event {
                case .found(let files):
                    results.append(contentsOf: files)
                    selected.formUnion(files.map(\.url))
                case .progress(let scannedCount, let skippedCount):
                    scanned = scannedCount
                    skipped = skippedCount
                }
            }
        } catch {
            guard generation == gen else { return }
            if !cancelRequested {
                scannerFailed = true
                message = "De scan is afgebroken: \(error.localizedDescription)"
            }
        }
        guard generation == gen else { return }
        streamFinished = true
        let incomplete = cancelRequested || scannerFailed
        scanComplete = !incomplete

        let usable = await checkDestination(made.destRoot)
        guard generation == gen else { return }
        destinationOK = usable
        phase = .reviewing(incomplete: incomplete)
    }

    static func validationMessage(_ error: SearchValidationError) -> String {
        switch error {
        case .sameFolder: "Kies een andere bestemming of een submap"
        case .sourceMissing: "De bronmap bestaat niet of is geen map."
        case .destinationUnusable: "De bestemming bestaat niet of is niet schrijfbaar."
        case .noKeywords: "Geef ten minste één keyword op."
        case .folderNameTooLong: "De keywords geven een mapnaam die te lang is."
        }
    }

    // MARK: OK and the batch (F0d, F18)

    @discardableResult
    func confirm() -> Task<Void, Never>? {
        guard canConfirm, let store, let context else { return nil }
        generation += 1
        let gen = generation
        let confirmedAt = now()
        let files = results.filter { selected.contains($0.url) }
        let snapshot = Snapshot(
            mode: mode, files: files, foundCount: results.count, scanComplete: scanComplete, skippedCount: skipped)
        let stop = StopFlag()
        stopFlag = stop
        processed = 0
        total = files.count
        message = nil
        phase = .processing
        let batch = makeBatch(store)
        let task = Task {
            await process(
                gen: gen, batch: batch, store: store, context: context, snapshot: snapshot, confirmedAt: confirmedAt,
                stop: stop)
            if generation == gen { batchTask = nil }
        }
        batchTask = task
        return task
    }

    func stop() {
        guard phase == .processing else { return }
        stopFlag?.stop()
    }

    private struct Snapshot: Sendable {
        let mode: TransferMode
        let files: [FoundFile]
        let foundCount: Int
        let scanComplete: Bool
        let skippedCount: Int
    }

    private func process(
        gen: Int, batch: TransferBatch, store: HistoryStore, context: SearchContext, snapshot: Snapshot,
        confirmedAt: Date, stop: StopFlag
    ) async {
        let summary = await batch.run(
            context: context, files: snapshot.files, mode: snapshot.mode, confirmedAt: confirmedAt,
            foundCount: snapshot.foundCount, scanComplete: snapshot.scanComplete, skippedCount: snapshot.skippedCount,
            stop: stop,
            progress: { [weak self] done, _ in
                Task { @MainActor in self?.advance(to: done, gen: gen) }
            })
        guard generation == gen else { return }

        switch summary.fatalCause {
        case .destinationUnusable:
            phase = .reviewing(incomplete: !snapshot.scanComplete)
            message = summary.fatalError
            destinationOK = false
            let usable = await checkDestination(context.destRoot)
            guard generation == gen else { return }
            destinationOK = usable
            return
        case .runInsertFailed:
            phase = .reviewing(incomplete: !snapshot.scanComplete)
            message = summary.fatalError
            return
        case .aborted, nil:
            break
        }

        // Still in processing: no form change can drop the refresh of the run that just ended.
        let refreshed = await loadHistory(store)
        if let refreshed { history = refreshed }
        guard generation == gen else { return }
        var messages = summary.fatalError.map { [$0] } ?? []
        if refreshed == nil { messages.append("De geschiedenis kon niet worden ververst") }
        message = messages.isEmpty ? nil : messages.joined(separator: "\n")
        self.summary = summary
        processed = summary.counts.values.reduce(0, +)
        phase = .done
    }

    /// A progress jump never moves the bar back and is ignored once the batch has published done.
    private func advance(to done: Int, gen: Int) {
        guard phase == .processing, generation == gen else { return }
        processed = max(processed, done)
    }

    func closeSummary() {
        guard phase == .done else { return }
        leaveForIdle()
    }

    func dismissMessage() {
        message = nil
    }

    // MARK: Leftovers (F19d)

    func acknowledgeLeftover(_ leftover: Leftover) async {
        guard let store else { return }
        let cleared = await Task.detached {
            (try? store.clearTempPath(actionId: leftover.actionId)) != nil
        }.value
        if cleared {
            leftovers.removeAll { $0 == leftover }
        } else {
            message = "Het restant kon niet als afgehandeld worden vastgelegd."
        }
    }
}
