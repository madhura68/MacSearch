import Darwin
import Foundation

struct TransferOutcome: Equatable, Sendable {
    let result: ActionResult
    /// The final name; nil for `failed`.
    let destPath: String?
    /// What goes into `error`: a warning next to a success, the cause of `failed`.
    let warning: String?
}

/// A history write failed, so the batch must stop (spec F19b). `fileProcessed` tells whether this
/// file's transfer had already taken effect:
/// - `false`: the pending insert, an update of the pending record (after `EXDEV` or a collision), or a
///   direct insert of `skipped_identical`/`failed`. The app's own file is cleaned up before the throw.
/// - `true`: route C's `temp_path = NULL` update (the file is complete and the source is kept) and every
///   update to a final result. `outcome` is what the file ended as.
struct StoreWriteFailed: Error {
    let fileProcessed: Bool
    let outcome: TransferOutcome?
}

/// Copies or moves one file without ever overwriting or removing a file that is not the app's
/// (spec NF4). Every file operation goes through `FileOps` (AC3a).
final class FileTransfer: Sendable {
    /// One budget per file for every `EEXIST` collision, temporary and final names alike.
    static let maxCollisions = 3

    private let ops: FileOps
    private let store: HistoryWriting
    private let uuids: UUIDSource
    private let renameExclusive: Bool

    init(ops: FileOps, store: HistoryWriting, uuids: UUIDSource, renameExclusive: Bool) {
        self.ops = ops
        self.store = store
        self.uuids = uuids
        self.renameExclusive = renameExclusive
    }

    func transfer(
        _ file: FoundFile, runId: Int64, destFolder: String, mode: TransferMode
    ) throws(StoreWriteFailed) -> TransferOutcome {
        let job = Job(ops: ops, store: store, uuids: uuids, file: file, runId: runId, destFolder: destFolder, mode: mode)
        defer { job.closeDescriptors() }
        do {
            return try job.run(renameExclusive: renameExclusive)
        } catch let error as StoreWriteFailed {
            throw error
        } catch {
            return try job.fail(error)
        }
    }
}

private struct CollisionBudgetSpent: Error {}

private struct OwnFile {
    let fd: Int32
    let path: String
}

/// The state of one transfer. File operations happen in this order, which fault-injection tests
/// count on: F16 (`exists`, `openRead` of a candidate, then of the source for its hash) comes before
/// any exclusive create; the source is opened only in the copy step.
private final class Job {
    let ops: FileOps
    let store: HistoryWriting
    let uuids: UUIDSource
    let file: FoundFile
    let runId: Int64
    let destFolder: String
    let mode: TransferMode
    let desiredPath: String

    /// The chosen final name.
    var dest: String
    /// The one record of this file, once it exists.
    var actionId: Int64?
    var collisions = 0
    /// The app's own, not yet published file; the only file Opruimen may remove.
    var own: OwnFile?
    var sourceFd: Int32?

    var sourcePath: String { file.url.path }

    init(
        ops: FileOps, store: HistoryWriting, uuids: UUIDSource, file: FoundFile, runId: Int64, destFolder: String,
        mode: TransferMode
    ) {
        self.ops = ops
        self.store = store
        self.uuids = uuids
        self.file = file
        self.runId = runId
        self.destFolder = destFolder
        self.mode = mode
        desiredPath = destFolder + "/" + file.url.lastPathComponent
        dest = desiredPath
    }

    func run(renameExclusive: Bool) throws -> TransferOutcome {
        switch try resolve() {
        case .identical(let path): return try skipIdentical(path)
        case .free(let path): dest = path
        }
        if mode == .move && renameExclusive && sameVolume() {
            if let outcome = try routeA() { return outcome }
            return try routeB()  // EXDEV: route B with the same record and attempt budget
        }
        return renameExclusive ? try routeB() : try routeC()
    }

    // MARK: Routes (NF4)

