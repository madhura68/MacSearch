import Darwin
import Foundation
import Testing
@testable import MacSearch

/// AC3a: the publication routes A/B/C of NF4 and the retries after `EEXIST`, on real files.
@Suite struct FileTransferRoutesTests {
    static let routesAndModes: [(Route, TransferMode)] = [(.a, .move), (.b, .copy), (.b, .move), (.c, .copy), (.c, .move)]

    // MARK: Routes

    @Test(arguments: routesAndModes)
    func transfersTheFile(_ route: Route, _ mode: TransferMode) throws {
        let f = try TransferFixture(); defer { f.remove() }
        let outcome = try f.transfer(route, mode)
        let expected: ActionResult = mode == .copy ? .copied : .moved
        #expect(outcome == TransferOutcome(result: expected, destPath: f.desired, warning: nil))
        #expect(f.contents(f.desired) == TransferFixture.source)
        #expect(f.exists(f.sourcePath) == (mode == .copy))
        #expect(f.tempFiles().isEmpty)
        try f.expectRecord(expected, dest: f.desired)
        switch route {
        case .a:
            #expect(f.ops.count(.createExclusive) == 0)
            #expect(f.ops.count(.renameExclusive) == 1)
        case .b:
            #expect(f.ops.count(.createExclusive) == 1)
            #expect(f.ops.count(.renameExclusive) == 1)
        case .c:
            #expect(f.ops.count(.createExclusive) == 1)
            #expect(f.ops.count(.renameExclusive) == 0)
        }
    }

    @Test func moveToAnotherVolumePublishesThroughATemporaryFile() throws {
        let f = try TransferFixture(); defer { f.remove() }
        let renamedFrom = Locked<[String]>([])
        f.ops.before(.renameExclusive) { call in
            if case .paths(let from, _) = call { renamedFrom.set(renamedFrom.get() + [from]) }
        }
        let outcome = try f.transfer(.b, .move)
        #expect(outcome.result == .moved)
        #expect(renamedFrom.get().count == 1)
        let from = try #require(renamedFrom.get().first)
        #expect(from.hasPrefix(f.dest(".macsearch-")) && from.hasSuffix(".tmp"))
        #expect(f.ops.count(.fullFsync) == 1)
        #expect(!f.exists(f.sourcePath))
    }

    @Test(arguments: [TransferMode.copy, .move])
    func withoutRenameExclusiveTheFinalFileIsCreatedDirectly(_ mode: TransferMode) throws {
        let f = try TransferFixture(); defer { f.remove() }
        let created = Locked<[String]>([])
        f.ops.before(.createExclusive) { call in
            if case .path(let path) = call { created.set(created.get() + [path]) }
        }
        _ = try f.transfer(.c, mode)
        #expect(created.get() == [f.desired])
        #expect(f.ops.count(.renameExclusive) == 0)
        #expect(f.tempFiles().isEmpty)
        #expect(f.contents(f.desired) == TransferFixture.source)
    }

    @Test(arguments: [(Route.b, TransferMode.copy), (Route.b, .move), (Route.c, .copy), (Route.c, .move)])
    func keepsDatesAndExtendedAttributes(_ route: Route, _ mode: TransferMode) throws {
        let f = try TransferFixture(); defer { f.remove() }
        let value = Array("waarde".utf8)
        #expect(setxattr(f.sourcePath, "com.macsearch.test", value, value.count, 0, 0) == 0)
        let created = Date(timeIntervalSince1970: 1_000_000_000)
        let modified = Date(timeIntervalSince1970: 1_100_000_000)
        try FileManager.default.setAttributes(
            [.creationDate: created, .modificationDate: modified], ofItemAtPath: f.sourcePath)
        let outcome = try f.transfer(route, mode)
        #expect(outcome.warning == nil)
        var buffer = [UInt8](repeating: 0, count: 64)
        let length = getxattr(f.desired, "com.macsearch.test", &buffer, buffer.count, 0, 0)
        #expect(length == value.count)
        #expect(Array(buffer.prefix(max(length, 0))) == value)
        let dates = try PosixFileOps().dates(path: f.desired)
        #expect(abs(dates.modified.timeIntervalSince(modified)) < 0.001)
        #expect(abs(dates.created.timeIntervalSince(created)) < 0.001)
    }

    @Test(arguments: [Route.b, .c])
    func theRecordExistsBeforeTheFirstByte(_ route: Route) throws {
        let f = try TransferFixture(); defer { f.remove() }
        let seen = Locked<([ActionRow], String?)?>(nil)
        let ops = f.ops, store = f.store, runId = f.runId
        ops.before(.copyData) { call in
            guard case .fds(_, let to) = call else { return }
            seen.set(((try? store.actions(runId: runId)) ?? [], ops.createdPath(fd: to)))
        }
        _ = try f.transfer(route, .copy)
        let (rows, path) = try #require(seen.get())
        let written = try #require(path)
        #expect(rows.count == 1)
        #expect(rows.first?.result == .pending)
        #expect(rows.first?.tempPath == written)
        #expect(rows.first?.destPath == f.desired)
        if route == .c {
            #expect(written == f.desired)
        } else {
            #expect(written.hasPrefix(f.dest(".macsearch-")))
        }
    }

