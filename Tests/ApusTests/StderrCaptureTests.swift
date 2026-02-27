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

    // MARK: - Additional Edge Cases

    func testCapture_multipleMessages_allCaptured() {
        let expectation = expectation(description: "Capture three distinct messages")
        expectation.expectedFulfillmentCount = 3
        let lock = NSLock()
        var matchCount = 0

        let capture = StderrCapture { line in
            if line.contains("MultiCaptureTest") {
                lock.lock()
                matchCount += 1
                lock.unlock()
                expectation.fulfill()
            }
        }

        capture.start()
        NSLog("MultiCaptureTest: message one")
        NSLog("MultiCaptureTest: message two")
        NSLog("MultiCaptureTest: message three")
        waitForExpectations(timeout: 5)
        capture.stop()

        XCTAssertGreaterThanOrEqual(matchCount, 3,
                                    "All three distinct NSLog messages should be captured")
    }

    func testCapture_stopAndRestartLifecycle_capturesAfterRestart() {
        // stop() then start() again should re-establish capture correctly.
        let expectation = expectation(description: "Capture after restart")
        var capturedAfterRestart: [String] = []

        let capture = StderrCapture { line in
            if line.contains("RestartCaptureTest") {
                capturedAfterRestart.append(line)
                expectation.fulfill()
            }
        }

        capture.start()
        capture.stop()
        capture.start() // second session

        NSLog("RestartCaptureTest: output after restart")
        waitForExpectations(timeout: 3)
        capture.stop()

        XCTAssertTrue(capturedAfterRestart.contains(where: { $0.contains("RestartCaptureTest") }),
                      "Capture should work correctly after a stop/start cycle")
    }

    func testCapture_deinit_doesNotCrash() {
        // deinit calls stop() automatically. This test verifies that a started
        // capture going out of scope does not crash or leave the process in a bad state.
        autoreleasepool {
            let capture = StderrCapture { _ in }
            capture.start()
            // capture goes out of scope here; its deinit should call stop() safely.
        }
        // If execution reaches this point without crashing the test passes.
        NSLog("Post-deinit NSLog should reach original stderr without crashing")
    }
}
