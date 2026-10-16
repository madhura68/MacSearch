import Foundation

enum TransferMode: String, Sendable {
    case copy, move
}

enum RunStatus: String, Sendable {
    case running, completed, cancelled, aborted, interrupted
}

enum ActionResult: String, Sendable {
    case pending, copied, moved, renamed, skippedIdentical = "skipped_identical", failed
}

/// What an action update does with `temp_path` (spec F19b step 2).
enum TempPathChange: Sendable, Equatable {
    case keep, set(String), clear
}

/// The `search_run` fields fixed at OK (spec F19a).
struct NewRun: Sendable {
    let createdAt: String
    let sourcePath: String
    let keywordsRaw: String
    let destRoot: String
    let destFolder: String
    let mode: TransferMode
    let foundCount: Int
    let selectedCount: Int
    let scanComplete: Bool
    let skippedCount: Int
}

/// The writes the transfer path makes; injectable so tests can make any of them fail.
protocol HistoryWriting: Sendable {
    func insertRun(_ run: NewRun) throws -> Int64
    func finishRun(id: Int64, status: RunStatus) throws
    func insertAction(
        runId: Int64, sourcePath: String, destPath: String?, tempPath: String?, result: ActionResult, error: String?
    ) throws -> Int64
    func updateAction(id: Int64, result: ActionResult, destPath: String?, tempPath: TempPathChange, error: String?) throws
}

/// A file of the app that may be incomplete after a crash (spec F19d).
struct Leftover: Sendable, Hashable, Identifiable {
    let actionId: Int64
    let path: String
    var id: Int64 { actionId }
}

struct RunSummary: Sendable, Hashable, Identifiable {
    let id: Int64
    let createdAt: String
    let keywordsRaw: String
    let sourcePath: String
    let destRoot: String
    let mode: TransferMode
    let status: RunStatus
    /// Actions with a final result (not `pending`).
    let processedCount: Int
    /// Spec F19c: interrupted, aborted or cancelled, an incomplete scan, or skipped items.
    let isIncomplete: Bool
}

struct ActionRow: Sendable, Hashable {
    let id: Int64
    let runId: Int64
    let sourcePath: String
    let destPath: String?
    let tempPath: String?
    let result: ActionResult
    let error: String?
}

/// ISO-8601 timestamps as stored in `created_at` and `finished_at`.
func iso8601(_ date: Date) -> String {
    date.ISO8601Format()
}
