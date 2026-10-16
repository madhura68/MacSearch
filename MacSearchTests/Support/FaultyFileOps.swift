import Foundation
import Synchronization
@testable import MacSearch

/// Wraps `PosixFileOps` with per-method fault injection, before-hooks, forced volume
/// capability, volume-ID overrides and call counters (AC3a).
final class FaultyFileOps: FileOps, Sendable {
    enum Op: Hashable, Sendable {
        case openRead, createExclusive, fstatInode, lstatInode, unlink, renameExclusive, copyData, copyXattrs
        case setDates, fullFsync, size, dates, exists, close, createDirectories, supportsRenameExclusive, volumeID
    }

    /// The arguments of an intercepted call, handed to before-hooks.
    enum Call: Sendable {
        case path(String)
        case paths(String, String)
        case fd(Int32)
        case fds(from: Int32, to: Int32)
    }

    typealias Hook = @Sendable (Call) throws(POSIXFailure) -> Void

    private struct Failure {
        let error: POSIXFailure
        let onCall: Int?
    }

    private struct State {
        var failures: [Op: Failure] = [:]
        var hooks: [Op: Hook] = [:]
        var counts: [Op: Int] = [:]
        var forcedRenameExclusive: Bool?
        var volumeIDOverrides: [String: String] = [:]
        var createdPaths: [Int32: String] = [:]
    }

    let base: PosixFileOps
    private let state = Mutex(State())

    init(base: PosixFileOps = PosixFileOps()) {
        self.base = base
    }

    // MARK: Configuration

    /// Fail `op` with `errno`; on every call, or only on the n-th call (1-based).
    func fail(_ op: Op, errno: Int32, onCall: Int? = nil) {
        state.withLock { $0.failures[op] = Failure(error: POSIXFailure(errno: errno), onCall: onCall) }
    }

    func clearFailure(_ op: Op) {
        state.withLock { $0.failures[op] = nil }
    }

    /// Runs before the real call; may perform side effects or throw to inject a failure.
    func before(_ op: Op, _ hook: @escaping Hook) {
        state.withLock { $0.hooks[op] = hook }
    }

    func forceRenameExclusive(_ value: Bool?) {
        state.withLock { $0.forcedRenameExclusive = value }
    }

    /// Paths starting with `prefix` report `id` as their volume (the longest matching prefix wins).
    func overrideVolumeID(prefix: String, id: String) {
        state.withLock { $0.volumeIDOverrides[prefix] = id }
    }

    func count(_ op: Op) -> Int {
        state.withLock { $0.counts[op, default: 0] }
    }

    /// The path that `createExclusive` created for this descriptor.
    func createdPath(fd: Int32) -> String? {
        state.withLock { $0.createdPaths[fd] }
    }

    // MARK: Interception

    private func intercept(_ op: Op, _ call: Call) throws(POSIXFailure) {
        let (failure, hook): (POSIXFailure?, Hook?) = state.withLock { state in
            let n = state.counts[op, default: 0] + 1
            state.counts[op] = n
            var failure: POSIXFailure?
            if let f = state.failures[op], f.onCall == nil || f.onCall == n {
                failure = f.error
            }
            return (failure, state.hooks[op])
        }
        if let hook { try hook(call) }
        if let failure { throw failure }
    }

    private func countOnly(_ op: Op) {
        state.withLock { $0.counts[op, default: 0] += 1 }
    }

    // MARK: FileOps

    func openRead(_ path: String) throws(POSIXFailure) -> Int32 {
        try intercept(.openRead, .path(path))
        return try base.openRead(path)
    }

    func createExclusive(_ path: String) throws(POSIXFailure) -> Int32 {
        try intercept(.createExclusive, .path(path))
        let fd = try base.createExclusive(path)
        state.withLock { $0.createdPaths[fd] = path }
        return fd
    }

    func fstatInode(_ fd: Int32) throws(POSIXFailure) -> Inode {
        try intercept(.fstatInode, .fd(fd))
        return try base.fstatInode(fd)
    }

    func lstatInode(_ path: String) throws(POSIXFailure) -> Inode {
        try intercept(.lstatInode, .path(path))
        return try base.lstatInode(path)
    }

    func unlink(_ path: String) throws(POSIXFailure) {
        try intercept(.unlink, .path(path))
        try base.unlink(path)
    }

    func renameExclusive(_ from: String, _ to: String) throws(POSIXFailure) {
        try intercept(.renameExclusive, .paths(from, to))
        try base.renameExclusive(from, to)
    }

    func copyData(from: Int32, to: Int32) throws(POSIXFailure) {
        try intercept(.copyData, .fds(from: from, to: to))
        try base.copyData(from: from, to: to)
    }

    func copyXattrs(from: Int32, to: Int32) throws(POSIXFailure) {
        try intercept(.copyXattrs, .fds(from: from, to: to))
        try base.copyXattrs(from: from, to: to)
    }

    func setDates(_ fd: Int32, modified: Date, created: Date) throws(POSIXFailure) {
        try intercept(.setDates, .fd(fd))
        try base.setDates(fd, modified: modified, created: created)
    }

    func fullFsync(_ fd: Int32) throws(POSIXFailure) {
        try intercept(.fullFsync, .fd(fd))
        try base.fullFsync(fd)
    }

    func size(fd: Int32) throws(POSIXFailure) -> Int64 {
        try intercept(.size, .fd(fd))
        return try base.size(fd: fd)
    }

    func dates(path: String) throws(POSIXFailure) -> (modified: Date, created: Date) {
        try intercept(.dates, .path(path))
        return try base.dates(path: path)
    }

    func exists(_ path: String) -> Bool {
        countOnly(.exists)
        return base.exists(path)
    }

    func close(_ fd: Int32) {
        countOnly(.close)
        state.withLock { _ = $0.createdPaths.removeValue(forKey: fd) }
        base.close(fd)
    }

    func createDirectories(_ path: String) throws(POSIXFailure) {
        try intercept(.createDirectories, .path(path))
        try base.createDirectories(path)
    }

    func supportsRenameExclusive(volumeOf dir: String) -> Bool {
        countOnly(.supportsRenameExclusive)
        if let forced = state.withLock({ $0.forcedRenameExclusive }) { return forced }
        return base.supportsRenameExclusive(volumeOf: dir)
    }

    func volumeID(_ path: String) -> AnyHashable? {
        countOnly(.volumeID)
        let override = state.withLock { state in
            state.volumeIDOverrides
                .filter { path.hasPrefix($0.key) }
                .max { $0.key.count < $1.key.count }?.value
        }
        return override.map(AnyHashable.init) ?? base.volumeID(path)
    }
}