    /// Move within one volume. Returns nil on `EXDEV`.
    func routeA() throws -> TransferOutcome? {
        try recordPending(tempPath: nil)
        while true {
            do throws(POSIXFailure) {
                try ops.renameExclusive(sourcePath, dest)
            } catch {
                switch error.errno {
                case EEXIST:
                    if let outcome = try retry() { return outcome }
                    continue
                case EXDEV:
                    return nil
                default:
                    throw error
                }
            }
            return try finish()
        }
    }

    /// Copy, or move to another volume, through `.macsearch-<UUID>.tmp`.
    func routeB() throws -> TransferOutcome {
        var temp: OwnFile
        while true {
            let path = destFolder + "/.macsearch-\(uuids.next().uuidString).tmp"
            do throws(POSIXFailure) {
                let fd = try ops.createExclusive(path)
                temp = OwnFile(fd: fd, path: path)
                break
            } catch {
                guard error.errno == EEXIST else { throw error }
                try countCollision()
            }
        }
        own = temp
        try recordPending(tempPath: temp.path)
        try copy(to: temp.fd)
        // A collision on the final name retries the publication only; the copy is reused.
        while true {
            do throws(POSIXFailure) {
                try ops.renameExclusive(temp.path, dest)
            } catch {
                guard error.errno == EEXIST else { throw error }
                if let outcome = try retry() { return outcome }
                continue
            }
            break
        }
        published()
        if mode == .move { try ops.unlink(sourcePath) }
        return try finish()
    }

    /// No `RENAME_EXCL`: the final file itself is created exclusively and filled.
    func routeC() throws -> TransferOutcome {
        var target: OwnFile
        while true {
            do throws(POSIXFailure) {
                let fd = try ops.createExclusive(dest)
                target = OwnFile(fd: fd, path: dest)
                break
            } catch {
                guard error.errno == EEXIST else { throw error }
                if let outcome = try retry() { return outcome }
            }
        }
        own = target
        let id = try recordPending(tempPath: target.path)
        try copy(to: target.fd)
        do {
            try store.updateAction(id: id, result: .pending, destPath: dest, tempPath: .clear, error: nil)
        } catch {
            // The complete file stays and is reported at the next start (F19d); the source is kept.
            own = nil
            let outcome = TransferOutcome(result: mode == .move ? .copied : successResult, destPath: dest, warning: nil)
            throw StoreWriteFailed(fileProcessed: true, outcome: outcome)
        }
        published()
        if mode == .move { try ops.unlink(sourcePath) }
        return try finish()
    }

    // MARK: Steps

    func resolve() throws -> Resolution {
        try ConflictResolver(ops: ops).resolve(sourcePath: sourcePath, sourceSize: file.size, desiredPath: desiredPath)
    }

    /// Route A only when both volumes are known and equal.
    func sameVolume() -> Bool {
        guard let source = ops.volumeID(sourcePath), let destination = ops.volumeID(destFolder) else { return false }
        return source == destination
    }

    func countCollision() throws {
        collisions += 1
        if collisions >= FileTransfer.maxCollisions { throw CollisionBudgetSpent() }
    }

    /// After `EEXIST` on the final name: F16 again. Returns the outcome when the file is done, or nil to
    /// publish under the new `dest`.
    func retry() throws -> TransferOutcome? {
        try countCollision()
        switch try resolve() {
        case .identical(let path):
            return try skipIdentical(path)
        case .free(let path):
            dest = path
            if let actionId {
                try pendingWrite {
                    try store.updateAction(id: actionId, result: .pending, destPath: path, tempPath: .keep, error: nil)
                }
            }
            return nil
        }
    }

    /// A2, B3 and C3: the pending record, before the first byte. After `EXDEV` in route A the record
    /// already exists and gets the temporary file.
    @discardableResult
    func recordPending(tempPath: String?) throws(StoreWriteFailed) -> Int64 {
        if let actionId {
            try pendingWrite {
                try store.updateAction(
                    id: actionId, result: .pending, destPath: dest, tempPath: tempPath.map { .set($0) } ?? .keep,
                    error: nil)
            }
            return actionId
        }
        let id = try pendingWrite {
            try store.insertAction(
                runId: runId, sourcePath: sourcePath, destPath: dest, tempPath: tempPath, result: .pending, error: nil)
        }
        actionId = id
        return id
    }

