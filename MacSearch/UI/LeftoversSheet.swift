import AppKit
import SwiftUI

/// F19d: files of the app that may be incomplete after an interruption. The app never removes them;
/// "Afgehandeld" only clears the record's `temp_path`.
struct LeftoversSheet: View {
    let model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mogelijk onvolledige bestanden").font(.title2)
            Text(
                "Deze bestanden zijn na een onderbreking blijven staan. MacSearch verwijdert ze niet: "
                    + "ruim ze zelf op en klik daarna op Afgehandeld.")
            Text("Verborgen bestanden toont Finder pas na Cmd+Shift+.")
                .foregroundStyle(.secondary)
            List(model.leftovers) { leftover in
                VStack(alignment: .leading, spacing: 6) {
                    Text(leftover.path)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    HStack {
                        Button("Kopieer pad") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(leftover.path, forType: .string)
                        }
                        Button("Toon in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: leftover.path)])
                        }
                        Button("Afgehandeld") {
                            Task { await model.acknowledgeLeftover(leftover) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            HStack {
                Spacer()
                Button("Sluiten") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(minWidth: 620, minHeight: 360)
        .onChange(of: model.leftovers.isEmpty) { _, empty in
            if empty { isPresented = false }
        }
    }
}
