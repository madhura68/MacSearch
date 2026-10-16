import Darwin
import Foundation
import Testing
@testable import MacSearch

/// AC3a: the publication routes A/B/C of NF4 and the retries after `EEXIST`, on real files.
@Suite struct FileTransferRoutesTests {
    enum Route: Sendable, CustomStringConvertible {
        case a, b, c
        var description: String { "route \(self == .a ? "A" : self == .b ? "B" : "C")" }
    }

    static let routesAndModes: [(Route, TransferMode)] = [(.a, .move), (.b, .copy), (.b, .move), (.c, .copy), (.c, .move)]
    static let source = Data("ABC".utf8)

    /// `bron/naam.jpg` containing `ABC`, an empty `doel/`, and a run in an in-memory store.
    struct Fixture {
        let root: URL
        let sourceURL: URL
        let destFolder: String
        let store: RecordingStore
        let ops: FaultyFileOps
        let runId: Int64

        var sourcePath: String { sourceURL.path }
        var desired: String { dest("naam.jpg") }
        func dest(_ name: String) -> String { destFolder + "/" + name }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    func makeFixture() throws -> Fixture {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: realPath(NSTemporaryDirectory()))
            .appendingPathComponent("FileTransferRoutesTests-\(UUID().uuidString)")
        let bron = root.appendingPathComponent("bron")
        let doel = root.appendingPathComponent("doel")
        try fm.createDirectory(at: bron, withIntermediateDirectories: true)
        try fm.createDirectory(at: doel, withIntermediateDirectories: true)
        let sourceURL = bron.appendingPathComponent("naam.jpg")
        try Self.source.write(to: sourceURL)
        let store = try RecordingStore()
        let runId = try store.inner.insertRun(
            NewRun(
                createdAt: iso8601(Date()), sourcePath: bron.path, keywordsRaw: "naam", destRoot: doel.path,
                destFolder: doel.path, mode: .copy, foundCount: 1, selectedCount: 1, scanComplete: true, skippedCount: 0))
        return Fixture(
            root: root, sourceURL: sourceURL, destFolder: doel.path, store: store, ops: FaultyFileOps(), runId: runId)
    }

    /// Route A: move on the same volume with `renameExclusive`. Route B: `renameExclusive`, and for a move
    /// the destination reports another volume. Route C: no `renameExclusive`.
    func transfer(
        _ f: Fixture, _ route: Route, _ mode: TransferMode, uuids: UUIDSource = SystemUUIDSource()
    ) throws -> TransferOutcome {
        if route == .b && mode == .move { f.ops.overrideVolumeID(prefix: f.destFolder, id: "ander-volume") }
        let transfer = FileTransfer(ops: f.ops, store: f.store, uuids: uuids, renameExclusive: route != .c)
        return try transfer.transfer(
            FoundFile(url: f.sourceURL, size: Int64(Self.source.count)), runId: f.runId, destFolder: f.destFolder,
            mode: mode)
    }

    // MARK: Helpers

    /// A file that is not the app's; never overwrites.
    static func plant(_ path: String, _ data: Data) {
        try? data.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
    }

    /// On the given publication attempts (route A/B: the rename, route C: the exclusive create of the
    /// final name), a foreign file appears under the chosen name just before the call.
    func plantOnPublication(
        _ f: Fixture, _ route: Route, onCalls: Set<Int>, _ content: @escaping @Sendable (Int) -> Data
    ) {
        let ops = f.ops
        let op: FaultyFileOps.Op = route == .c ? .createExclusive : .renameExclusive
        ops.before(op) { call in
            let n = ops.count(op)
            guard onCalls.contains(n) else { return }
            switch call {
            case .paths(_, let to): Self.plant(to, content(n))
            case .path(let path): Self.plant(path, content(n))
            default: break
            }
        }
    }

