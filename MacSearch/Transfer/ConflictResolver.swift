import CryptoKit
import Darwin
import Foundation

enum Resolution: Equatable, Sendable {
    case free(String)
    case identical(String)
}

/// Finder-style conflict resolution (spec F16): try `naam`, `naam (2)`, `naam (3)`, … in order,
/// up to and including the first free name. A candidate with the same size and SHA-256 as the
/// source is identical; candidates beyond the first free name are never looked at.
struct ConflictResolver: Sendable {
    let ops: FileOps

    static let maxCandidates = 10_000

    func resolve(sourcePath: String, sourceSize: Int64, desiredPath: String) throws -> Resolution {
        var sourceHash: Data?
        for n in 1...Self.maxCandidates {
            let candidate = Self.candidate(desiredPath, n)
            guard ops.exists(candidate) else { return .free(candidate) }
            guard try size(of: candidate) == sourceSize else { continue }
            if sourceHash == nil {
                sourceHash = try ContentHasher.sha256(path: sourcePath, ops: ops)
            }
            if try ContentHasher.sha256(path: candidate, ops: ops) == sourceHash {
                return .identical(candidate)
            }
        }
        throw POSIXFailure(errno: EEXIST)
    }

    /// `n == 1` is the desired name itself; otherwise `name (n).ext`.
    static func candidate(_ desiredPath: String, _ n: Int) -> String {
        guard n > 1 else { return desiredPath }
        let path = desiredPath as NSString
        let name = path.lastPathComponent as NSString
        let ext = name.pathExtension
        let numbered = "\(name.deletingPathExtension) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
        return path.deletingLastPathComponent.appending("/" + numbered)
    }

    private func size(of path: String) throws -> Int64 {
        let fd = try ops.openRead(path)
        defer { ops.close(fd) }
        return try ops.size(fd: fd)
    }
}

enum ContentHasher {
    static let blockSize = 1 << 20

    /// Streaming SHA-256 in blocks of 1 MiB.
    static func sha256(path: String, ops: FileOps) throws -> Data {
        let fd = try ops.openRead(path)
        defer { ops.close(fd) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: blockSize)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, blockSize) }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXFailure(errno: errno)
            }
            if count == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
        }
        return Data(hasher.finalize())
    }
}
