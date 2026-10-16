import AppKit
import SwiftUI

/// F22 and F20: the form, the mode toggle, Search and the history. Every change goes through `AppModel`.
struct SidebarView: View {
    let model: AppModel

    private enum PendingChange: Identifiable {
        case field(FormField, String)
        case history(RunSummary)

        var id: String {
            switch self {
            case .field(let field, let value): "\(field)-\(value)"
            case .history(let run): "run-\(run.id)"
            }
        }
    }

    @State private var pending: PendingChange?

    var body: some View {
        Form {
            Section("Zoeken") {
                folderRow("Bron", path: model.sourcePath, field: .source)
                TextField("Keywords", text: keywordsBinding, prompt: Text("bijv. janpeter visser"))
                    .disabled(!model.formEditable)
                folderRow("Bestemming", path: model.destPath, field: .destination)
                Picker("Modus", selection: modeBinding) {
                    Text("Kopiëren").tag(TransferMode.copy)
                    Text("Verplaatsen").tag(TransferMode.move)
                }
                .pickerStyle(.segmented)
                .disabled(!model.modeEditable)
                HStack {
                    Button("Zoeken") { model.search() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canSearch)
                    if model.phase == .scanning {
                        Button("Annuleren") { model.cancelScan() }
                    }
                }
                if let warning = containmentWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
            Section("Geschiedenis") {
                ForEach(model.history) { run in
                    Button { request(.history(run)) } label: { HistoryRow(run: run) }
                        .buttonStyle(.plain)
                }
            }
            .disabled(!model.formEditable)
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Huidige resultaten verwerpen?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { change in
            Button("Verwerpen", role: .destructive) { confirm(change) }
            Button("Annuleren", role: .cancel) {}
        } message: { _ in
            Text("Deze wijziging verwerpt de gevonden bestanden en je selectie.")
        }
    }

    private var keywordsBinding: Binding<String> {
        Binding(get: { model.keywordsRaw }, set: { request(.field(.keywords, $0)) })
    }

    private var modeBinding: Binding<TransferMode> {
        Binding(get: { model.mode }, set: { model.setMode($0) })
    }

    private var containmentWarning: String? {
        switch model.containment {
        case .none: nil
        case .destInsideSource: "De bestemming ligt binnen de bron; die map wordt bij het zoeken overgeslagen."
        case .sourceInsideDest: "De bron ligt binnen de bestemming."
        }
    }

    private func folderRow(_ title: String, path: String?, field: FormField) -> some View {
        LabeledContent(title) {
            HStack {
                Text(path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Geen map gekozen")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(path == nil ? .secondary : .primary)
                    .help(path ?? "")
                Button("Kies…") { chooseFolder(title: title, field: field) }
                    .disabled(!model.formEditable)
            }
        }
    }

    private func chooseFolder(title: String, field: FormField) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = field == .destination
        panel.message = "Kies de \(title.lowercased())"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        request(.field(field, url.path))
    }

    private func request(_ change: PendingChange) {
        let result: ChangeResult =
            switch change {
            case .field(let field, let value): model.setField(field, value)
            case .history(let run): model.requestHistory(run)
            }
        if result == .needsConfirmation { pending = change }
    }

    private func confirm(_ change: PendingChange) {
        switch change {
        case .field(let field, let value): model.confirmFormChange(field, value)
        case .history(let run): model.confirmHistory(run)
        }
        pending = nil
    }
}

/// F20: date, keywords, source → destination and the processed count; incomplete runs are marked (F19c).
struct HistoryRow: View {
    let run: RunSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(run.keywordsRaw).font(.body.weight(.medium))
                Spacer()
                if run.isIncomplete {
                    Label("onvolledig", systemImage: "exclamationmark.circle")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Text(date).font(.caption).foregroundStyle(.secondary)
            Text("\(folder(run.sourcePath)) → \(folder(run.destRoot)) · \(run.processedCount) verwerkt · \(modeName)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    private var date: String {
        (try? Date(run.createdAt, strategy: .iso8601))?.formatted(date: .abbreviated, time: .shortened)
            ?? run.createdAt
    }

    private var modeName: String {
        run.mode == .copy ? "kopiëren" : "verplaatsen"
    }

    private func folder(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
