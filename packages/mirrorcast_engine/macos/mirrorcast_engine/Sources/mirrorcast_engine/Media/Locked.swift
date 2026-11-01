import Foundation

/// A value protected by a lock. Small and dependency-free, so it works with
/// any value type (including CoreVideo buffers) without Sendable gymnastics.
final class Locked<Value> {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
