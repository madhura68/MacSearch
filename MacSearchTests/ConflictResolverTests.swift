import Foundation
import Testing
@testable import MacSearch

@Suite struct ConflictResolverTests {
    let fm = FileManager.default
    let resolver = ConflictResolver(ops: PosixFileOps())

    func makeTempDir() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("ConflictResolverTests-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    func write(_ url: URL, _ text: String) -> URL {
        #expect(fm.createFile(atPath: url.path, contents: Data(text.utf8)))
        return url
    }

    func resolve(_ source: URL, _ desired: URL) throws -> Resolution {
        let size = try #require(try fm.attributesOfItem(atPath: source.path)[.size] as? Int64)
        return try resolver.resolve(sourcePath: source.path, sourceSize: size, desiredPath: desired.path)
    }

    @Test func freeWhenTargetDoesNotExist() throws {
        let dir = try makeTempDir(); defer { try? fm.removeItem(at: dir) }
        let source = write(dir.appendingPathComponent("bron.jpg"), "ABC")
        let desired = dir.appendingPathComponent("naam.jpg")
        #expect(try resolve(source, desired) == .free(desired.path))
    }

    @Test func identicalWhenTargetHasSameContent() throws {
        let dir = try makeTempDir(); defer { try? fm.removeItem(at: dir) }
        let source = write(dir.appendingPathComponent("bron.jpg"), "ABC")
        let desired = write(dir.appendingPathComponent("naam.jpg"), "ABC")
        #expect(try resolve(source, desired) == .identical(desired.path))
    }

    @Test func differentSizeGivesNextName() throws {
        let dir = try makeTempDir(); defer { try? fm.removeItem(at: dir) }
        let source = write(dir.appendingPathComponent("bron.jpg"), "ABC")
        let desired = write(dir.appendingPathComponent("naam.jpg"), "ABCDEF")
        #expect(try resolve(source, desired) == .free(dir.appendingPathComponent("naam (2).jpg").path))
    }

    @Test func identicalSecondCandidateIsSkipped() throws {
        let dir = try makeTempDir(); defer { try? fm.removeItem(at: dir) }
        let source = write(dir.appendingPathComponent("bron.jpg"), "ABC")
        let desired = write(dir.appendingPathComponent("naam.jpg"), "ABCDEF")
        let second = write(dir.appendingPathComponent("naam (2).jpg"), "ABC")
        #expect(try resolve(source, desired) == .identical(second.path))
    }

    @Test func twoDifferentCandidatesGiveTheThird() throws {
        let dir = try makeTempDir(); defer { try? fm.removeItem(at: dir) }
        let source = write(dir.appendingPathComponent("bron.jpg"), "ABC")
        let desired = write(dir.appendingPathComponent("naam.jpg"), "ABCDEF")
        write(dir.appendingPathComponent("naam (2).jpg"), "XYZ")
        #expect(try resolve(source, desired) == .free(dir.appendingPathComponent("naam (3).jpg").path))
    }

    @Test func sameSizeDifferentContentGivesNextName() throws {
        let dir = try makeTempDir(); defer { try? fm.removeItem(at: dir) }
        let source = write(dir.appendingPathComponent("bron.jpg"), "ABC")
        let desired = write(dir.appendingPathComponent("naam.jpg"), "XYZ")
        #expect(try resolve(source, desired) == .free(dir.appendingPathComponent("naam (2).jpg").path))
    }

    @Test func nameWithoutExtensionGetsSuffix() throws {
        let dir = try makeTempDir(); defer { try? fm.removeItem(at: dir) }
        let source = write(dir.appendingPathComponent("bron"), "ABC")
        let desired = write(dir.appendingPathComponent("naam"), "ABCDEF")
        #expect(try resolve(source, desired) == .free(dir.appendingPathComponent("naam (2)").path))
    }
}
