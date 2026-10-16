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

/// A one-shot barrier for injected closures and hooks. The closure calls `pass()` (async) or
/// `passBlocking()` (from a synchronous `FileOps` hook); the test awaits `reached()`, inspects the
/// state, then calls `open()`.
final class Gate: Sendable {
    private struct State {
        var reached = false
        var opened = false
        var reachedWaiters: [CheckedContinuation<Void, Never>] = []
        var openWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())
    private let semaphore = DispatchSemaphore(value: 0)

    func pass() async {
        signalReached()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state in
                if state.opened { return true }
                state.openWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func passBlocking() {
        signalReached()
        if state.withLock({ !$0.opened }) { semaphore.wait() }
    }

    func reached() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state in
                if state.reached { return true }
                state.reachedWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state in
            state.opened = true
            defer { state.openWaiters = [] }
            return state.openWaiters
        }
        waiters.forEach { $0.resume() }
        semaphore.signal()
    }

    private func signalReached() {
        let waiters = state.withLock { state in
            state.reached = true
            defer { state.reachedWaiters = [] }
            return state.reachedWaiters
        }
        waiters.forEach { $0.resume() }
    }
}
