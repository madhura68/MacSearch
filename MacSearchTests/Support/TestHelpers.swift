import Foundation
import Synchronization
@testable import MacSearch

/// The canonical path (`/private/var/...` rather than `/var/...`), as the app resolves folders.
func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// Hands out the given UUIDs in order, then random ones.
final class SequenceUUIDs: UUIDSource {
    private let remaining: Mutex<[UUID]>

    init(_ uuids: [UUID]) {
        remaining = Mutex(uuids)
    }

    func next() -> UUID {
        remaining.withLock { $0.isEmpty ? UUID() : $0.removeFirst() }
    }
}

/// A value that hooks can set from any thread and the test reads afterwards.
final class Locked<Value: Sendable>: Sendable {
    private let value: Mutex<Value>

    init(_ initial: Value) {
        value = Mutex(initial)
    }

    func set(_ newValue: Value) {
        value.withLock { $0 = newValue }
    }

    func get() -> Value {
        value.withLock { $0 }
    }
}
