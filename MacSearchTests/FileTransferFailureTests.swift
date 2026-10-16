import Darwin
import Foundation
import Testing
@testable import MacSearch

/// AC3a: the failure paths of F15 and F17 and NF4 Opruimen. A foreign file is never touched; when in
/// doubt `temp_path` stays set so the next start reports it (F19d).
@Suite struct FileTransferFailureTests {
    // MARK: Copy and publication

    @Test func aCopyThatBreaksHalfwayIsCleanedUp() throws {
        let content = Data((0..<10_000).map { UInt8($0 % 251) })
        let f = try TransferFixture(content: content)
        defer { f.remove() }
        let head = content.prefix(4096)
        let seen = Locked<(size: Int64, read: Data, sameInode: Bool)?>(nil)
        let ops = f.ops
        ops.before(.copyData) { (call: FaultyFileOps.Call) throws(POSIXFailure) in
            guard case .fds(_, let to) = call, let path = ops.createdPath(fd: to) else { return }
            _ = head.withUnsafeBytes { Darwin.write(to, $0.baseAddress, $0.count) }
            // The descriptor is write-only, so read the written part back through the recorded path.
            let reader = Darwin.open(path, O_RDONLY)
            defer { Darwin.close(reader) }
            var written = stat(), opened = stat()
            _ = fstat(to, &written)
            _ = fstat(reader, &opened)
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = pread(reader, &buffer, buffer.count, 0)
            seen.set(
                (Int64(written.st_size), Data(buffer.prefix(max(count, 0))),
                 written.st_dev == opened.st_dev && written.st_ino == opened.st_ino))
            throw POSIXFailure(errno: EIO)
        }
        let outcome = try f.transfer(.b, .copy)
        let partial = try #require(seen.get())
        #expect(partial.sameInode)
        #expect(partial.size == 4096)
        #expect(partial.read == head)
        #expect(outcome.result == .failed)
        #expect(f.tempFiles().isEmpty)
        #expect(!f.exists(f.desired))
        #expect(f.contents(f.sourcePath) == content)
        try f.expectRecord(.failed, dest: nil)
    }

    @Test func publicationFailingWithEIOFails() throws {
        let f = try TransferFixture(); defer { f.remove() }
        f.ops.fail(.renameExclusive, errno: EIO)
        let outcome = try f.transfer(.b, .copy)
        #expect(outcome.result == .failed)
        #expect(!f.exists(f.desired))
        #expect(f.tempFiles().isEmpty)
        #expect(f.contents(f.sourcePath) == TransferFixture.source)
        try f.expectRecord(.failed, dest: nil)
    }

    @Test(arguments: [Route.b, .c])
    func copyDataFailingFails(_ route: Route) throws {
        let f = try TransferFixture(); defer { f.remove() }
        f.ops.fail(.copyData, errno: EIO)
        let outcome = try f.transfer(route, .copy)
        #expect(outcome.result == .failed)
        #expect(!f.exists(f.desired))
        #expect(f.tempFiles().isEmpty)
        try f.expectRecord(.failed, dest: nil)
    }

    /// Review Focus 4.
    @Test(arguments: [Route.b, .c])
    func diskFullDuringTheCopyFails(_ route: Route) throws {
        let f = try TransferFixture(); defer { f.remove() }
        f.ops.fail(.copyData, errno: ENOSPC)
        let outcome = try f.transfer(route, .move)
        #expect(outcome.result == .failed)
        #expect(!f.exists(f.desired))
        #expect(f.tempFiles().isEmpty)
        #expect(f.contents(f.sourcePath) == TransferFixture.source)
        try f.expectRecord(.failed, dest: nil)
    }

    /// Review Focus 3.
    @Test(arguments: FileTransferRoutesTests.routesAndModes)
    func aSourceRemovedAfterTheScanFails(_ route: Route, _ mode: TransferMode) throws {
        let f = try TransferFixture(); defer { f.remove() }
        try FileManager.default.removeItem(atPath: f.sourcePath)
        let outcome = try f.transfer(route, mode)
        #expect(outcome.result == .failed)
        #expect(!f.exists(f.desired))
        #expect(f.tempFiles().isEmpty)
        try f.expectRecord(.failed, dest: nil)
    }

