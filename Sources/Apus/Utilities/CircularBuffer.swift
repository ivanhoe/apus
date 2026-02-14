import Foundation

/// Thread-safe circular buffer for storing a fixed number of recent entries.
final class CircularBuffer<T>: @unchecked Sendable {
    private var buffer: [T?]
    private var writeIndex = 0
    private var _count = 0
    private let capacity: Int
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = Array(repeating: nil, count: capacity)
    }

    /// Append an element, overwriting the oldest if at capacity.
    func append(_ element: T) {
        lock.lock()
        defer { lock.unlock() }
        buffer[writeIndex] = element
        writeIndex = (writeIndex + 1) % capacity
        _count = min(_count + 1, capacity)
    }

    /// Returns all elements in insertion order (oldest first).
    func allElements() -> [T] {
        lock.lock()
        defer { lock.unlock() }

        if _count < capacity {
            return buffer[0..<_count].compactMap { $0 }
        } else {
            let end = buffer[writeIndex..<capacity].compactMap { $0 }
            let start = buffer[0..<writeIndex].compactMap { $0 }
            return end + start
        }
    }

    /// Returns the last N elements in insertion order.
    func tail(_ n: Int) -> [T] {
        let all = allElements()
        return Array(all.suffix(n))
    }

    /// Total number of elements currently stored.
    var totalCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }

    /// Remove all elements.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        buffer = Array(repeating: nil, count: capacity)
        writeIndex = 0
        _count = 0
    }
}