    func pendingWrite<T>(_ body: () throws -> T) throws(StoreWriteFailed) -> T {
        do {
            return try body()
        } catch {
            _ = cleanUp()
            throw StoreWriteFailed(fileProcessed: false, outcome: nil)
        }
    }

    /// B4 and C4: data, extended attributes and dates through the descriptors; for a move the flush.
    func copy(to fd: Int32) throws {
        let source = try ops.openRead(sourcePath)
        sourceFd = source
        try ops.copyData(from: source, to: fd)
        try ops.copyXattrs(from: source, to: fd)
        let dates = try ops.dates(path: sourcePath)
        try ops.setDates(fd, modified: dates.modified, created: dates.created)
        if mode == .move { try ops.fullFsync(fd) }
    }

    /// The own file now carries the final name and is no longer the app's to remove.
    func published() {
        if let own { ops.close(own.fd) }
        own = nil
    }

    var successResult: ActionResult {
        mode == .move ? .moved : (dest == desiredPath ? .copied : .renamed)
    }

    func finish() throws(StoreWriteFailed) -> TransferOutcome {
        let outcome = TransferOutcome(result: successResult, destPath: dest, warning: nil)
        try record(outcome, tempPath: .clear)
        return outcome
    }

    func skipIdentical(_ path: String) throws(StoreWriteFailed) -> TransferOutcome {
        let tempPath = cleanUp()
        let outcome = TransferOutcome(result: .skippedIdentical, destPath: path, warning: nil)
        try record(outcome, tempPath: tempPath)
        return outcome
    }

    /// A file-level failure (F17): clean up the own file, keep the source, record `failed`.
    func fail(_ error: Error) throws(StoreWriteFailed) -> TransferOutcome {
        let tempPath = cleanUp()
        let outcome = TransferOutcome(result: .failed, destPath: nil, warning: Self.message(error))
        try record(outcome, tempPath: tempPath)
        return outcome
    }

    /// The write of the final result: an update of the record, or a direct insert when no record
    /// exists yet (route C before step 3, or a decision before any own file).
    func record(_ outcome: TransferOutcome, tempPath: TempPathChange) throws(StoreWriteFailed) {
        do {
            if let actionId {
                try store.updateAction(
                    id: actionId, result: outcome.result, destPath: outcome.destPath ?? dest, tempPath: tempPath,
                    error: outcome.warning)
            } else {
                _ = try store.insertAction(
                    runId: runId, sourcePath: sourcePath, destPath: outcome.destPath ?? dest, tempPath: nil,
                    result: outcome.result, error: outcome.warning)
            }
        } catch {
            throw actionId == nil
                ? StoreWriteFailed(fileProcessed: false, outcome: nil)
                : StoreWriteFailed(fileProcessed: true, outcome: outcome)
        }
    }

    /// NF4 Opruimen: removes the own file only while its descriptor is open and the path still names
    /// the same device and inode. Returns what happens to `temp_path`.
    func cleanUp() -> TempPathChange {
        guard let file = own else { return .keep }
        own = nil
        defer { ops.close(file.fd) }
        guard let opened = try? ops.fstatInode(file.fd), let named = try? ops.lstatInode(file.path),
            opened == named
        else { return .keep }
        do {
            try ops.unlink(file.path)
        } catch {
            return .keep
        }
        return .clear
    }

    func closeDescriptors() {
        if let own { ops.close(own.fd) }
        if let sourceFd { ops.close(sourceFd) }
        own = nil
        sourceFd = nil
    }

    static func message(_ error: Error) -> String {
        switch error {
        case let failure as POSIXFailure: String(cString: strerror(failure.errno))
        case is CollisionBudgetSpent: "Geen vrije doelnaam na \(FileTransfer.maxCollisions) pogingen"
        default: String(describing: error)
        }
    }
}
