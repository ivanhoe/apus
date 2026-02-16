import XCTest
@testable import Apus

#if canImport(SwiftData)
import SwiftData

final class SwiftDataInspectorTests: XCTestCase {

    @available(iOS 17, macOS 14, *)
    func testInvalidContainerReturnsErrorInsteadOfCrashing() async throws {
        let tool = SwiftDataInspector(container: "not-a-container")
        let result = try await tool.execute(arguments: [:])

        XCTAssertTrue(result.isError)
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("Invalid modelContainer"))
    }
}
#endif
