import SwiftUI

enum AppEnvironment {
    /// True inside a test host, so the app skips all startup work and tests never touch the real database.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}

@main
struct MacSearchApp: App {
    var body: some Scene {
        WindowGroup {
            Text("MacSearch")
                .frame(minWidth: 480, minHeight: 320)
        }
    }
}
