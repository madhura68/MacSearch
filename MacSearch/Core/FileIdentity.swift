import Foundation

/// File identity (`fileResourceIdentifierKey`), used instead of path strings to decide
/// whether two folders are the same or one lies inside the other (spec F0a).
struct FileIdentity: Hashable, @unchecked Sendable {
    // Immutable after init; the wrapped identifier is never mutated, which is why @unchecked Sendable is safe.
    private let identifier: any NSObjectProtocol

    /// Resolves symlinks first, then reads the identifier. Nil when the item does not exist.
    init?(url: URL) {
        let resolved = url.resolvingSymlinksInPath()
        guard let value = try? resolved.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else {
            return nil
        }
        identifier = value
    }

    /// From a resource value the enumerator already fetched, without extra I/O.
    init(resourceIdentifier: any NSObjectProtocol) {
        identifier = resourceIdentifier
    }

    static func == (lhs: FileIdentity, rhs: FileIdentity) -> Bool {
        lhs.identifier.isEqual(rhs.identifier)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(identifier.hash)
    }
}
