#if canImport(UIKit) && !os(watchOS)
import XCTest
@testable import Apus

final class UIInteractionToolTests: XCTestCase {

    var tool: UIInteractionTool!

    override func setUp() {
        super.setUp()
        tool = UIInteractionTool()
    }

    // MARK: - Metadata

    func testToolName() {
        XCTAssertEqual(tool.toolName, "ui_interact")
    }

    func testToolDescription_isNotEmpty() {
        XCTAssertFalse(tool.toolDescription.isEmpty)
    }

    func testToolDescription_mentionsActions() {
        XCTAssertTrue(tool.toolDescription.contains("tap"))
        XCTAssertTrue(tool.toolDescription.contains("swipe"))
        XCTAssertTrue(tool.toolDescription.contains("type_text"))
    }

    // MARK: - Schema Validation

    func testSchema_isObject() {
        XCTAssertEqual(tool.inputSchema["type"] as? String, "object")
    }

    func testSchema_requiresAction() {
        let required = tool.inputSchema["required"] as? [String]
        XCTAssertNotNil(required)
        XCTAssertEqual(required, ["action"])
    }

    func testSchema_hasAllProperties() {
        let properties = tool.inputSchema["properties"] as? [String: Any]
        XCTAssertNotNil(properties)
        let expectedKeys: Set<String> = ["action", "identifier", "label", "path", "coordinate", "direction", "text", "duration"]
        XCTAssertEqual(Set(properties?.keys.map { $0 } ?? []), expectedKeys)
    }

    func testSchema_actionEnumValues() {
        let properties = tool.inputSchema["properties"] as? [String: Any]
        let actionProp = properties?["action"] as? [String: Any]
        let enumValues = actionProp?["enum"] as? [String]
        XCTAssertNotNil(enumValues)
        XCTAssertEqual(Set(enumValues ?? []), Set(["tap", "double_tap", "long_press", "swipe", "type_text"]))
    }

    func testSchema_directionEnumValues() {
        let properties = tool.inputSchema["properties"] as? [String: Any]
        let dirProp = properties?["direction"] as? [String: Any]
        let enumValues = dirProp?["enum"] as? [String]
        XCTAssertNotNil(enumValues)
        XCTAssertEqual(Set(enumValues ?? []), Set(["up", "down", "left", "right"]))
    }

    func testSchema_coordinateIsObject() {
        let properties = tool.inputSchema["properties"] as? [String: Any]
        let coordProp = properties?["coordinate"] as? [String: Any]
        XCTAssertEqual(coordProp?["type"] as? String, "object")
        let coordProps = coordProp?["properties"] as? [String: Any]
        XCTAssertNotNil(coordProps?["x"])
        XCTAssertNotNil(coordProps?["y"])
    }

    func testSchema_durationIsNumber() {
        let properties = tool.inputSchema["properties"] as? [String: Any]
        let durationProp = properties?["duration"] as? [String: Any]
        XCTAssertEqual(durationProp?["type"] as? String, "number")
    }

    // MARK: - Missing/Invalid Action

    func testRejects_missingAction() async throws {
        let result = try await tool.execute(arguments: [:])
        XCTAssertTrue(result.isError)
        let text = extractText(result)
        XCTAssertTrue(text.contains("action"), "Error should mention 'action'")
    }

    func testRejects_invalidAction() async throws {
        let result = try await tool.execute(arguments: ["action": "shake"])
        XCTAssertTrue(result.isError)
        let text = extractText(result)
        XCTAssertTrue(text.contains("shake"), "Error should include the invalid action name")
    }

    func testRejects_numericAction() async throws {
        let result = try await tool.execute(arguments: ["action": 42])
        XCTAssertTrue(result.isError)
    }

    // MARK: - Swipe Validation

    func testSwipe_rejectsMissingDirection() async throws {
        let result = try await tool.execute(arguments: ["action": "swipe", "identifier": "some_view"])
        XCTAssertTrue(result.isError)
        let text = extractText(result)
        XCTAssertTrue(text.contains("direction"), "Error should mention 'direction'")
    }

    func testSwipe_rejectsInvalidDirection() async throws {
        let result = try await tool.execute(arguments: ["action": "swipe", "direction": "diagonal"])
        XCTAssertTrue(result.isError)
        let text = extractText(result)
        XCTAssertTrue(text.contains("direction"), "Error should mention 'direction'")
    }

    // MARK: - Type Text Validation

    func testTypeText_rejectsMissingText() async throws {
        let result = try await tool.execute(arguments: ["action": "type_text", "identifier": "text_field"])
        XCTAssertTrue(result.isError)
        let text = extractText(result)
        XCTAssertTrue(text.contains("text"), "Error should mention 'text'")
    }

    func testTypeText_rejectsEmptyText() async throws {
        let result = try await tool.execute(arguments: ["action": "type_text", "text": ""])
        XCTAssertTrue(result.isError)
        let text = extractText(result)
        XCTAssertTrue(text.contains("text"), "Error should mention 'text'")
    }

    func testTypeText_rejectsNonStringText() async throws {
        let result = try await tool.execute(arguments: ["action": "type_text", "text": 123])
        XCTAssertTrue(result.isError)
    }

    // MARK: - View Resolution Errors (no UIKit window in test environment)

    func testTap_withIdentifier_noWindow() async throws {
        let result = try await tool.execute(arguments: ["action": "tap", "identifier": "some_button"])
        XCTAssertTrue(result.isError)
        let text = extractText(result)
        XCTAssertTrue(text.contains("not found") || text.contains("No key window"),
                       "Should fail gracefully when no window is available")
    }