    func contents(_ path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func tempFiles(_ f: Fixture) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: f.destFolder)) ?? []).filter { $0.hasPrefix(".macsearch-") }
    }

    func inserts(_ f: Fixture) -> [RecordingStore.Call] {
        f.store.calls.filter { if case .insertAction = $0 { true } else { false } }
    }

    /// Exactly one record for the source, with this result, destination and `temp_path`.
    func expectRecord(
        _ f: Fixture, _ result: ActionResult, dest: String?, tempPath: String? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let rows = try f.store.actions(runId: f.runId)
        #expect(rows.count == 1, "records: \(rows)", sourceLocation: sourceLocation)
        let row = try #require(rows.first, sourceLocation: sourceLocation)
        #expect(row.sourcePath == f.sourcePath, sourceLocation: sourceLocation)
        #expect(row.result == result, sourceLocation: sourceLocation)
        if let dest { #expect(row.destPath == dest, sourceLocation: sourceLocation) }
        #expect(row.tempPath == tempPath, sourceLocation: sourceLocation)
    }

    // MARK: Routes

    @Test(arguments: routesAndModes)
    func transfersTheFile(_ route: Route, _ mode: TransferMode) throws {
        let f = try makeFixture(); defer { f.remove() }
        let outcome = try transfer(f, route, mode)
        let expected: ActionResult = mode == .copy ? .copied : .moved
        #expect(outcome == TransferOutcome(result: expected, destPath: f.desired, warning: nil))
        #expect(contents(f.desired) == Self.source)
        #expect(exists(f.sourcePath) == (mode == .copy))
        #expect(tempFiles(f).isEmpty)
        try expectRecord(f, expected, dest: f.desired)
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
        let f = try makeFixture(); defer { f.remove() }
        let renamedFrom = Locked<[String]>([])
        f.ops.before(.renameExclusive) { call in
            if case .paths(let from, _) = call { renamedFrom.set(renamedFrom.get() + [from]) }
        }
        let outcome = try transfer(f, .b, .move)
        #expect(outcome.result == .moved)
        #expect(renamedFrom.get().count == 1)
        let from = try #require(renamedFrom.get().first)
        #expect(from.hasPrefix(f.dest(".macsearch-")) && from.hasSuffix(".tmp"))
        #expect(f.ops.count(.fullFsync) == 1)
        #expect(!exists(f.sourcePath))
    }

    @Test(arguments: [TransferMode.copy, .move])
    func withoutRenameExclusiveTheFinalFileIsCreatedDirectly(_ mode: TransferMode) throws {
        let f = try makeFixture(); defer { f.remove() }
        let created = Locked<[String]>([])
        f.ops.before(.createExclusive) { call in
            if case .path(let path) = call { created.set(created.get() + [path]) }
        }
        _ = try transfer(f, .c, mode)
        #expect(created.get() == [f.desired])
        #expect(f.ops.count(.renameExclusive) == 0)
        #expect(tempFiles(f).isEmpty)
        #expect(contents(f.desired) == Self.source)
    }

    @Test(arguments: [(Route.b, TransferMode.copy), (Route.b, .move), (Route.c, .copy), (Route.c, .move)])
    func keepsDatesAndExtendedAttributes(_ route: Route, _ mode: TransferMode) throws {
        let f = try makeFixture(); defer { f.remove() }
        let value = Array("waarde".utf8)
        #expect(setxattr(f.sourcePath, "com.macsearch.test", value, value.count, 0, 0) == 0)
        let created = Date(timeIntervalSince1970: 1_000_000_000)
        let modified = Date(timeIntervalSince1970: 1_100_000_000)
        try FileManager.default.setAttributes(
            [.creationDate: created, .modificationDate: modified], ofItemAtPath: f.sourcePath)
        let outcome = try transfer(f, route, mode)
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
        let f = try makeFixture(); defer { f.remove() }
        let seen = Locked<([ActionRow], String?)?>(nil)
        let ops = f.ops, store = f.store, runId = f.runId
        ops.before(.copyData) { call in
            guard case .fds(_, let to) = call else { return }
            seen.set(((try? store.actions(runId: runId)) ?? [], ops.createdPath(fd: to)))
        }
        _ = try transfer(f, route, .copy)
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
        let f = try makeFixture(); defer { f.remove() }
        let first = UUID(), second = UUID()
        let foreign = f.dest(".macsearch-\(first.uuidString).tmp")
        Self.plant(foreign, Data("vreemd".utf8))
        let outcome = try transfer(f, .b, .copy, uuids: SequenceUUIDs([first, second]))
        #expect(outcome == TransferOutcome(result: .copied, destPath: f.desired, warning: nil))
        #expect(contents(foreign) == Data("vreemd".utf8))
        #expect(tempFiles(f) == [(foreign as NSString).lastPathComponent])
        #expect(
            inserts(f) == [
                .insertAction(result: .pending, destPath: f.desired, tempPath: f.dest(".macsearch-\(second.uuidString).tmp"))
            ])
        #expect(f.ops.count(.createExclusive) == 2)
        #expect(contents(f.desired) == Self.source)
        try expectRecord(f, .copied, dest: f.desired)
    }

    @Test(arguments: [Route.b, .c])
    func collisionOnTheFinalNameWithOtherContentIsRenamed(_ route: Route) throws {
        let f = try makeFixture(); defer { f.remove() }
        plantOnPublication(f, route, onCalls: [1]) { _ in Data("vreemd".utf8) }
        let outcome = try transfer(f, route, .copy)
        let second = f.dest("naam (2).jpg")
        #expect(outcome == TransferOutcome(result: .renamed, destPath: second, warning: nil))
        #expect(contents(f.desired) == Data("vreemd".utf8))
        #expect(contents(second) == Self.source)
        #expect(contents(f.sourcePath) == Self.source)
        #expect(tempFiles(f).isEmpty)
        try expectRecord(f, .renamed, dest: second)
        if route == .c { #expect(f.ops.count(.renameExclusive) == 0) }
    }

    @Test(arguments: [Route.b, .c], [TransferMode.copy, .move])
    func collisionOnTheFinalNameWithIdenticalContentIsSkipped(_ route: Route, _ mode: TransferMode) throws {
        let f = try makeFixture(); defer { f.remove() }
        plantOnPublication(f, route, onCalls: [1]) { _ in Self.source }
        let outcome = try transfer(f, route, mode)
        #expect(outcome == TransferOutcome(result: .skippedIdentical, destPath: f.desired, warning: nil))
        #expect(contents(f.desired) == Self.source)
        #expect(contents(f.sourcePath) == Self.source)
        #expect(!exists(f.dest("naam (2).jpg")))
        #expect(tempFiles(f).isEmpty)
        try expectRecord(f, .skippedIdentical, dest: f.desired)
        if route == .c {
            #expect(inserts(f) == [.insertAction(result: .skippedIdentical, destPath: f.desired, tempPath: nil)])
            #expect(f.store.count(.updateAction) == 0)
        }
    }

    @Test(arguments: [Route.b, .c])
    func threeCollisionsFail(_ route: Route) throws {
        let f = try makeFixture(); defer { f.remove() }
        plantOnPublication(f, route, onCalls: [1, 2, 3]) { n in Data("vreemd \(n)".utf8) }
        let outcome = try transfer(f, route, .copy)
        #expect(outcome.result == .failed)
        #expect(contents(f.desired) == Data("vreemd 1".utf8))
        #expect(contents(f.dest("naam (2).jpg")) == Data("vreemd 2".utf8))
        #expect(contents(f.dest("naam (3).jpg")) == Data("vreemd 3".utf8))
        #expect(!exists(f.dest("naam (4).jpg")))
        #expect(tempFiles(f).isEmpty)
        #expect(contents(f.sourcePath) == Self.source)
        try expectRecord(f, .failed, dest: nil)
        #expect(try f.store.actions(runId: f.runId).first?.error != nil)
        if route == .c {
            #expect(inserts(f) == [.insertAction(result: .failed, destPath: f.dest("naam (3).jpg"), tempPath: nil)])
            #expect(f.store.count(.updateAction) == 0)
        }
    }

    @Test func collisionWhenMovingOnTheSameVolumeTakesTheNextName() throws {
        let f = try makeFixture(); defer { f.remove() }
        plantOnPublication(f, .a, onCalls: [1]) { _ in Data("vreemd".utf8) }
        let outcome = try transfer(f, .a, .move)
        let second = f.dest("naam (2).jpg")
        #expect(outcome == TransferOutcome(result: .moved, destPath: second, warning: nil))
        #expect(contents(f.desired) == Data("vreemd".utf8))
        #expect(contents(second) == Self.source)
        #expect(!exists(f.sourcePath))
        try expectRecord(f, .moved, dest: second)
    }

    @Test func exdevInRouteAContinuesInRouteBWithTheSameRecord() throws {
        let f = try makeFixture(); defer { f.remove() }
        f.ops.fail(.renameExclusive, errno: EXDEV, onCall: 1)
        let outcome = try transfer(f, .a, .move)
        #expect(outcome == TransferOutcome(result: .moved, destPath: f.desired, warning: nil))
        #expect(contents(f.desired) == Self.source)
        #expect(!exists(f.sourcePath))
        #expect(tempFiles(f).isEmpty)
        #expect(f.ops.count(.createExclusive) == 1)
        #expect(f.store.count(.insertAction) == 1)
        try expectRecord(f, .moved, dest: f.desired)
    }

    @Test(arguments: [Route.b, .c])
    func sameSizeOtherContentIsRenamed(_ route: Route) throws {
        let f = try makeFixture(); defer { f.remove() }
        Self.plant(f.desired, Data("XYZ".utf8))
        let outcome = try transfer(f, route, .copy)
        let second = f.dest("naam (2).jpg")
        #expect(outcome == TransferOutcome(result: .renamed, destPath: second, warning: nil))
        #expect(contents(f.desired) == Data("XYZ".utf8))
        #expect(contents(second) == Self.source)
        try expectRecord(f, .renamed, dest: second)
    }

    @Test(arguments: routesAndModes)
    func identicalFromTheStartIsSkippedWithOneInsert(_ route: Route, _ mode: TransferMode) throws {
        let f = try makeFixture(); defer { f.remove() }
        Self.plant(f.desired, Self.source)
        let outcome = try transfer(f, route, mode)
        #expect(outcome == TransferOutcome(result: .skippedIdentical, destPath: f.desired, warning: nil))
        #expect(contents(f.sourcePath) == Self.source)
        #expect(f.ops.count(.createExclusive) == 0)
        #expect(f.ops.count(.renameExclusive) == 0)
        #expect(f.store.calls == [.insertAction(result: .skippedIdentical, destPath: f.desired, tempPath: nil)])
        try expectRecord(f, .skippedIdentical, dest: f.desired)
    }

    // MARK: Attempt budget

    @Test func temporaryAndPublicationCollisionsShareOneBudget() throws {
        let f = try makeFixture(); defer { f.remove() }
        let first = UUID()
        let foreignTemp = f.dest(".macsearch-\(first.uuidString).tmp")
        Self.plant(foreignTemp, Data("vreemd".utf8))
        plantOnPublication(f, .b, onCalls: [1, 2]) { n in Data("vreemd \(n)".utf8) }
        let outcome = try transfer(f, .b, .copy, uuids: SequenceUUIDs([first]))
        #expect(outcome.result == .failed)
        #expect(f.ops.count(.renameExclusive) == 2)
        #expect(contents(foreignTemp) == Data("vreemd".utf8))
        #expect(tempFiles(f) == [(foreignTemp as NSString).lastPathComponent])
        #expect(contents(f.desired) == Data("vreemd 1".utf8))
        #expect(contents(f.dest("naam (2).jpg")) == Data("vreemd 2".utf8))
        #expect(!exists(f.dest("naam (3).jpg")))
        #expect(contents(f.sourcePath) == Self.source)
        try expectRecord(f, .failed, dest: nil)
    }

    @Test func theBudgetCarriesOverFromRouteAIntoRouteB() throws {
        let f = try makeFixture(); defer { f.remove() }
        plantOnPublication(f, .a, onCalls: [1, 3, 4]) { n in Data("vreemd \(n)".utf8) }
        f.ops.fail(.renameExclusive, errno: EXDEV, onCall: 2)
        let outcome = try transfer(f, .a, .move)
        #expect(outcome.result == .failed)
        #expect(f.ops.count(.renameExclusive) == 4)
        #expect(contents(f.desired) == Data("vreemd 1".utf8))
        #expect(contents(f.dest("naam (2).jpg")) == Data("vreemd 3".utf8))
        #expect(contents(f.dest("naam (3).jpg")) == Data("vreemd 4".utf8))
        #expect(tempFiles(f).isEmpty)
        #expect(contents(f.sourcePath) == Self.source)
        #expect(f.store.count(.insertAction) == 1)
        try expectRecord(f, .failed, dest: nil)
    }

    @Test func publicationRetriesReuseTheCopiedTemporaryFile() throws {
        let f = try makeFixture(); defer { f.remove() }
        plantOnPublication(f, .b, onCalls: [1, 2]) { n in Data("vreemd \(n)".utf8) }
        let outcome = try transfer(f, .b, .copy)
        let third = f.dest("naam (3).jpg")
        #expect(outcome == TransferOutcome(result: .renamed, destPath: third, warning: nil))
        #expect(f.ops.count(.createExclusive) == 1)
        #expect(f.ops.count(.copyData) == 1)
        #expect(contents(third) == Self.source)
        #expect(tempFiles(f).isEmpty)
        try expectRecord(f, .renamed, dest: third)
    }
}