    // MARK: Move

    @Test(arguments: [Route.b, .c])
    func failingToRemoveTheSourceGivesCopiedWithAWarning(_ route: Route) throws {
        let f = try TransferFixture(); defer { f.remove() }
        f.ops.fail(.unlink, errno: EACCES, onCall: 1)
        let outcome = try f.transfer(route, .move)
        #expect(outcome.result == .copied)
        #expect(outcome.destPath == f.desired)
        #expect(outcome.warning != nil)
        #expect(f.contents(f.desired) == TransferFixture.source)
        #expect(f.contents(f.sourcePath) == TransferFixture.source)
        #expect(f.tempFiles().isEmpty)
        let row = try f.expectRecord(.copied, dest: f.desired)
        #expect(row.error == outcome.warning)
    }

    @Test(arguments: [Route.b, .c])
    func aCopyOfTheWrongSizeFails(_ route: Route) throws {
        let f = try TransferFixture(); defer { f.remove() }
        // The copy reports success but leaves a shorter file.
        f.ops.before(.setDates) { call in
            if case .fd(let fd) = call { _ = ftruncate(fd, 1) }
        }
        let outcome = try f.transfer(route, .move)
        #expect(outcome.result == .failed)
        #expect(!f.exists(f.desired))
        #expect(f.tempFiles().isEmpty)
        #expect(f.contents(f.sourcePath) == TransferFixture.source)
        try f.expectRecord(.failed, dest: nil)
    }

    @Test(arguments: [Route.b, .c])
    func aFailedFlushPublishesButKeepsTheSource(_ route: Route) throws {
        let f = try TransferFixture(); defer { f.remove() }
        f.ops.fail(.fullFsync, errno: EIO)
        let outcome = try f.transfer(route, .move)
        #expect(outcome.result == .copied)
        #expect(outcome.warning != nil)
        #expect(f.contents(f.desired) == TransferFixture.source)
        #expect(f.tempFiles().isEmpty)
        #expect(f.contents(f.sourcePath) == TransferFixture.source)
        let row = try f.expectRecord(.copied, dest: f.desired)
        #expect(row.error == outcome.warning)
    }

    // MARK: Metadata

    @Test(arguments: [Route.b, .c], [FaultyFileOps.Op.copyXattrs, .setDates])
    func failingMetadataIsAWarning(_ route: Route, _ op: FaultyFileOps.Op) throws {
        let f = try TransferFixture(); defer { f.remove() }
        f.ops.fail(op, errno: ENOTSUP)
        let outcome = try f.transfer(route, .copy)
        #expect(outcome.result == .copied)
        #expect(outcome.warning != nil)
        #expect(f.contents(f.desired) == TransferFixture.source)
        #expect(f.tempFiles().isEmpty)
        let row = try f.expectRecord(.copied, dest: f.desired)
        #expect(row.error == outcome.warning)
    }

    // MARK: Opruimen

    @Test(arguments: [Route.b, .c])
    func aReplacedOwnFileIsLeftAlone(_ route: Route) throws {
        let f = try TransferFixture(); defer { f.remove() }
        let ops = f.ops
        let ownPath = Locked<String?>(nil)
        ops.before(.copyData) { (call: FaultyFileOps.Call) throws(POSIXFailure) in
            guard case .fds(_, let to) = call, let path = ops.createdPath(fd: to) else { return }
            ownPath.set(path)
            _ = Darwin.unlink(path)
            TransferFixture.plant(path, Data("vreemd".utf8))
            throw POSIXFailure(errno: EIO)
        }
        let outcome = try f.transfer(route, .copy)
        let path = try #require(ownPath.get())
        #expect(outcome.result == .failed)
        #expect(f.contents(path) == Data("vreemd".utf8))
        try f.expectRecord(.failed, dest: nil, tempPath: path)
    }

