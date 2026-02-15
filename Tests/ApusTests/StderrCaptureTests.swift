import XCTest
@testable import Apus

final class StderrCaptureTests: XCTestCase {

    func testCapturesPrintOutput() {
        let expectation = expectation(description: "Capture stderr line")
        var capturedLines: [String] = []

        let capture = StderrCapture { line in
            capturedLines.append(line)
            if capturedLines.count >= 1 {
                expectation.fulfill()
            }
        }

        capture.start()

        // NSLog writes to stderr
        NSLog("StderrCaptureTest: hello from NSLog")

        waitForExpectations(timeout: 3)
        capture.stop()

        XCTAssertTrue(capturedLines.contains(where: { $0.contains("StderrCaptureTest") }))
    }

    func testStopRestoresStderr() {
        let capture = StderrCapture { _ in }

        capture.start()
        capture.stop()

        // After stop, stderr is restored and the app doesn't crash
        NSLog("This should go to original stderr")
    }

    func testDoubleStopDoesNotCrash() {
        let capture = StderrCapture { _ in }
        capture.start()
        capture.stop()
        capture.stop() // Should not crash
    }

    func testDoubleStartIsIdempotent() {
        var count = 0
        let capture = StderrCapture { _ in count += 1 }
        capture.start()
        capture.start() // Second start should be ignored
        capture.stop()
    }

    func testFiltersEmptyLines() {
        let expectation = expectation(description: "Capture line")
        var capturedLines: [String] = []

        let capture = StderrCapture { line in
            capturedLines.append(line)
            if line.contains("StderrFilterTest") {
                expectation.fulfill()
            }
        }

        capture.start()
        NSLog("StderrFilterTest: content")
        waitForExpectations(timeout: 3)
        capture.stop()

        // Empty lines should have been filtered out
        XCTAssertTrue(capturedLines.allSatisfy { !$0.isEmpty })
    }
}
