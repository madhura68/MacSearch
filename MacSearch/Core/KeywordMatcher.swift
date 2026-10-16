import Foundation

/// Matches keywords against file names (spec F1–F5).
enum KeywordMatcher {
    /// F1: lowercase, fold diacritics, then keep only letters and digits.
    static func norm(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return String(folded.filter { $0.isLetter || $0.isNumber })
    }

    /// F2: split on whitespace, normalise each part and drop the empty ones.
    static func keywords(from input: String) -> [String] {
        input.split(whereSeparator: \.isWhitespace)
            .map { norm(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// F3/F4: the keywords occur in order as non-overlapping substrings of the normalised
    /// name without extension. Greedy leftmost search: each keyword starts after the previous one ends.
    static func matches(fileName: String, keywords: [String]) -> Bool {
        guard !keywords.isEmpty else { return false }
        let name = norm((fileName as NSString).deletingPathExtension)
        var searchStart = name.startIndex
        for keyword in keywords {
            guard let found = name.range(of: keyword, range: searchStart..<name.endIndex) else { return false }
            searchStart = found.upperBound
        }
        return true
    }
}
