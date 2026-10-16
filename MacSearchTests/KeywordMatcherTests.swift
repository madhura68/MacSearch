import Testing
@testable import MacSearch

@Suite struct KeywordMatcherTests {
    static let janpeterVisserMatches = [
        "IMG_JanPeter_Visser.jpg",
        "2024 janpeter-visser 01.heic",
        "xyzJanpeterVisser.mov",
        "Jan_Peter Visser.png",
        "janpeter op strand met visser.jpg",
        "JANPETER.VISSER.jpeg",
    ]
    static let janpeterVisserNonMatches = ["visser_janpeter.jpg", "janpeter.jpg", "visser.jpg"]

    @Test(arguments: janpeterVisserMatches)
    func matchesF5(_ name: String) {
        #expect(KeywordMatcher.matches(fileName: name, keywords: KeywordMatcher.keywords(from: "janpeter visser")))
    }

    @Test(arguments: janpeterVisserNonMatches)
    func doesNotMatchF5(_ name: String) {
        #expect(!KeywordMatcher.matches(fileName: name, keywords: KeywordMatcher.keywords(from: "janpeter visser")))
    }

    @Test func foldsAccentsInKeywords() {
        #expect(KeywordMatcher.matches(fileName: "Rene_2020.jpg", keywords: KeywordMatcher.keywords(from: "rené")))
    }

    @Test(arguments: [("janpeter_janpeter.jpg", true), ("janpeter.jpg", false)])
    func repeatedKeywordsDoNotOverlap(_ name: String, _ expected: Bool) {
        #expect(KeywordMatcher.matches(fileName: name, keywords: KeywordMatcher.keywords(from: "janpeter janpeter")) == expected)
    }

    // Review Focus 1: a decomposed (NFD) name, as found on external disks, matches a composed keyword.
    @Test func decomposedNameMatchesComposedKeyword() {
        #expect(KeywordMatcher.matches(fileName: "Rene\u{301}_2020.jpg", keywords: KeywordMatcher.keywords(from: "René")))
    }

    @Test func inputWithoutLettersOrDigitsGivesNoKeywords() {
        #expect(KeywordMatcher.keywords(from: "  ...  -- ") == [])
    }
}
