import Darwin
import Foundation

struct POSIXFailure: Error, Equatable {
    let errno: Int32
}

struct Inode: Equatable, Sendable {
    let dev: UInt64
    let ino: UInt64
}

/// Every file operation of `FileTransfer` goes through this protocol (AC3a), so tests can inject
/// failures and hooks at each step while still running on real files.
protocol FileOps: Sendable {
    func openRead(_ path: String) throws(POSIXFailure) -> Int32
    /// `O_CREAT|O_EXCL|O_WRONLY`.
    func createExclusive(_ path: String) throws(POSIXFailure) -> Int32
    func fstatInode(_ fd: Int32) throws(POSIXFailure) -> Inode
    func lstatInode(_ path: String) throws(POSIXFailure) -> Inode
    func unlink(_ path: String) throws(POSIXFailure)
    /// `renamex_np` with `RENAME_EXCL`: never replaces an existing target.
    func renameExclusive(_ from: String, _ to: String) throws(POSIXFailure)
    /// `fcopyfile` with `COPYFILE_DATA`.
    func copyData(from: Int32, to: Int32) throws(POSIXFailure)
    /// `fcopyfile` with `COPYFILE_XATTR`.
    func copyXattrs(from: Int32, to: Int32) throws(POSIXFailure)
    /// `futimens` and `fsetattrlist` with `ATTR_CMN_CRTIME`, via the descriptor, never the path.
    func setDates(_ fd: Int32, modified: Date, created: Date) throws(POSIXFailure)
    /// `fcntl(F_FULLFSYNC)`.
    func fullFsync(_ fd: Int32) throws(POSIXFailure)
    func size(fd: Int32) throws(POSIXFailure) -> Int64
    func dates(path: String) throws(POSIXFailure) -> (modified: Date, created: Date)
    /// True when something exists at the path, a dangling symlink included.
    func exists(_ path: String) -> Bool
    func close(_ fd: Int32)
    /// `mkdir -p`.
    func createDirectories(_ path: String) throws(POSIXFailure)
    /// `VOL_CAP_INT_RENAME_EXCL`, counted only when its valid bit is set; a failing query means false.
    func supportsRenameExclusive(volumeOf dir: String) -> Bool
    func volumeID(_ path: String) -> AnyHashable?
}

protocol UUIDSource: Sendable {
    func next() -> UUID
}

struct SystemUUIDSource: UUIDSource {
    func next() -> UUID { UUID() }
}

/// The `VOL_CAPABILITIES_INTERFACES` word of `vol_capabilities_attr_t`.
struct VolumeCapabilities: Sendable {
    let capabilities: UInt32
    let valid: UInt32
}

func renameExclusiveAllowed(_ caps: VolumeCapabilities) -> Bool {
    let bit = UInt32(VOL_CAP_INT_RENAME_EXCL)
    return caps.capabilities & bit != 0 && caps.valid & bit != 0
}
