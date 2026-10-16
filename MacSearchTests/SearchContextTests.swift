import Foundation
import Testing
@testable import MacSearch

@Suite struct SearchContextTests {
    let fm = FileManager.default

    /// A fresh temporary directory; the caller removes it.
    func makeTempDir() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("SearchContextTests-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func mkdir(_ url: URL) throws -> URL {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var tempVolumeIsCaseInsensitive: Bool {
        let values = try? FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return values?.volumeSupportsCaseSensitiveNames == false
    }

    @Test func sameFolderIsRefused() throws {
        let root = try makeTempDir(); defer { try? fm.removeItem(at: root) }
        let foto = try mkdir(root.appendingPathComponent("foto"))
        #expect(throws: SearchValidationError.sameFolder) {
            try SearchContext.make(source: foto, keywordsRaw: "jan", destRoot: foto)
        }
    }

    @Test func sameFolderViaSymlinkIsRefused() throws {
        let root = try makeTempDir(); defer { try? fm.removeItem(at: root) }
        let foto = try mkdir(root.appendingPathComponent("foto"))
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: foto)
        #expect(throws: SearchValidationError.sameFolder) {
            try SearchContext.make(source: foto, keywordsRaw: "jan", destRoot: link)
        }
    }

    @Test(.enabled(if: SearchContextTests.tempVolumeIsCaseInsensitive, "needs a case-insensitive volume"))
    func sameFolderViaCaseVariantIsRefused() throws {
        let root = try makeTempDir(); defer { try? fm.removeItem(at: root) }
        let foto = try mkdir(root.appendingPathComponent("foto"))
        let upper = root.appendingPathComponent("FOTO")
        #expect(throws: SearchValidationError.sameFolder) {
            try SearchContext.make(source: foto, keywordsRaw: "jan", destRoot: upper)
        }
    }

    @Test func destinationInsideSourceIsExcluded() throws {
        let root = try makeTempDir(); defer { try? fm.removeItem(at: root) }
        let source = try mkdir(root.appendingPathComponent("bron"))
        let dest = try mkdir(source.appendingPathComponent("a/uit"))
        let ctx = try SearchContext.make(source: source, keywordsRaw: "jan", destRoot: dest)
        #expect(ctx.containment == .destInsideSource)
        #expect(ctx.excluded == FileIdentity(url: dest))
        #expect(ctx.excluded != nil)
    }

    @Test func symlinkedDestinationInsideSourceIsExcluded() throws {
        let root = try makeTempDir(); defer { try? fm.removeItem(at: root) }
        let source = try mkdir(root.appendingPathComponent("bron"))
        let sub = try mkdir(source.appendingPathComponent("uit"))
        let link = root.appendingPathComponent("uit-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: sub)
        let ctx = try SearchContext.make(source: source, keywordsRaw: "jan", destRoot: link)
        #expect(ctx.containment == .destInsideSource)
        #expect(ctx.excluded == FileIdentity(url: sub))
    }

    @Test func siblingWithPrefixNameIsNotExcluded() throws {
        let root = try makeTempDir(); defer { try? fm.removeItem(at: root) }
        let foto = try mkdir(root.appendingPathComponent("foto"))
        let fotos = try mkdir(root.appendingPathComponent("fotos"))
        let ctx = try SearchContext.make(source: foto, keywordsRaw: "jan", destRoot: fotos)
        #expect(ctx.excluded == nil)
        #expect(ctx.containment == .none)
    }

    @Test func sourceInsideDestinationIsNotExcluded() throws {
        let root = try makeTempDir(); defer { try? fm.removeItem(at: root) }
        let dest = try mkdir(root.appendingPathComponent("uit"))
        let source = try mkdir(dest.appendingPathComponent("bron"))
        let ctx = try SearchContext.make(source: source, keywordsRaw: "jan", destRoot: dest)
        #expect(ctx.containment == .sourceInsideDest)
        #expect(ctx.excluded == nil)
    }

    @Test func keywordFolderNameFollowsF14() {
        #expect(keywordFolderName(" .a/b:c?*\"<>|\\  d.. ") == "a-b-c------- d")
    }

    @Test func folderNameOver255BytesIsRefused() throws {
        let root = try makeTempDir(); defer { try? fm.removeItem(at: root) }
        let source = try mkdir(root.appendingPathComponent("bron"))
        let dest = try mkdir(root.appendingPathComponent("uit"))
        let long = String(repeating: "é", count: 128) // 256 bytes in UTF-8
        #expect(throws: SearchValidationError.folderNameTooLong) {
            try SearchContext.make(source: source, keywordsRaw: long, destRoot: dest)
        }
    }

    // Review Focus 5: input without usable characters blocks searching.
    @Test func keywordsWithoutLettersAreRefused() throws {
        let root = try makeTempDir(); defer { try? fm.removeItem(at: root) }
        let source = try mkdir(root.appendingPathComponent("bron"))
        let dest = try mkdir(root.appendingPathComponent("uit"))
        #expect(throws: SearchValidationError.noKeywords) {
            try SearchContext.make(source: source, keywordsRaw: "...", destRoot: dest)
        }
    }

    @Test func missingSourceIsRefused() throws {
        let root = try makeTempDir(); defer { try? fm.removeItem(at: root) }
        let dest = try mkdir(root.appendingPathComponent("uit"))
        #expect(throws: SearchValidationError.sourceMissing) {
            try SearchContext.make(source: root.appendingPathComponent("nergens"), keywordsRaw: "jan", destRoot: dest)
        }
    }

    @Test func missingDestinationIsRefused() throws {
        let root = try makeTempDir(); defer { try? fm.removeItem(at: root) }
        let source = try mkdir(root.appendingPathComponent("bron"))
        #expect(throws: SearchValidationError.destinationUnusable) {
            try SearchContext.make(source: source, keywordsRaw: "jan", destRoot: root.appendingPathComponent("nergens"))
        }
    }

    @Test func readOnlyDestinationIsRefused() throws {
        let root = try makeTempDir(); defer { try? fm.removeItem(at: root) }
        let source = try mkdir(root.appendingPathComponent("bron"))
        let dest = try mkdir(root.appendingPathComponent("uit"))
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dest.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path) }
        #expect(!destinationUsable(dest))
        #expect(throws: SearchValidationError.destinationUnusable) {
            try SearchContext.make(source: source, keywordsRaw: "jan", destRoot: dest)
        }
    }

    @Test func symlinkedSourceIsResolved() throws {
        let root = try makeTempDir(); defer { try? fm.removeItem(at: root) }
        let real = try mkdir(root.appendingPathComponent("echt"))
        let dest = try mkdir(root.appendingPathComponent("uit"))
        let link = root.appendingPathComponent("bron-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let ctx = try SearchContext.make(source: link, keywordsRaw: "jan visser", destRoot: dest)
        #expect(ctx.source.path == real.resolvingSymlinksInPath().path)
        #expect(ctx.keywords == ["jan", "visser"])
        #expect(ctx.folderName == "jan visser")
    }
}
