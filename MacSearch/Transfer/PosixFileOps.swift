import Darwin
import Foundation

final class PosixFileOps: FileOps, Sendable {
    private let capabilityQuery: @Sendable (String) throws(POSIXFailure) -> VolumeCapabilities

    init(
        capabilityQuery: @escaping @Sendable (String) throws(POSIXFailure) -> VolumeCapabilities = PosixFileOps
            .getattrlistQuery
    ) {
        self.capabilityQuery = capabilityQuery
    }

    /// Reads the interfaces capability word of the volume that contains `path`.
    @Sendable static func getattrlistQuery(_ path: String) throws(POSIXFailure) -> VolumeCapabilities {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_CAPABILITIES)
        // Reply layout: u_int32_t length, then vol_capabilities_attr_t { capabilities[4]; valid[4] }.
        let size = MemoryLayout<UInt32>.size + MemoryLayout<vol_capabilities_attr_t>.size
        var buffer = [UInt8](repeating: 0, count: size)
        let rc = buffer.withUnsafeMutableBytes { getattrlist(path, &request, $0.baseAddress, size, 0) }
        guard rc == 0 else { throw POSIXFailure(errno: errno) }
        let index = Int(VOL_CAPABILITIES_INTERFACES)
        return buffer.withUnsafeBytes { bytes in
            VolumeCapabilities(
                capabilities: bytes.loadUnaligned(fromByteOffset: 4 + 4 * index, as: UInt32.self),
                valid: bytes.loadUnaligned(fromByteOffset: 4 + 16 + 4 * index, as: UInt32.self))
        }
    }

    private func check(_ rc: Int32) throws(POSIXFailure) {
        if rc != 0 { throw POSIXFailure(errno: errno) }
    }

    func openRead(_ path: String) throws(POSIXFailure) -> Int32 {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXFailure(errno: errno) }
        return fd
    }

    func createExclusive(_ path: String) throws(POSIXFailure) -> Int32 {
        let fd = open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXFailure(errno: errno) }
        return fd
    }

    func fstatInode(_ fd: Int32) throws(POSIXFailure) -> Inode {
        var st = stat()
        try check(fstat(fd, &st))
        return Inode(dev: UInt64(bitPattern: Int64(st.st_dev)), ino: st.st_ino)
    }

    func lstatInode(_ path: String) throws(POSIXFailure) -> Inode {
        var st = stat()
        try check(lstat(path, &st))
        return Inode(dev: UInt64(bitPattern: Int64(st.st_dev)), ino: st.st_ino)
    }

    func unlink(_ path: String) throws(POSIXFailure) {
        try check(Darwin.unlink(path))
    }

    func renameExclusive(_ from: String, _ to: String) throws(POSIXFailure) {
        try check(renamex_np(from, to, UInt32(RENAME_EXCL)))
    }

    func copyData(from: Int32, to: Int32) throws(POSIXFailure) {
        try check(fcopyfile(from, to, nil, copyfile_flags_t(COPYFILE_DATA)))
    }

    func copyXattrs(from: Int32, to: Int32) throws(POSIXFailure) {
        try check(fcopyfile(from, to, nil, copyfile_flags_t(COPYFILE_XATTR)))
    }

    func setDates(_ fd: Int32, modified: Date, created: Date) throws(POSIXFailure) {
        // Modification time first: setting it earlier than the creation time can move the creation time.
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(modified)]
        try check(futimens(fd, &times))
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        var creation = timespec(created)
        try check(fsetattrlist(fd, &request, &creation, MemoryLayout<timespec>.size, 0))
    }

    func fullFsync(_ fd: Int32) throws(POSIXFailure) {
        if fcntl(fd, F_FULLFSYNC) == -1 { throw POSIXFailure(errno: errno) }
    }

    func size(fd: Int32) throws(POSIXFailure) -> Int64 {
        var st = stat()
        try check(fstat(fd, &st))
        return Int64(st.st_size)
    }

    func dates(path: String) throws(POSIXFailure) -> (modified: Date, created: Date) {
        var st = stat()
        try check(stat(path, &st))
        return (Date(st.st_mtimespec), Date(st.st_birthtimespec))
    }

    func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    func close(_ fd: Int32) {
        _ = Darwin.close(fd)
    }

    func createDirectories(_ path: String) throws(POSIXFailure) {
        if mkdir(path, 0o755) == 0 { return }
        let error = errno
        switch error {
        case EEXIST:
            var st = stat()
            guard stat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { throw POSIXFailure(errno: ENOTDIR) }
        case ENOENT:
            let parent = (path as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != path else { throw POSIXFailure(errno: error) }
            try createDirectories(parent)
            if mkdir(path, 0o755) != 0, errno != EEXIST { throw POSIXFailure(errno: errno) }
        default:
            throw POSIXFailure(errno: error)
        }
    }

    func supportsRenameExclusive(volumeOf dir: String) -> Bool {
        guard let caps = try? capabilityQuery(dir) else { return false }
        return renameExclusiveAllowed(caps)
    }

    func volumeID(_ path: String) -> AnyHashable? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIdentifierKey])
        return (values?.volumeIdentifier as? NSObject).map(AnyHashable.init)
    }
}

private extension timespec {
    init(_ date: Date) {
        let seconds = date.timeIntervalSince1970.rounded(.down)
        self.init(tv_sec: Int(seconds), tv_nsec: Int(((date.timeIntervalSince1970 - seconds) * 1e9).rounded()))
    }
}

private extension Date {
    init(_ ts: timespec) {
        self.init(timeIntervalSince1970: Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9)
    }
}