    func testTap_withPath_noWindow() async throws {
        let result = try await tool.execute(arguments: ["action": "tap", "path": "0.0.1"])
        XCTAssertTrue(result.isError)
    }

    func testTap_withCoordinate_noWindow() async throws {
        let result = try await tool.execute(arguments: [
            "action": "tap",
            "coordinate": ["x": 100.0, "y": 200.0] as [String: Any]
        ])
        XCTAssertTrue(result.isError)
    }

    func testTap_withNoTarget_noWindow() async throws {
        // Tap with no target — should error about no target specified
        let result = try await tool.execute(arguments: ["action": "tap"])
        XCTAssertTrue(result.isError)
        let text = extractText(result)
        XCTAssertTrue(text.contains("No target") || text.contains("not found") || text.contains("No key window"),
                       "Should indicate no target was found")
    }

    // MARK: - Label targeting (no window)

    func testTap_withLabel_noWindow() async throws {
        let result = try await tool.execute(arguments: ["action": "tap", "label": "Setup"])
        XCTAssertTrue(result.isError)
        let text = extractText(result)
        XCTAssertTrue(text.contains("not found") || text.contains("No key window"))
    }

    func testSchema_hasLabelProperty() {
        let properties = tool.inputSchema["properties"] as? [String: Any]
        let labelProp = properties?["label"] as? [String: Any]
        XCTAssertNotNil(labelProp)
        XCTAssertEqual(labelProp?["type"] as? String, "string")
    }

    // MARK: - findView(byLabel:) unit tests

    func testFindViewByLabel_prefersInteractiveView() async throws {
        await MainActor.run {
            let root = UIView()
            let staticLabel = UIView()
            staticLabel.accessibilityLabel = "Setup"
            let button = UIButton()
            button.accessibilityLabel = "Setup"
            root.addSubview(staticLabel)
            root.addSubview(button)

            let found = UIInteractionTool.findView(byLabel: "Setup", in: root)
            XCTAssertEqual(found, button, "Should prefer UIControl over static view")
        }
    }

    func testFindViewByLabel_returnsStaticViewAsFallback() async throws {
        await MainActor.run {
            let root = UIView()
            let label = UIView()
            label.accessibilityLabel = "Header"
            root.addSubview(label)

            let found = UIInteractionTool.findView(byLabel: "Header", in: root)
            XCTAssertEqual(found, label)
        }
    }

    func testFindViewByLabel_returnsNilWhenNotFound() async throws {
        await MainActor.run {
            let root = UIView()
            root.addSubview(UIView())

            let found = UIInteractionTool.findView(byLabel: "Nonexistent", in: root)
            XCTAssertNil(found)
        }
    }

    // MARK: - findView(byIdentifier:) unit test

    func testFindViewByIdentifier_findsNestedView() async throws {
        await MainActor.run {
            let root = UIView()
            let child = UIView()
            let grandchild = UIView()
            grandchild.accessibilityIdentifier = "target"
            child.addSubview(grandchild)
            root.addSubview(child)

            let found = UIInteractionTool.findView(byIdentifier: "target", in: root)
            XCTAssertNotNil(found)
            XCTAssertEqual(found, grandchild)
        }
    }

    func testFindViewByIdentifier_returnsNilWhenNotFound() async throws {
        await MainActor.run {
            let root = UIView()
            root.addSubview(UIView())

            let found = UIInteractionTool.findView(byIdentifier: "nonexistent", in: root)
            XCTAssertNil(found)
        }
    }

    func testFindViewByIdentifier_findsRootItself() async throws {
        await MainActor.run {
            let root = UIView()
            root.accessibilityIdentifier = "root_view"

            let found = UIInteractionTool.findView(byIdentifier: "root_view", in: root)
            XCTAssertEqual(found, root)
        }
    }

    // MARK: - Activation helpers

    func testActivateView_returnsFailureWhenNoHandler() async throws {
        await MainActor.run {
            let view = UIView()
            let result = tool.activateView(view)
            XCTAssertFalse(result.succeeded)
            XCTAssertEqual(result.method, "no handler found")
        }
    }

    func testActivateView_returnsSuccessWhenControlIsTappable() async throws {
        await MainActor.run {
            let button = UIButton(type: .system)
            let result = tool.activateView(button)
            XCTAssertTrue(result.succeeded)
            XCTAssertNotEqual(result.method, "no handler found")
        }
    }

    // MARK: - Scrollable ancestry helper

    func testFirstScrollableView_returnsSelfWhenTargetIsScrollView() async throws {
        await MainActor.run {
            let scrollView = UIScrollView()
            let found = tool.firstScrollableView(startingAt: scrollView)
            XCTAssertEqual(found, scrollView)
        }
    }

    func testFirstScrollableView_returnsNearestAncestor() async throws {
        await MainActor.run {
            let container = UIView()
            let scrollView = UIScrollView()
            let nested = UIView()

            scrollView.addSubview(nested)
            container.addSubview(scrollView)

            let found = tool.firstScrollableView(startingAt: nested)
            XCTAssertEqual(found, scrollView)
        }
    }

    func testFirstScrollableView_returnsNilWhenNoScrollViewExists() async throws {
        await MainActor.run {
            let root = UIView()
            let child = UIView()
            root.addSubview(child)

            let found = tool.firstScrollableView(startingAt: child)
            XCTAssertNil(found)
        }
    }

    // MARK: - Helpers

    private func extractText(_ result: MCPToolResult) -> String {
        result.content.compactMap { content in
            if case .text(let text) = content { return text }
            return nil
        }.joined()
    }
}
#endif
