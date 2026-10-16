import Darwin
import Foundation
import Testing
@testable import MacSearch

@Suite struct PosixFileOpsTests {
    let fm = FileManager.default
    let ops = PosixFileOps()

    func makeTempDir() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("PosixFileOpsTests-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func createExclusiveRefusesExistingPath() throws {
        let dir = try makeTempDir(); defer { try? fm.removeItem(at: dir) }
        let path = dir.appendingPathComponent("a.jpg").path
        #expect(fm.createFile(atPath: path, contents: Data("vreemd".utf8)))
        #expect(throws: POSIXFailure(errno: EEXIST)) { try ops.createExclusive(path) }
    }

    @Test func renameExclusiveRefusesExistingTargetAndLeavesItUnchanged() throws {
        let dir = try makeTempDir(); defer { try? fm.removeItem(at: dir) }
        let from = dir.appendingPathComponent("eigen.tmp").path
        let to = dir.appendingPathComponent("doel.jpg").path
        #expect(fm.createFile(atPath: from, contents: Data("nieuw".utf8)))
        #expect(fm.createFile(atPath: to, contents: Data("vreemd".utf8)))
        #expect(throws: POSIXFailure(errno: EEXIST)) { try ops.renameExclusive(from, to) }
        #expect(fm.contents(atPath: to) == Data("vreemd".utf8))
        #expect(fm.contents(atPath: from) == Data("nieuw".utf8))
    }

    @Test func temporaryDirectorySupportsRenameExclusive() {
        #expect(ops.supportsRenameExclusive(volumeOf: NSTemporaryDirectory()))
    }

    @Test(arguments: [(true, true, true), (true, false, false), (false, true, false), (false, false, false)])
    func renameExclusiveNeedsCapabilityAndValidBit(_ capability: Bool, _ valid: Bool, _ expected: Bool) {
        let bit = UInt32(VOL_CAP_INT_RENAME_EXCL)
        let caps = VolumeCapabilities(capabilities: capability ? bit : 0, valid: valid ? bit : 0)
        #expect(renameExclusiveAllowed(caps) == expected)
    }

    @Test func failingCapabilityQueryMeansNoRenameExclusive() {
        let ops = PosixFileOps(capabilityQuery: { _ throws(POSIXFailure) in throw POSIXFailure(errno: EIO) })
        #expect(!ops.supportsRenameExclusive(volumeOf: NSTemporaryDirectory()))
    }

    @Test func createDirectoriesUnderARegularFileFails() throws {
        let dir = try makeTempDir(); defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("bestand")
        #expect(fm.createFile(atPath: file.path, contents: nil))
        #expect(throws: POSIXFailure(errno: ENOTDIR)) {
            try ops.createDirectories(file.appendingPathComponent("a/b").path)
        }
    }

    @Test func createDirectoriesCreatesIntermediateFolders() throws {
        let dir = try makeTempDir(); defer { try? fm.removeItem(at: dir) }
        let deep = dir.appendingPathComponent("a/b/c").path
        try ops.createDirectories(deep)
        try ops.createDirectories(deep)
        var isDirectory: ObjCBool = false
        #expect(fm.fileExists(atPath: deep, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    @Test func datesRoundTripThroughTheDescriptor() throws {
        let dir = try makeTempDir(); defer { try? fm.removeItem(at: dir) }
        let path = dir.appendingPathComponent("a.jpg").path
        let fd = try ops.createExclusive(path)
        defer { ops.close(fd) }
        let created = Date(timeIntervalSince1970: 1_000_000_000.123)
        let modified = Date(timeIntervalSince1970: 1_100_000_000.456)
        try ops.setDates(fd, modified: modified, created: created)
        let read = try ops.dates(path: path)
        #expect(abs(read.modified.timeIntervalSince(modified)) < 0.001)
        #expect(abs(read.created.timeIntervalSince(created)) < 0.001)
    }

    @Test func faultyFileOpsInjectsOnTheNthCallAndCounts() throws {
        let dir = try makeTempDir(); defer { try? fm.removeItem(at: dir) }
        let faulty = FaultyFileOps()
        faulty.fail(.createExclusive, errno: ENOSPC, onCall: 2)
        let first = try faulty.createExclusive(dir.appendingPathComponent("1").path)
        #expect(faulty.createdPath(fd: first) == dir.appendingPathComponent("1").path)
        faulty.close(first)
        #expect(faulty.createdPath(fd: first) == nil)
        #expect(throws: POSIXFailure(errno: ENOSPC)) { try faulty.createExclusive(dir.appendingPathComponent("2").path) }
        #expect(faulty.count(.createExclusive) == 2)
    }
}
