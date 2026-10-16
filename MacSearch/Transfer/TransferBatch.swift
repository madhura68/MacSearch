import Darwin
import Foundation
import Synchronization

enum FatalCause: Sendable, Equatable {
    case destinationUnusable, runInsertFailed, aborted
}

struct BatchSummary: Sendable {
    let runId: Int64?
    /// The status as written; `running` when even the final write failed (F19c).
    let status: RunStatus?
    let counts: [ActionResult: Int]
    /// Warnings next to successful results (F17); the causes of `failed` stay in the history.
    let warnings: [String]
    let fatalError: String?
    let fatalCause: FatalCause?
    let destFolder: String
}

/// Stop (F0d): the batch finishes the current file and starts no next one.
final class StopFlag: Sendable {
    private let flag = Atomic<Bool>(false)

    func stop() {
        flag.store(true, ordering: .relaxed)
    }

    var isStopped: Bool {
        flag.load(ordering: .relaxed)
    }
}

/// Processes the selected files of one run, with the bookkeeping of F19a–F19c around `FileTransfer`.
struct TransferBatch: Sendable {
    let store: HistoryWriting
    let ops: FileOps
    let uuids: UUIDSource
    let isUsable: @Sendable (URL) -> Bool

    init(
        store: HistoryWriting, ops: FileOps, uuids: UUIDSource,
        isUsable: @escaping @Sendable (URL) -> Bool = destinationUsable
    ) {
        self.store = store
        self.ops = ops
        self.uuids = uuids
        self.isUsable = isUsable
    }

    /// F14: `yyyy-MM-dd` of the moment of OK, Gregorian, `en_US_POSIX`, local time zone.
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// The date comes only from `confirmedAt`; the batch never reads the clock (F0d).
    @concurrent
    func run(
        context: SearchContext, files: [FoundFile], mode: TransferMode, confirmedAt: Date,
        foundCount: Int, scanComplete: Bool, skippedCount: Int,
        stop: StopFlag, progress: @escaping @Sendable (_ processed: Int, _ total: Int) -> Void
    ) async -> BatchSummary {
        let destFolder = context.destRoot.appendingPathComponent(context.folderName)
            .appendingPathComponent(Self.day(confirmedAt)).path
        func summary(
            runId: Int64?, status: RunStatus?, counts: [ActionResult: Int] = [:], warnings: [String] = [],
            fatalError: String? = nil, fatalCause: FatalCause? = nil
        ) -> BatchSummary {
            BatchSummary(
                runId: runId, status: status, counts: counts, warnings: warnings, fatalError: fatalError,
                fatalCause: fatalCause, destFolder: destFolder)
        }

        guard isUsable(context.destRoot) else {
            return summary(
                runId: nil, status: nil,
                fatalError: "De bestemming \(context.destRoot.path) bestaat niet of is niet schrijfbaar.",
                fatalCause: .destinationUnusable)
        }

        let runId: Int64
        do {
            runId = try store.insertRun(
                NewRun(
                    createdAt: iso8601(confirmedAt), sourcePath: context.source.path, keywordsRaw: context.keywordsRaw,
                    destRoot: context.destRoot.path, destFolder: destFolder, mode: mode, foundCount: foundCount,
                    selectedCount: files.count, scanComplete: scanComplete, skippedCount: skippedCount))
        } catch {
            return summary(
                runId: nil, status: nil,
                fatalError: "De run kon niet in de geschiedenis worden vastgelegd; er is niets gekopieerd of verplaatst.",
                fatalCause: .runInsertFailed)
        }

        do throws(POSIXFailure) {
            try ops.createDirectories(destFolder)
        } catch {
            return summary(
                runId: runId, status: finish(runId, .aborted),
                fatalError: "De doelmap \(destFolder) kon niet worden aangemaakt: \(String(cString: strerror(error.errno))).",
                fatalCause: .aborted)
        }

        // Only now that the folder exists can its volume be asked for RENAME_EXCL and its identifier.
        let transfer = FileTransfer(
            ops: ops, store: store, uuids: uuids, renameExclusive: ops.supportsRenameExclusive(volumeOf: destFolder))

        var counts: [ActionResult: Int] = [:]
        var warnings: [String] = []
        var lastProcessed: FoundFile?
        var stopped = false
        for (index, file) in files.enumerated() {
            if stop.isStopped {
                stopped = true
                break
            }
            do {
                let outcome = try transfer.transfer(file, runId: runId, destFolder: destFolder, mode: mode)
                counts[outcome.result, default: 0] += 1
                if outcome.result != .failed, let warning = outcome.warning {
                    warnings.append("\(file.url.lastPathComponent): \(warning)")
                }
                lastProcessed = file
            } catch {
                // F19b: stop before the next file; aborted wins over Stop.
                if error.fileProcessed {
                    lastProcessed = file
                    if let outcome = error.outcome { counts[outcome.result, default: 0] += 1 }
                }
                let last = lastProcessed?.url.path ?? "geen bestand verwerkt"
                return summary(
                    runId: runId, status: finish(runId, .aborted), counts: counts, warnings: warnings,
                    fatalError: "De geschiedenis kon niet worden bijgewerkt; de verwerking is gestopt. "
                        + "Laatst verwerkte bestand: \(last).",
                    fatalCause: .aborted)
            }
            progress(index + 1, files.count)
        }

        let status = finish(runId, stopped ? .cancelled : .completed)
        if status == .running {
            warnings.append("De eindstatus van deze run kon niet worden opgeslagen.")
        }
        return summary(runId: runId, status: status, counts: counts, warnings: warnings)
    }

    /// Writes the final status; when that fails the run stays `running` and becomes `interrupted` at
    /// the next start (F19c).
    private func finish(_ runId: Int64, _ status: RunStatus) -> RunStatus {
        do {
            try store.finishRun(id: runId, status: status)
            return status
        } catch {
            return .running
        }
    }
}
