import XCTest
@testable import Apus

final class CircularBufferTests: XCTestCase {

    func testAppendAndRetrieve() {
        let buffer = CircularBuffer<Int>(capacity: 5)
        buffer.append(1)
        buffer.append(2)
        buffer.append(3)

        XCTAssertEqual(buffer.allElements(), [1, 2, 3])
        XCTAssertEqual(buffer.totalCount, 3)
    }

    func testOverflow() {
        let buffer = CircularBuffer<Int>(capacity: 3)
        buffer.append(1)
        buffer.append(2)
        buffer.append(3)
        buffer.append(4)
        buffer.append(5)

        // Only last 3 should remain
        XCTAssertEqual(buffer.allElements(), [3, 4, 5])
        XCTAssertEqual(buffer.totalCount, 3)
    }

    func testTail() {
        let buffer = CircularBuffer<Int>(capacity: 10)
        for i in 1...10 {
            buffer.append(i)
        }

        XCTAssertEqual(buffer.tail(3), [8, 9, 10])
        XCTAssertEqual(buffer.tail(1), [10])
        XCTAssertEqual(buffer.tail(10), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        XCTAssertEqual(buffer.tail(20), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]) // More than available
    }

    func testTailAfterOverflow() {
        let buffer = CircularBuffer<Int>(capacity: 3)
        for i in 1...7 {
            buffer.append(i)
        }

        XCTAssertEqual(buffer.tail(2), [6, 7])
        XCTAssertEqual(buffer.tail(3), [5, 6, 7])
    }

    func testEmpty() {
        let buffer = CircularBuffer<String>(capacity: 5)
        XCTAssertEqual(buffer.allElements(), [])
        XCTAssertEqual(buffer.tail(3), [])
        XCTAssertEqual(buffer.totalCount, 0)
    }

    func testClear() {
        let buffer = CircularBuffer<Int>(capacity: 5)
        buffer.append(1)
        buffer.append(2)
        buffer.append(3)

        buffer.clear()

        XCTAssertEqual(buffer.allElements(), [])
        XCTAssertEqual(buffer.totalCount, 0)
    }

    func testCapacityOne() {
        let buffer = CircularBuffer<String>(capacity: 1)
        buffer.append("a")
        XCTAssertEqual(buffer.allElements(), ["a"])

        buffer.append("b")
        XCTAssertEqual(buffer.allElements(), ["b"])
        XCTAssertEqual(buffer.totalCount, 1)
    }

    func testThreadSafety() {
        let buffer = CircularBuffer<Int>(capacity: 1000)
        let group = DispatchGroup()

        // Write from multiple threads simultaneously
        for i in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                for j in 0..<10 {
                    buffer.append(i * 10 + j)
                }
                group.leave()
            }
        }

        group.wait()
        XCTAssertEqual(buffer.totalCount, 1000)
    }
}
