import AppKit
import SwiftUI

/// F18: the progress bar of the running batch, with Stop (F0d).
struct ProcessingView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Text(model.mode == .copy ? "Bezig met kopiëren…" : "Bezig met verplaatsen…").font(.title2)
            ProgressView(value: Double(model.processed), total: Double(max(model.total, 1)))
                .frame(maxWidth: 480)
            Text("\(model.processed) / \(model.total)").monospacedDigit()
            Button("Stop") { model.stop() }
            Text("Stop maakt het lopende bestand eerst af.").font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// F18: counts per result kind, the warnings, and "Toon in Finder" for the target folder.
struct SummaryView: View {
    let model: AppModel

    private static let order: [(ActionResult, String)] = [
        (.copied, "Gekopieerd"), (.moved, "Verplaatst"), (.renamed, "Hernoemd"),
        (.skippedIdentical, "Overgeslagen (identiek)"), (.failed, "Mislukt"),
    ]

    var body: some View {
        if let summary = model.summary {
            VStack(alignment: .leading, spacing: 12) {
                Text(title(summary)).font(.title2)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(Self.order, id: \.0) { result, label in
                        if let count = summary.counts[result], count > 0 {
                            GridRow {
                                Text(label)
                                Text("\(count)").monospacedDigit()
                            }
                        }
                    }
                }
                if !summary.warnings.isEmpty {
                    Text("Waarschuwingen").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(summary.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
                HStack {
                    Button("Toon in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: summary.destFolder)])
                    }
                    Spacer()
                    Button("Sluiten") { model.closeSummary() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(maxWidth: 560, maxHeight: .infinity)
        }
    }

    private func title(_ summary: BatchSummary) -> String {
        switch summary.status {
        case .completed: "Klaar"
        case .cancelled: "Gestopt"
        case .aborted: "Afgebroken"
        default: "Onderbroken"
        }
    }
}
