import Foundation
import UniformTypeIdentifiers

struct FoundFile: Sendable, Hashable {
    let url: URL
    let size: Int64
}

enum ScanEvent: Sendable {
    case found([FoundFile])
    case progress(scanned: Int, skipped: Int)
}

enum ScanError: Error {
    case sourceUnreadable
}

/// Recursive, streaming search for matching photos and videos (spec F6–F10).
struct MediaScanner: Sendable {
    static let maxBatch = 200
    static let maxBatchInterval: Duration = .milliseconds(100)

    private let onItem: (@Sendable (Int) -> Void)?

    /// `onItem` is a test hook, called with the sequence number of every enumerated item; it may block.
    init(onItem: (@Sendable (Int) -> Void)? = nil) {
        self.onItem = onItem
    }

    func scan(_ ctx: SearchContext) -> AsyncThrowingStream<ScanEvent, Error> {
        let onItem = self.onItem
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                Self.enumerate(ctx, onItem: onItem, continuation: continuation)
            }
            // Cancelling the consumer stops the producer (F9).
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Synchronous `nextObject()` loop; runs on a detached task, never on the main actor.
    private static func enumerate(
        _ ctx: SearchContext,
        onItem: (@Sendable (Int) -> Void)?,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) {
        let keys: [URLResourceKey] = [
            .contentTypeKey, .isDirectoryKey, .fileResourceIdentifierKey, .fileSizeKey, .isReadableKey,
        ]
        let skipped = SkipCounter()
        guard let enumerator = FileManager.default.enumerator(
            at: ctx.source,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                skipped.value += 1
                return true
            })
        else {
            continuation.finish(throwing: ScanError.sourceUnreadable)
            return
        }

        let keySet = Set(keys)
        let clock = ContinuousClock()
        var scanned = 0
        var batch: [FoundFile] = []
        var lastFlush = clock.now

        func flush() {
            if !batch.isEmpty {
                continuation.yield(.found(batch))
                batch.removeAll(keepingCapacity: true)
            }
            continuation.yield(.progress(scanned: scanned, skipped: skipped.value))
            lastFlush = clock.now
        }

        while let item = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            scanned += 1
            onItem?(scanned)
            if Task.isCancelled { break }

            guard let values = try? item.resourceValues(forKeys: keySet) else {
                skipped.value += 1
                continue
            }
            if values.isDirectory == true {
                if let excluded = ctx.excluded, let identifier = values.fileResourceIdentifier,
                   FileIdentity(resourceIdentifier: identifier) == excluded {
                    enumerator.skipDescendants()
                }
            } else if let type = values.contentType, type.conforms(to: .image) || type.conforms(to: .movie),
                      KeywordMatcher.matches(fileName: item.lastPathComponent, keywords: ctx.keywords) {
                if values.isReadable == true {
                    batch.append(FoundFile(url: item, size: Int64(values.fileSize ?? 0)))
                } else {
                    skipped.value += 1 // F10
                }
            }

            if batch.count >= maxBatch || clock.now - lastFlush >= maxBatchInterval {
                flush()
            }
        }

        if !Task.isCancelled {
            flush()
        }
        continuation.finish()
    }
}

/// The enumerator's error handler is an escaping closure that runs synchronously inside
/// `nextObject()`, on the same thread as the loop, so a plain reference box is enough.
private final class SkipCounter {
    var value = 0
}
