import Foundation
import Synchronization
import Testing
@testable import MacSearch

@Suite struct MediaScannerTests {
    let fm = FileManager.default

    struct Collected {
        var found: [FoundFile] = []
        var batchSizes: [Int] = []
        var lastProgress: (scanned: Int, skipped: Int)?
    }

    func makeTempDir() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("MediaScannerTests-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    func touch(_ url: URL) throws -> URL {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(fm.createFile(atPath: url.path, contents: Data()))
        return url
    }

    func context(source: URL, root: URL, dest: URL? = nil) throws -> SearchContext {
        let dest = dest ?? root.appendingPathComponent("uit")
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        return try SearchContext.make(source: source, keywordsRaw: "janpeter visser", destRoot: dest)
    }

    func collect(_ stream: AsyncThrowingStream<ScanEvent, Error>) async throws -> Collected {
        var result = Collected()
        for try await event in stream {
            switch event {
            case .found(let files):
                result.found += files
                result.batchSizes.append(files.count)
            case .progress(let scanned, let skipped):
                result.lastProgress = (scanned, skipped)
            }
        }
        return result
    }

    /// Waits for a semaphore on a GCD thread, so no cooperative thread blocks.
    func waitOffPool(_ semaphore: DispatchSemaphore) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                semaphore.wait()
                continuation.resume()
            }
        }
    }

    func names(_ files: [FoundFile]) -> Set<String> {
        Set(files.map(\.url.lastPathComponent))
    }

    @Test func findsOnlyVisibleMatchingMedia() async throws {
        let root = try makeTempDir(); defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("bron")
        try touch(source.appendingPathComponent(".x/janpeter_visser.jpg"))
        try touch(source.appendingPathComponent("Fotos.photoslibrary/originals/janpeter_visser_lib.jpg"))
        try touch(source.appendingPathComponent("janpeter_visser.txt"))
        let dest = source.appendingPathComponent("uit")
        try touch(dest.appendingPathComponent("janpeter_visser_oud.jpg"))
        try touch(source.appendingPathComponent("a/IMG_janpeter_visser.jpg"))
        try touch(source.appendingPathComponent("b/c/janpeter-visser.mov"))
        let ctx = try context(source: source, root: root, dest: dest)

        let result = try await collect(MediaScanner().scan(ctx))
        #expect(names(result.found) == ["IMG_janpeter_visser.jpg", "janpeter-visser.mov"])
    }

    @Test func unreadableFolderIsSkippedAndScanFinishes() async throws {
        let root = try makeTempDir(); defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("bron")
        try touch(source.appendingPathComponent("janpeter_visser.jpg"))
        let locked = source.appendingPathComponent("dicht")
        try touch(locked.appendingPathComponent("janpeter_visser_2.jpg"))
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let ctx = try context(source: source, root: root)

        let result = try await collect(MediaScanner().scan(ctx))
        #expect(names(result.found) == ["janpeter_visser.jpg"])
        #expect((result.lastProgress?.skipped ?? 0) >= 1)
    }

    @Test func unreadableFileIsSkipped() async throws {
        let root = try makeTempDir(); defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("bron")
        try touch(source.appendingPathComponent("janpeter_visser_open.jpg"))
        let locked = try touch(source.appendingPathComponent("janpeter_visser_dicht.jpg"))
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let ctx = try context(source: source, root: root)

        let result = try await collect(MediaScanner().scan(ctx))
        #expect(names(result.found) == ["janpeter_visser_open.jpg"])
        #expect(result.lastProgress?.skipped == 1)
    }

    @Test func cancellingTheConsumerStopsTheProducer() async throws {
        let root = try makeTempDir(); defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("bron")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        for i in 0..<2_000 {
            fm.createFile(atPath: source.appendingPathComponent("janpeter_visser_\(i).jpg").path, contents: nil)
        }
        let ctx = try context(source: source, root: root)

        let reached = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let highest = Mutex(0)
        let scanner = MediaScanner(onItem: { index in
            highest.withLock { $0 = max($0, index) }
            if index == 500 {
                reached.signal()
                release.wait()
            }
        })
        let consumer = Task {
            for try await _ in scanner.scan(ctx) {}
        }
        await waitOffPool(reached)
        consumer.cancel()
        release.signal()
        try await Task.sleep(for: .milliseconds(200))
        #expect(highest.withLock { $0 } <= 502)
    }

    @Test func finalProgressCountsEveryEnumeratedItem() async throws {
        let root = try makeTempDir(); defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("bron")
        for dir in ["d1", "d2", "d3"] {
            for i in 0..<10 {
                try touch(source.appendingPathComponent("\(dir)/bestand_\(i).txt"))
            }
        }
        let ctx = try context(source: source, root: root)

        let result = try await collect(MediaScanner().scan(ctx))
        #expect(result.lastProgress?.scanned == 33)
    }

    @Test func symlinkedSourceIsScanned() async throws {
        let root = try makeTempDir(); defer { try? fm.removeItem(at: root) }
        let real = root.appendingPathComponent("echt")
        try touch(real.appendingPathComponent("janpeter_visser.jpg"))
        let link = root.appendingPathComponent("bron-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let ctx = try context(source: link, root: root)

        let result = try await collect(MediaScanner().scan(ctx))
        #expect(names(result.found) == ["janpeter_visser.jpg"])
    }

    // Review Focus 2: very large result sets arrive in batches of at most 200.
    @Test func largeResultSetsArriveInBoundedBatches() async throws {
        let root = try makeTempDir(); defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("bron")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        for i in 0..<5_000 {
            fm.createFile(atPath: source.appendingPathComponent("janpeter_visser_\(i).jpg").path, contents: nil)
        }
        let ctx = try context(source: source, root: root)

        let result = try await collect(MediaScanner().scan(ctx))
        #expect(result.found.count == 5_000)
        #expect(result.batchSizes.allSatisfy { $0 <= 200 })
    }
}
