import Darwin
import Foundation

enum StartupState: Sendable {
    case ready(store: HistoryStore, leftovers: [Leftover], history: [RunSummary])
    /// F19: a blocking error with the database path; Search and OK stay off.
    case failed(path: String, message: String)
}

/// The work at every start (F19, F19c, F19d). Synchronous; the app runs it in `Task.detached` (NF1).
/// It never removes a file: leftovers are only reported.
enum StartupRoutine {
    static let historyLimit = 50

    static func run(databaseURL: URL, ops: FileOps) -> StartupState {
        do {
            try ops.createDirectories(databaseURL.deletingLastPathComponent().path)
            let store = try HistoryStore(url: databaseURL)
            _ = try store.markRunningInterrupted()
            var leftovers: [Leftover] = []
            for candidate in try store.leftoverCandidates() {
                if ops.exists(candidate.path) {
                    leftovers.append(candidate)
                } else {
                    // Nothing left to report, e.g. published between route B steps 5 and 7.
                    try store.clearTempPath(actionId: candidate.actionId)
                }
            }
            return .ready(store: store, leftovers: leftovers, history: try store.recentRuns(limit: historyLimit))
        } catch let failure as POSIXFailure {
            return .failed(path: databaseURL.path, message: String(cString: strerror(failure.errno)))
        } catch {
            return .failed(path: databaseURL.path, message: String(describing: error))
        }
    }
}
