import Foundation
import Testing
@testable import MacSearch

enum Route: Sendable, CustomStringConvertible {
    case a, b, c
    var description: String { "route \(self == .a ? "A" : self == .b ? "B" : "C")" }
}

/// `bron/naam.jpg`, an empty `doel/`, and a run in an in-memory `RecordingStore`, on real files
/// under a canonical temporary path. File operations go through a `FaultyFileOps`.
struct TransferFixture {
    static let source = Data("ABC".utf8)

    let root: URL
    let sourceURL: URL
    let content: Data
    let destFolder: String
    let store: RecordingStore
    let ops: FaultyFileOps
    let runId: Int64

    var sourcePath: String { sourceURL.path }
    var desired: String { dest("naam.jpg") }
    func dest(_ name: String) -> String { destFolder + "/" + name }
    func remove() { try? FileManager.default.removeItem(at: root) }

    init(content: Data = TransferFixture.source) throws {
        let fm = FileManager.default
        root = URL(fileURLWithPath: realPath(NSTemporaryDirectory()))
            .appendingPathComponent("TransferFixture-\(UUID().uuidString)")
        let bron = root.appendingPathComponent("bron")
        let doel = root.appendingPathComponent("doel")
        try fm.createDirectory(at: bron, withIntermediateDirectories: true)
        try fm.createDirectory(at: doel, withIntermediateDirectories: true)
        sourceURL = bron.appendingPathComponent("naam.jpg")
        try content.write(to: sourceURL)
        self.content = content
        destFolder = doel.path
        store = try RecordingStore()
        ops = FaultyFileOps()
        runId = try store.inner.insertRun(
            NewRun(
                createdAt: iso8601(Date()), sourcePath: bron.path, keywordsRaw: "naam", destRoot: doel.path,
                destFolder: doel.path, mode: .copy, foundCount: 1, selectedCount: 1, scanComplete: true, skippedCount: 0))
    }

    /// Route A: move on the same volume with `renameExclusive`. Route B: `renameExclusive`, and for a move
    /// the destination reports another volume. Route C: no `renameExclusive`.
    func transfer(_ route: Route, _ mode: TransferMode, uuids: UUIDSource = SystemUUIDSource()) throws -> TransferOutcome {
        if route == .b && mode == .move { ops.overrideVolumeID(prefix: destFolder, id: "ander-volume") }
        let transfer = FileTransfer(ops: ops, store: store, uuids: uuids, renameExclusive: route != .c)
        return try transfer.transfer(
            FoundFile(url: sourceURL, size: Int64(content.count)), runId: runId, destFolder: destFolder, mode: mode)
    }

    /// A file that is not the app's; never overwrites.
    static func plant(_ path: String, _ data: Data) {
        try? data.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
    }

    /// On the given publication attempts (route A/B: the rename, route C: the exclusive create of the
    /// final name), a foreign file appears under the chosen name just before the call.
    func plantOnPublication(_ route: Route, onCalls: Set<Int>, _ content: @escaping @Sendable (Int) -> Data) {
        let ops = ops
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

    func tempFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: destFolder)) ?? []).filter { $0.hasPrefix(".macsearch-") }
    }

    func inserts() -> [RecordingStore.Call] {
        store.calls.filter { if case .insertAction = $0 { true } else { false } }
    }

    func rows() throws -> [ActionRow] {
        try store.actions(runId: runId)
    }

    /// Exactly one record for the source, with this result, destination (when given) and `temp_path`.
    @discardableResult
    func expectRecord(
        _ result: ActionResult, dest: String?, tempPath: String? = nil, sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> ActionRow {
        let rows = try rows()
        #expect(rows.count == 1, "records: \(rows)", sourceLocation: sourceLocation)
        let row = try #require(rows.first, sourceLocation: sourceLocation)
        #expect(row.sourcePath == sourcePath, sourceLocation: sourceLocation)
        #expect(row.result == result, sourceLocation: sourceLocation)
        if let dest { #expect(row.destPath == dest, sourceLocation: sourceLocation) }
        #expect(row.tempPath == tempPath, sourceLocation: sourceLocation)
        return row
    }
}
