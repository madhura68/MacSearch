import SwiftUI

enum AppEnvironment {
    /// True inside a test host, so the app skips all startup work and tests never touch the real database.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}

/// The real collaborators of `AppModel`; every piece of I/O runs off the main actor (NF1).
enum Production {
    static func databaseURL() -> URL {
        URL.applicationSupportDirectory.appendingPathComponent("MacSearch/macsearch.sqlite")
    }

    @MainActor
    static func makeModel(startup: StartupState) -> AppModel {
        AppModel(
            startup: startup,
            scanner: { MediaScanner().scan($0) },
            batch: { store in TransferBatch(store: store, ops: PosixFileOps(), uuids: SystemUUIDSource()) },
            checkDestination: { url in await Task.detached { destinationUsable(url) }.value },
            makeContext: {
                (source: URL, keywords: String, dest: URL) async throws(SearchValidationError) -> SearchContext in
                let result: Result<SearchContext, SearchValidationError> = await Task.detached {
                    Result { () throws(SearchValidationError) in
                        try SearchContext.make(source: source, keywordsRaw: keywords, destRoot: dest)
                    }
                }.value
                return try result.get()
            },
            loadHistory: { store in
                await Task.detached { try? store.recentRuns(limit: StartupRoutine.historyLimit) }.value
            })
    }
}

@main
struct MacSearchApp: App {
    var body: some Scene {
        WindowGroup {
            if AppEnvironment.isRunningTests {
                Text("MacSearch")
                    .frame(minWidth: 480, minHeight: 320)
            } else {
                RootView()
            }
        }
    }
}

/// A loading screen while the start routine runs, then the main window.
struct RootView: View {
    @State private var model: AppModel?

    var body: some View {
        Group {
            if let model {
                ContentView(model: model)
            } else {
                ProgressView("MacSearch wordt gestart…")
                    .frame(minWidth: 960, minHeight: 640)
            }
        }
        .task {
            guard model == nil else { return }
            let state = await Task.detached {
                StartupRoutine.run(databaseURL: Production.databaseURL(), ops: PosixFileOps())
            }.value
            model = Production.makeModel(startup: state)
        }
    }
}

struct ContentView: View {
    let model: AppModel
    /// F19d: the report opens once per start; closing it handles nothing.
    @State private var leftoversShown = false
    @State private var showLeftovers = false

    var body: some View {
        if let error = model.startupError {
            StartupErrorView(path: error.path, message: error.message)
        } else {
            NavigationSplitView {
                SidebarView(model: model)
                    .navigationSplitViewColumnWidth(min: 300, ideal: 340)
            } detail: {
                detail
            }
            .frame(minWidth: 960, minHeight: 640)
            .sheet(isPresented: $showLeftovers) {
                LeftoversSheet(model: model, isPresented: $showLeftovers)
            }
            .onAppear {
                guard !leftoversShown else { return }
                leftoversShown = true
                showLeftovers = !model.leftovers.isEmpty
            }
            .alert(
                "MacSearch",
                isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.dismissMessage() } })
            ) {
                Button("OK") { model.dismissMessage() }
            } message: {
                Text(model.message ?? "")
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.phase {
        case .processing: ProcessingView(model: model)
        case .done: SummaryView(model: model)
        case .idle, .scanning, .reviewing: ResultsSliderView(model: model)
        }
    }
}

/// F19: the database could not be opened; nothing can be searched or processed.
struct StartupErrorView: View {
    let path: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("De geschiedenis kan niet worden geopend", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 8) {
                Text("Zonder actielog verplaatst of kopieert MacSearch niets.")
                Text(path).textSelection(.enabled).font(.body.monospaced())
                Text(message).foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 960, minHeight: 640)
    }
}
