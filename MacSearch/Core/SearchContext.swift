import Foundation

/// F25/F26: the destination exists, is a folder and is writable.
func destinationUsable(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        return false
    }
    return access(url.path, W_OK) == 0
}

/// F14: the keyword folder name as typed, made valid on exFAT and SMB.
/// Order: replace characters, trim, then collapse internal whitespace.
func keywordFolderName(_ raw: String) -> String {
    let forbidden: Set<Character> = ["/", ":", "\\", "?", "*", "\"", "<", ">", "|"]
    let replaced = String(raw.map { forbidden.contains($0) ? "-" : $0 })
    let trimmed = replaced.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    return trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

enum SearchValidationError: Error, Equatable {
    case sourceMissing, destinationUnusable, sameFolder, noKeywords, folderNameTooLong
}

enum Containment: Equatable {
    case none, destInsideSource, sourceInsideDest
}

/// The immutable context fixed at Search (F0a). Results, exclusion, target path and history
/// always belong to exactly one context.
struct SearchContext: Sendable {
    let source: URL
    let destRoot: URL
    let keywordsRaw: String
    let keywords: [String]
    let folderName: String
    /// Only set when the destination lies strictly inside the source (F8).
    let excluded: FileIdentity?
    /// For the F27 warning.
    let containment: Containment

    /// Does I/O; call it off the main actor (NF1).
    static func make(source: URL, keywordsRaw: String, destRoot: URL) throws(SearchValidationError) -> SearchContext {
        let source = source.resolvingSymlinksInPath()
        let destRoot = destRoot.resolvingSymlinksInPath()

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let sourceID = FileIdentity(url: source) else {
            throw .sourceMissing
        }
        guard destinationUsable(destRoot), let destID = FileIdentity(url: destRoot) else {
            throw .destinationUnusable
        }
        guard sourceID != destID else { throw .sameFolder }

        let keywords = KeywordMatcher.keywords(from: keywordsRaw)
        guard !keywords.isEmpty else { throw .noKeywords }
        let folderName = keywordFolderName(keywordsRaw)
        guard folderName.utf8.count <= 255 else { throw .folderNameTooLong }

        let containment: Containment
        if ancestorIdentities(of: destRoot).contains(sourceID) {
            containment = .destInsideSource
        } else if ancestorIdentities(of: source).contains(destID) {
            containment = .sourceInsideDest
        } else {
            containment = .none
        }

        return SearchContext(
            source: source, destRoot: destRoot, keywordsRaw: keywordsRaw, keywords: keywords,
            folderName: folderName, excluded: containment == .destInsideSource ? destID : nil,
            containment: containment)
    }

    /// Identities of all parent folders of an already resolved URL, up to the root.
    private static func ancestorIdentities(of url: URL) -> [FileIdentity] {
        var result: [FileIdentity] = []
        var current = url
        while current.path != "/" {
            current = current.deletingLastPathComponent()
            if let id = FileIdentity(url: current) { result.append(id) }
        }
        return result
    }
}
