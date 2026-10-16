import Foundation
import Synchronization
@testable import MacSearch

struct InjectedStoreFailure: Error, Equatable {}

/// Wraps an in-memory `HistoryStore`: logs every write attempt and can make any write fail,
/// on every call or only on the n-th (AC3a, AC4).
final class RecordingStore: HistoryWriting, Sendable {
    enum Write: Hashable, Sendable {
        case insertRun, finishRun, insertAction, updateAction
    }

    enum Call: Equatable, Sendable {
        case insertRun
        case finishRun(RunStatus)
        case insertAction(result: ActionResult, destPath: String?, tempPath: String?)
        case updateAction(result: ActionResult, destPath: String?, tempPath: TempPathChange)
    }

    private struct State {
        var calls: [Call] = []
        var counts: [Write: Int] = [:]
        var failures: [Write: Int?] = [:]
    }

    let inner: HistoryStore
    private let state = Mutex(State())

    init(inner: HistoryStore? = nil) throws {
        self.inner = try inner ?? HistoryStore.inMemory()
    }

    /// Fail `write` with `InjectedStoreFailure`; on every call, or only on the n-th call (1-based).
    func fail(_ write: Write, onCall: Int? = nil) {
        state.withLock { $0.failures[write] = .some(onCall) }
    }

    var calls: [Call] {
        state.withLock { $0.calls }
    }

    func count(_ write: Write) -> Int {
        state.withLock { $0.counts[write, default: 0] }
    }

    func actions(runId: Int64) throws -> [ActionRow] {
        try inner.actions(runId: runId)
    }

    private func record(_ write: Write, _ call: Call) throws {
        let fails = state.withLock { state in
            state.calls.append(call)
            let n = state.counts[write, default: 0] + 1
            state.counts[write] = n
            guard let failure = state.failures[write] else { return false }
            return failure == nil || failure == n
        }
        if fails { throw InjectedStoreFailure() }
    }

    // MARK: HistoryWriting

    func insertRun(_ run: NewRun) throws -> Int64 {
        try record(.insertRun, .insertRun)
        return try inner.insertRun(run)
    }

    func finishRun(id: Int64, status: RunStatus) throws {
        try record(.finishRun, .finishRun(status))
        try inner.finishRun(id: id, status: status)
    }

    func insertAction(
        runId: Int64, sourcePath: String, destPath: String?, tempPath: String?, result: ActionResult, error: String?
    ) throws -> Int64 {
        try record(.insertAction, .insertAction(result: result, destPath: destPath, tempPath: tempPath))
        return try inner.insertAction(
            runId: runId, sourcePath: sourcePath, destPath: destPath, tempPath: tempPath, result: result, error: error)
    }

    func updateAction(id: Int64, result: ActionResult, destPath: String?, tempPath: TempPathChange, error: String?) throws {
        try record(.updateAction, .updateAction(result: result, destPath: destPath, tempPath: tempPath))
        try inner.updateAction(id: id, result: result, destPath: destPath, tempPath: tempPath, error: error)
    }
}
