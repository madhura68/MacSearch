import QuickLook
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// F11–F13: one result large, with previous/next, its checkbox, all on/off, the counter and OK.
struct ResultsSliderView: View {
    let model: AppModel
    @State private var index = 0
    @State private var previewURL: URL?

    var body: some View {
        VStack(spacing: 12) {
            header
            if case .reviewing(incomplete: true) = model.phase {
                Label(
                    "Onvolledig: de scan is niet afgerond. Je kunt de gevonden bestanden toch verwerken.",
                    systemImage: "exclamationmark.triangle"
                )
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            }
            if let current {
                slider(current)
            } else {
                ContentUnavailableView(emptyTitle, systemImage: "photo.on.rectangle.angled")
                    .frame(minHeight: 0, maxHeight: .infinity)
            }
        }
        .padding([.horizontal, .top])
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        // The checkbox and the actions stay visible whatever the size of the image.
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if let current { selectionRow(current) }
                footer
            }
            .padding()
            .background(.bar)
        }
        .quickLookPreview($previewURL)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            step(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            step(1)
            return .handled
        }
        .onChange(of: model.results.count) { _, count in
            index = min(index, max(count - 1, 0))
        }
    }

    private var current: FoundFile? {
        model.results.indices.contains(index) ? model.results[index] : nil
    }

    private var emptyTitle: String {
        switch model.phase {
        case .scanning: "Zoeken…"
        case .reviewing: "Niets gevonden"
        default: "Kies een bron, keywords en een bestemming, en klik op Zoeken"
        }
    }

    private var header: some View {
        HStack {
            if model.phase == .scanning {
                ProgressView().controlSize(.small)
                Text("\(model.results.count) gevonden / \(model.scanned) doorzocht")
            } else if !model.results.isEmpty {
                Text("\(model.selected.count) / \(model.results.count) geselecteerd")
            }
            if model.skipped > 0 {
                Text("· \(model.skipped) overgeslagen").foregroundStyle(.secondary)
            }
            Spacer()
            if !model.results.isEmpty {
                Text("\(index + 1) van \(model.results.count)").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private func slider(_ file: FoundFile) -> some View {
        HStack {
            Button { step(-1) } label: { Image(systemName: "chevron.left").font(.title) }
                .buttonStyle(.borderless)
                .disabled(index == 0)
            Thumbnail(url: file.url)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            Button { step(1) } label: { Image(systemName: "chevron.right").font(.title) }
                .buttonStyle(.borderless)
                .disabled(index >= model.results.count - 1)
        }
    }

    private func selectionRow(_ file: FoundFile) -> some View {
        HStack {
            Toggle(
                file.url.lastPathComponent,
                isOn: Binding(get: { model.selected.contains(file.url) }, set: { _ in model.toggle(file.url) }))
            if Self.isVideo(file.url) {
                Button("Afspelen", systemImage: "play.fill") { previewURL = file.url }
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            Button("Alles aan") { model.selectAll() }
                .disabled(model.results.isEmpty || model.phase == .processing)
            Button("Alles uit") { model.selectNone() }
                .disabled(model.results.isEmpty || model.phase == .processing)
            Spacer()
            if case .reviewing = model.phase, !model.destinationOK {
                Text("De bestemming bestaat niet of is niet schrijfbaar.").foregroundStyle(.red).font(.callout)
            }
            Button(model.mode == .copy ? "OK, kopiëren" : "OK, verplaatsen") { model.confirm() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canConfirm)
        }
    }

    private func step(_ delta: Int) {
        guard !model.results.isEmpty else { return }
        index = min(max(index + delta, 0), model.results.count - 1)
    }

    static func isVideo(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
    }
}

/// A Quick Look thumbnail, generated off the main actor; a file without one gets a placeholder.
struct Thumbnail: View {
    let url: URL
    @State private var state = LoadState.loading
    @Environment(\.displayScale) private var scale

    private enum LoadState {
        case loading
        case loaded(NSImage)
        case failed
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView()
            case .loaded(let image):
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            case .failed:
                ContentUnavailableView(
                    "Geen voorbeeld", systemImage: "photo", description: Text(url.lastPathComponent))
            }
        }
        .task(id: url) {
            state = .loading
            let request = QLThumbnailGenerator.Request(
                fileAt: url, size: CGSize(width: 1200, height: 900), scale: scale, representationTypes: .thumbnail)
            let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
            guard !Task.isCancelled else { return }
            state = image.map(LoadState.loaded) ?? .failed
        }
    }
}
