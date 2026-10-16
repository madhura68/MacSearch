import GRDB
import Testing
@testable import MacSearch

@Suite struct SmokeTests {
    @Test func appCodeIsVisible() {
        #expect(AppEnvironment.isRunningTests)
    }

    @Test func grdbIsVisible() throws {
        _ = try DatabaseQueue()
    }
}