    @Test(arguments: [Route.b, .c])
    func aFailingUnlinkLeavesTheTempPathSet(_ route: Route) throws {
        let f = try TransferFixture(); defer { f.remove() }
        let ownPath = Locked<String?>(nil)
        let ops = f.ops
        ops.before(.copyData) { call in
            if case .fds(_, let to) = call { ownPath.set(ops.createdPath(fd: to)) }
        }
        f.ops.fail(.copyData, errno: EIO)
        f.ops.fail(.unlink, errno: EPERM)
        let outcome = try f.transfer(route, .copy)
        let path = try #require(ownPath.get())
        #expect(outcome.result == .failed)
        #expect(f.exists(path))
        try f.expectRecord(.failed, dest: nil, tempPath: path)
    }

    @Test(arguments: [Route.b, .c])
    func cleanupThatCannotFindThePathRemovesNothing(_ route: Route) throws {
        let f = try TransferFixture(); defer { f.remove() }
        let ownPath = Locked<String?>(nil)
        let ops = f.ops
        ops.before(.copyData) { call in
            if case .fds(_, let to) = call { ownPath.set(ops.createdPath(fd: to)) }
        }
        f.ops.fail(.copyData, errno: EIO)
        f.ops.fail(.lstatInode, errno: ENOENT)
        let outcome = try f.transfer(route, .copy)
        let path = try #require(ownPath.get())
        #expect(outcome.result == .failed)
        #expect(f.ops.count(.unlink) == 0)
        try f.expectRecord(.failed, dest: nil, tempPath: path)
    }

    // MARK: History writes

    @Test(arguments: [Route.b, .c])
    func aFailingPendingInsertStopsWithoutATransfer(_ route: Route) throws {
        let f = try TransferFixture(); defer { f.remove() }
        f.store.fail(.insertAction)
        let error = #expect(throws: StoreWriteFailed.self) { try f.transfer(route, .copy) }
        #expect(error?.fileProcessed == false)
        #expect(f.ops.count(.createExclusive) == 1)
        #expect(f.ops.count(.copyData) == 0)
        #expect(!f.exists(f.desired))
        #expect(f.tempFiles().isEmpty)
        #expect(try f.rows().isEmpty)
    }

    @Test func routeCKeepsTheSourceWhenTheCompletionWriteFails() throws {
        let f = try TransferFixture(); defer { f.remove() }
        f.store.fail(.updateAction, onCall: 1)
        let error = #expect(throws: StoreWriteFailed.self) { try f.transfer(.c, .move) }
        #expect(error?.fileProcessed == true)
        #expect(f.contents(f.sourcePath) == TransferFixture.source)
        #expect(f.contents(f.desired) == TransferFixture.source)
        try f.expectRecord(.pending, dest: f.desired, tempPath: f.desired)
    }

    @Test func aFailureBeforeAnOwnFileIsOneInsert() throws {
        let f = try TransferFixture(); defer { f.remove() }
        f.ops.fail(.createExclusive, errno: ENOSPC)
        let outcome = try f.transfer(.c, .copy)
        #expect(outcome.result == .failed)
        #expect(f.inserts() == [.insertAction(result: .failed, destPath: f.desired, tempPath: nil)])
        #expect(f.store.count(.updateAction) == 0)
        #expect(!f.exists(f.desired))
    }

    @Test func aFailingHashInConflictResolutionIsOneInsert() throws {
        let f = try TransferFixture(); defer { f.remove() }
        TransferFixture.plant(f.desired, Data("XYZ".utf8))
        // F16 opens the candidate for its size first, then the source for its hash.
        f.ops.fail(.openRead, errno: EACCES, onCall: 2)
        let outcome = try f.transfer(.b, .copy)
        #expect(outcome.result == .failed)
        #expect(f.inserts() == [.insertAction(result: .failed, destPath: f.desired, tempPath: nil)])
        #expect(f.store.count(.updateAction) == 0)
        #expect(f.ops.count(.createExclusive) == 0)
        #expect(f.contents(f.desired) == Data("XYZ".utf8))
    }
}