    // MARK: Collisions

    @Test func collisionOnTheTemporaryNameTakesTheNextUUID() throws {
        let f = try TransferFixture(); defer { f.remove() }
        let first = UUID(), second = UUID()
        let foreign = f.dest(".macsearch-\(first.uuidString).tmp")
        TransferFixture.plant(foreign, Data("vreemd".utf8))
        let outcome = try f.transfer(.b, .copy, uuids: SequenceUUIDs([first, second]))
        #expect(outcome == TransferOutcome(result: .copied, destPath: f.desired, warning: nil))
        #expect(f.contents(foreign) == Data("vreemd".utf8))
        #expect(f.tempFiles() == [(foreign as NSString).lastPathComponent])
        #expect(
            f.inserts() == [
                .insertAction(result: .pending, destPath: f.desired, tempPath: f.dest(".macsearch-\(second.uuidString).tmp"))
            ])
        #expect(f.ops.count(.createExclusive) == 2)
        #expect(f.contents(f.desired) == TransferFixture.source)
        try f.expectRecord(.copied, dest: f.desired)
    }

    @Test(arguments: [Route.b, .c])
    func collisionOnTheFinalNameWithOtherContentIsRenamed(_ route: Route) throws {
        let f = try TransferFixture(); defer { f.remove() }
        f.plantOnPublication(route, onCalls: [1]) { _ in Data("vreemd".utf8) }
        let outcome = try f.transfer(route, .copy)
        let second = f.dest("naam (2).jpg")
        #expect(outcome == TransferOutcome(result: .renamed, destPath: second, warning: nil))
        #expect(f.contents(f.desired) == Data("vreemd".utf8))
        #expect(f.contents(second) == TransferFixture.source)
        #expect(f.contents(f.sourcePath) == TransferFixture.source)
        #expect(f.tempFiles().isEmpty)
        try f.expectRecord(.renamed, dest: second)
        if route == .c { #expect(f.ops.count(.renameExclusive) == 0) }
    }

    @Test(arguments: [Route.b, .c], [TransferMode.copy, .move])
    func collisionOnTheFinalNameWithIdenticalContentIsSkipped(_ route: Route, _ mode: TransferMode) throws {
        let f = try TransferFixture(); defer { f.remove() }
        f.plantOnPublication(route, onCalls: [1]) { _ in TransferFixture.source }
        let outcome = try f.transfer(route, mode)
        #expect(outcome == TransferOutcome(result: .skippedIdentical, destPath: f.desired, warning: nil))
        #expect(f.contents(f.desired) == TransferFixture.source)
        #expect(f.contents(f.sourcePath) == TransferFixture.source)
        #expect(!f.exists(f.dest("naam (2).jpg")))
        #expect(f.tempFiles().isEmpty)
        try f.expectRecord(.skippedIdentical, dest: f.desired)
        if route == .c {
            #expect(f.inserts() == [.insertAction(result: .skippedIdentical, destPath: f.desired, tempPath: nil)])
            #expect(f.store.count(.updateAction) == 0)
        }
    }

    @Test(arguments: [Route.b, .c])
    func threeCollisionsFail(_ route: Route) throws {
        let f = try TransferFixture(); defer { f.remove() }
        f.plantOnPublication(route, onCalls: [1, 2, 3]) { n in Data("vreemd \(n)".utf8) }
        let outcome = try f.transfer(route, .copy)
        #expect(outcome.result == .failed)
        #expect(f.contents(f.desired) == Data("vreemd 1".utf8))
        #expect(f.contents(f.dest("naam (2).jpg")) == Data("vreemd 2".utf8))
        #expect(f.contents(f.dest("naam (3).jpg")) == Data("vreemd 3".utf8))
        #expect(!f.exists(f.dest("naam (4).jpg")))
        #expect(f.tempFiles().isEmpty)
        #expect(f.contents(f.sourcePath) == TransferFixture.source)
        try f.expectRecord(.failed, dest: nil)
        #expect(try f.rows().first?.error != nil)
        if route == .c {
            #expect(f.inserts() == [.insertAction(result: .failed, destPath: f.dest("naam (3).jpg"), tempPath: nil)])
            #expect(f.store.count(.updateAction) == 0)
        }
    }

    @Test func collisionWhenMovingOnTheSameVolumeTakesTheNextName() throws {
        let f = try TransferFixture(); defer { f.remove() }
        f.plantOnPublication(.a, onCalls: [1]) { _ in Data("vreemd".utf8) }
        let outcome = try f.transfer(.a, .move)
        let second = f.dest("naam (2).jpg")
        #expect(outcome == TransferOutcome(result: .moved, destPath: second, warning: nil))
        #expect(f.contents(f.desired) == Data("vreemd".utf8))
        #expect(f.contents(second) == TransferFixture.source)
        #expect(!f.exists(f.sourcePath))
        try f.expectRecord(.moved, dest: second)
    }

    @Test func exdevInRouteAContinuesInRouteBWithTheSameRecord() throws {
        let f = try TransferFixture(); defer { f.remove() }
        f.ops.fail(.renameExclusive, errno: EXDEV, onCall: 1)
        let outcome = try f.transfer(.a, .move)
        #expect(outcome == TransferOutcome(result: .moved, destPath: f.desired, warning: nil))
        #expect(f.contents(f.desired) == TransferFixture.source)
        #expect(!f.exists(f.sourcePath))
        #expect(f.tempFiles().isEmpty)
        #expect(f.ops.count(.createExclusive) == 1)
        #expect(f.store.count(.insertAction) == 1)
        try f.expectRecord(.moved, dest: f.desired)
    }

    @Test(arguments: [Route.b, .c])
    func sameSizeOtherContentIsRenamed(_ route: Route) throws {
        let f = try TransferFixture(); defer { f.remove() }
        TransferFixture.plant(f.desired, Data("XYZ".utf8))
        let outcome = try f.transfer(route, .copy)
        let second = f.dest("naam (2).jpg")
        #expect(outcome == TransferOutcome(result: .renamed, destPath: second, warning: nil))
        #expect(f.contents(f.desired) == Data("XYZ".utf8))
        #expect(f.contents(second) == TransferFixture.source)
        try f.expectRecord(.renamed, dest: second)
    }

    @Test(arguments: routesAndModes)
    func identicalFromTheStartIsSkippedWithOneInsert(_ route: Route, _ mode: TransferMode) throws {
        let f = try TransferFixture(); defer { f.remove() }
        TransferFixture.plant(f.desired, TransferFixture.source)
        let outcome = try f.transfer(route, mode)
        #expect(outcome == TransferOutcome(result: .skippedIdentical, destPath: f.desired, warning: nil))
        #expect(f.contents(f.sourcePath) == TransferFixture.source)
        #expect(f.ops.count(.createExclusive) == 0)
        #expect(f.ops.count(.renameExclusive) == 0)
        #expect(f.store.calls == [.insertAction(result: .skippedIdentical, destPath: f.desired, tempPath: nil)])
        try f.expectRecord(.skippedIdentical, dest: f.desired)
    }

    // MARK: Attempt budget

    @Test func temporaryAndPublicationCollisionsShareOneBudget() throws {
        let f = try TransferFixture(); defer { f.remove() }
        let first = UUID()
        let foreignTemp = f.dest(".macsearch-\(first.uuidString).tmp")
        TransferFixture.plant(foreignTemp, Data("vreemd".utf8))
        f.plantOnPublication(.b, onCalls: [1, 2]) { n in Data("vreemd \(n)".utf8) }
        let outcome = try f.transfer(.b, .copy, uuids: SequenceUUIDs([first]))
        #expect(outcome.result == .failed)
        #expect(f.ops.count(.renameExclusive) == 2)
        #expect(f.contents(foreignTemp) == Data("vreemd".utf8))
        #expect(f.tempFiles() == [(foreignTemp as NSString).lastPathComponent])
        #expect(f.contents(f.desired) == Data("vreemd 1".utf8))
        #expect(f.contents(f.dest("naam (2).jpg")) == Data("vreemd 2".utf8))
        #expect(!f.exists(f.dest("naam (3).jpg")))
        #expect(f.contents(f.sourcePath) == TransferFixture.source)
        try f.expectRecord(.failed, dest: nil)
    }

    @Test func theBudgetCarriesOverFromRouteAIntoRouteB() throws {
        let f = try TransferFixture(); defer { f.remove() }
        f.plantOnPublication(.a, onCalls: [1, 3, 4]) { n in Data("vreemd \(n)".utf8) }
        f.ops.fail(.renameExclusive, errno: EXDEV, onCall: 2)
        let outcome = try f.transfer(.a, .move)
        #expect(outcome.result == .failed)
        #expect(f.ops.count(.renameExclusive) == 4)
        #expect(f.contents(f.desired) == Data("vreemd 1".utf8))
        #expect(f.contents(f.dest("naam (2).jpg")) == Data("vreemd 3".utf8))
        #expect(f.contents(f.dest("naam (3).jpg")) == Data("vreemd 4".utf8))
        #expect(f.tempFiles().isEmpty)
        #expect(f.contents(f.sourcePath) == TransferFixture.source)
        #expect(f.store.count(.insertAction) == 1)
        try f.expectRecord(.failed, dest: nil)
    }

    @Test func publicationRetriesReuseTheCopiedTemporaryFile() throws {
        let f = try TransferFixture(); defer { f.remove() }
        f.plantOnPublication(.b, onCalls: [1, 2]) { n in Data("vreemd \(n)".utf8) }
        let outcome = try f.transfer(.b, .copy)
        let third = f.dest("naam (3).jpg")
        #expect(outcome == TransferOutcome(result: .renamed, destPath: third, warning: nil))
        #expect(f.ops.count(.createExclusive) == 1)
        #expect(f.ops.count(.copyData) == 1)
        #expect(f.contents(third) == TransferFixture.source)
        #expect(f.tempFiles().isEmpty)
        try f.expectRecord(.renamed, dest: third)
    }
}
