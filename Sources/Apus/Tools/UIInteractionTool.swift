#if canImport(UIKit) && !os(watchOS)
import UIKit
import Foundation

/// MCP tool that performs programmatic UI interactions (tap, swipe, type text, etc.).
/// Enables AI agents to navigate and interact with a running iOS app without manual input.
final class UIInteractionTool: MCPTool {
    var toolName: String { "ui_interact" }
    var toolDescription: String {
        """
        Interact with UI elements programmatically: tap, double_tap, long_press, swipe, type_text. \
        Target views by accessibilityIdentifier, accessibilityLabel, view path, or screen coordinate. \
        Use 'label' for UIKit controls (tab bars, nav buttons) and 'identifier' for custom views.
        """
    }
    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "enum": ["tap", "double_tap", "long_press", "swipe", "type_text"],
                    "description": "The interaction to perform"
                ] as [String: Any],
                "identifier": [
                    "type": "string",
                    "description": "accessibilityIdentifier of the target view (most stable for custom views)"
                ] as [String: Any],
                "label": [
                    "type": "string",
                    "description": "accessibilityLabel of the target view (best for UIKit controls: tab bars, nav buttons, etc.)"
                ] as [String: Any],
                "path": [
                    "type": "string",
                    "description": "View path from get_view_hierarchy (e.g. '0.0.1.3')"
                ] as [String: Any],
                "coordinate": [
                    "type": "object",
                    "properties": [
                        "x": ["type": "number"] as [String: Any],
                        "y": ["type": "number"] as [String: Any]
                    ] as [String: Any],
                    "description": "Screen coordinate to interact with {x, y} (fallback)"
                ] as [String: Any],
                "direction": [
                    "type": "string",
                    "enum": ["up", "down", "left", "right"],
                    "description": "Swipe direction (required for 'swipe' action)"
                ] as [String: Any],
                "text": [
                    "type": "string",
                    "description": "Text to type (required for 'type_text' action)"
                ] as [String: Any],
                "duration": [
                    "type": "number",
                    "description": "Press duration in seconds (only for 'long_press', default: 0.5)"
                ] as [String: Any]
            ] as [String: Any],
            "required": ["action"]
        ]
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        guard let actionStr = arguments["action"] as? String else {
            return .error("Missing required parameter 'action'. Must be one of: tap, double_tap, long_press, swipe, type_text.")
        }

        guard let action = Action(rawValue: actionStr) else {
            return .error("Invalid action '\(actionStr)'. Must be one of: tap, double_tap, long_press, swipe, type_text.")
        }

        // Validate action-specific params before touching UIKit
        if action == .swipe {
            guard let dir = arguments["direction"] as? String, Direction(rawValue: dir) != nil else {
                return .error("'swipe' action requires 'direction' parameter (up, down, left, right).")
            }
        }

        if action == .typeText {
            guard let text = arguments["text"] as? String, !text.isEmpty else {
                return .error("'type_text' action requires non-empty 'text' parameter.")
            }
        }

        switch action {
        case .tap, .doubleTap, .longPress:
            return await performTap(action: action, arguments: arguments)
        case .swipe:
            return await MainActor.run {
                performSwipe(arguments: arguments)
            }
        case .typeText:
            return await MainActor.run {
                performTypeText(arguments: arguments)
            }
        }
    }

    // MARK: - Actions

    enum Action: String {
        case tap = "tap"
        case doubleTap = "double_tap"
        case longPress = "long_press"
        case swipe = "swipe"
        case typeText = "type_text"
    }

    enum Direction: String {
        case up, down, left, right
    }

    struct ActivationResult {
        let succeeded: Bool
        let method: String
    }

    // MARK: - Tap / Double Tap / Long Press

    @MainActor
    private func performTap(action: Action, arguments: [String: Any]) async -> MCPToolResult {
        guard let (view, desc) = resolveTargetView(arguments: arguments) else {
            return .error(resolveErrorMessage(arguments: arguments))
        }

        let className = String(describing: type(of: view))

        switch action {
        case .tap:
            let activation = activateView(view)
            guard activation.succeeded else {
                return .error("Failed to tap \(className): no activation handler found (target: \(desc)).")
            }
            return .text("Tapped \(className) via \(activation.method) (target: \(desc))")

        case .doubleTap:
            let first = activateView(view)
            // Small delay between taps is simulated by sequential calls
            let second = activateView(view)
            guard first.succeeded && second.succeeded else {
                return .error("Failed to double-tap \(className): activation attempts were \(first.method), then \(second.method) (target: \(desc)).")
            }
            return .text("Double-tapped \(className) via \(first.method), then \(second.method) (target: \(desc))")

        case .longPress:
            let requestedDuration = arguments["duration"] as? Double ?? 0.5
            let duration = max(0, requestedDuration.isFinite ? requestedDuration : 0.5)
            if let control = view as? UIControl {
                control.sendActions(for: .touchDown)
                if duration > 0 {
                    let durationInNanoseconds = UInt64(min(duration, 300) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: durationInNanoseconds)
                }
                control.sendActions(for: .touchUpInside)
                return .text("Long-pressed \(className) for \(duration)s via UIControl touchDown/touchUpInside (target: \(desc))")
            }
            // Fallback: just do a regular tap — some controls respond the same
            let activation = activateView(view)
            guard activation.succeeded else {
                return .error("Failed to long-press \(className): no safe long-press activation handler found (target: \(desc)).")
            }
            return .text("Long-pressed \(className) via \(activation.method) fallback (target: \(desc))")

        default:
            return .error("Unexpected action in performTap")
        }
    }

    // MARK: - Swipe

    @MainActor
    private func performSwipe(arguments: [String: Any]) -> MCPToolResult {
        guard let dirStr = arguments["direction"] as? String,
              let direction = Direction(rawValue: dirStr) else {
            return .error("'swipe' requires 'direction' (up, down, left, right).")
        }

        // If a target view is specified, swipe on it; otherwise swipe on the key window
        let targetView: UIView
        let desc: String

        if let (view, d) = resolveTargetView(arguments: arguments) {
            targetView = view
            desc = d
        } else if hasAnyTarget(arguments: arguments) {
            return .error(resolveErrorMessage(arguments: arguments))
        } else {
            guard let window = ViewHighlighter.getKeyWindow() else {
                return .error("No key window found")
            }
            targetView = window
            desc = "key window"
        }

        // Try accessibilityScroll first (works well with UIScrollView and SwiftUI)
        let scrollDirection = accessibilityScrollDirection(for: direction)
        if targetView.accessibilityScroll(scrollDirection) {
            return .text("Swiped \(direction.rawValue) on \(viewName(targetView)) via accessibilityScroll (target: \(desc))")
        }

        if let scrollView = firstScrollableView(startingAt: targetView), scrollView === targetView {
            performManualScroll(scrollView: scrollView, direction: direction)
            return .text("Swiped \(direction.rawValue) on \(viewName(scrollView)) via contentOffset (target: \(desc))")
        }

        // Walk up the hierarchy to find a scrollable parent
        var current: UIView? = targetView.superview
        while let parent = current {
            if parent.accessibilityScroll(scrollDirection) {
                let parentName = viewName(parent)
                return .text("Swiped \(direction.rawValue) on \(parentName) (scrollable parent of \(desc))")
            }
            if let scrollView = parent as? UIScrollView {
                performManualScroll(scrollView: scrollView, direction: direction)
                return .text("Swiped \(direction.rawValue) on \(viewName(scrollView)) via contentOffset (parent of \(desc))")
            }
            current = parent.superview
        }

        return .error("No scrollable view found for swipe. Target '\(desc)' and its ancestors don't support scrolling.")
    }

    // MARK: - Type Text

    @MainActor
    private func performTypeText(arguments: [String: Any]) -> MCPToolResult {
        guard let text = arguments["text"] as? String else {
            return .error("'type_text' requires 'text' parameter.")
        }

        // If a target is specified, try to make it first responder
        if let (view, desc) = resolveTargetView(arguments: arguments) {
            if view.canBecomeFirstResponder {
                view.becomeFirstResponder()
            }

            if let textInput = view as? UIKeyInput {
                for char in text {
                    textInput.insertText(String(char))
                }
                return .text("Typed \(text.count) character(s) into \(viewName(view)) (target: \(desc))")
            }

            return .error("View \(viewName(view)) at '\(desc)' does not accept text input (not UIKeyInput).")
        }

        // No target specified — type into current first responder
        if let firstResponder = findFirstResponder(in: ViewHighlighter.getKeyWindow()),
           let textInput = firstResponder as? UIKeyInput {
            for char in text {
                textInput.insertText(String(char))
            }
            return .text("Typed \(text.count) character(s) into current first responder (\(viewName(firstResponder)))")
        }

        return .error("No text input is focused and no target view specified. Use 'identifier' or 'path' to target a text field, or tap one first.")
    }

    // MARK: - View Resolution

    /// Resolve a target view from identifier, path, or coordinate arguments.
    /// Returns the view and a human-readable description of how it was found.
    @MainActor
    private func resolveTargetView(arguments: [String: Any]) -> (UIView, String)? {
        guard let window = ViewHighlighter.getKeyWindow() else { return nil }

        // Priority 1: accessibilityIdentifier
        if let identifier = arguments["identifier"] as? String, !identifier.isEmpty {
            if let view = Self.findView(byIdentifier: identifier, in: window) {
                return (view, "identifier='\(identifier)'")
            }
            return nil
        }

        // Priority 2: accessibilityLabel
        if let label = arguments["label"] as? String, !label.isEmpty {
            if let view = Self.findView(byLabel: label, in: window) {
                return (view, "label='\(label)'")
            }
            return nil
        }

        // Priority 3: view path
        if let path = arguments["path"] as? String, !path.isEmpty {
            if let view = ViewHighlighter.findView(at: path, in: window) {
                return (view, "path='\(path)'")
            }
            return nil
        }

        // Priority 3: coordinate
        if let coord = arguments["coordinate"] as? [String: Any],
           let x = coord["x"] as? Double,
           let y = coord["y"] as? Double {
            let point = CGPoint(x: x, y: y)
            if let view = window.hitTest(point, with: nil) {
                return (view, "coordinate=(\(Int(x)),\(Int(y)))")
            }
            return nil
        }

        return nil
    }

    /// Check if any target arguments were provided (to distinguish "no target" from "target not found").
    private func hasAnyTarget(arguments: [String: Any]) -> Bool {
        if let id = arguments["identifier"] as? String, !id.isEmpty { return true }
        if let label = arguments["label"] as? String, !label.isEmpty { return true }
        if let path = arguments["path"] as? String, !path.isEmpty { return true }
        if arguments["coordinate"] is [String: Any] { return true }
        return false
    }

    /// Build an error message for failed view resolution.
    private func resolveErrorMessage(arguments: [String: Any]) -> String {
        if let identifier = arguments["identifier"] as? String {
            return "View with accessibilityIdentifier '\(identifier)' not found. Use get_view_hierarchy to discover available views."
        }
        if let label = arguments["label"] as? String {
            return "View with accessibilityLabel '\(label)' not found. Use get_view_hierarchy (depth: 20+) to see available labels."
        }
        if let path = arguments["path"] as? String {
            return "View not found at path '\(path)'. The hierarchy may have changed — refresh with get_view_hierarchy."
        }
        if let coord = arguments["coordinate"] as? [String: Any] {
            let x = coord["x"] as? Double ?? 0
            let y = coord["y"] as? Double ?? 0
            return "No view found at coordinate (\(Int(x)), \(Int(y))). Check that the coordinate is within the screen bounds."
        }
        return "No target view specified. Provide 'identifier', 'label', 'path', or 'coordinate'."
    }

    // MARK: - View Activation

    /// Activate a view using the best available mechanism. Returns a description of the method used.
    @MainActor
    @discardableResult
    func activateView(_ view: UIView) -> ActivationResult {
        // Priority 1: accessibilityActivate (works with SwiftUI buttons, tabs, etc.)
        if view.accessibilityActivate() {
            return ActivationResult(succeeded: true, method: "accessibilityActivate")
        }

        // Priority 2: UIControl.sendActions (UIButton, UISwitch, etc.)
        if let control = view as? UIControl {
            control.sendActions(for: .touchUpInside)
            return ActivationResult(succeeded: true, method: "UIControl.sendActions(.touchUpInside)")
        }

        // Priority 3: Walk up to find a tappable parent (SwiftUI wraps things in container views)
        var current: UIView? = view.superview
        while let parent = current {
            if parent.accessibilityActivate() {
                return ActivationResult(succeeded: true, method: "accessibilityActivate (parent \(viewName(parent)))")
            }
            if let control = parent as? UIControl {
                control.sendActions(for: .touchUpInside)
                return ActivationResult(succeeded: true, method: "UIControl.sendActions (parent \(viewName(control)))")
            }
            current = parent.superview
        }

        // Priority 4: Cell selection fallback for SwiftUI List / UICollectionView / UITableView hosts
        if let cellActivation = activateAncestorListCell(from: view) {
            return cellActivation
        }

        return ActivationResult(succeeded: false, method: "no handler found")
    }

    @MainActor
    private func activateAncestorListCell(from view: UIView) -> ActivationResult? {
        if let tableCell = findAncestor(of: view, as: UITableViewCell.self),
           let tableView = findAncestor(of: tableCell, as: UITableView.self),
           let indexPath = tableView.indexPath(for: tableCell) {
            let selectedIndexPath: IndexPath
            if let delegate = tableView.delegate,
               delegate.responds(to: #selector(UITableViewDelegate.tableView(_:willSelectRowAt:))) {
                guard let gatedIndexPath = delegate.tableView?(tableView, willSelectRowAt: indexPath) else {
                    return ActivationResult(
                        succeeded: false,
                        method: "UITableViewDelegate.willSelectRowAt blocked (\(indexPath.section),\(indexPath.row))"
                    )
                }
                selectedIndexPath = gatedIndexPath
            } else {
                selectedIndexPath = indexPath
            }

            tableView.selectRow(at: selectedIndexPath, animated: true, scrollPosition: .none)
            tableView.delegate?.tableView?(tableView, didSelectRowAt: selectedIndexPath)
            return ActivationResult(
                succeeded: true,
                method: "UITableViewDelegate.didSelectRowAt (\(selectedIndexPath.section),\(selectedIndexPath.row))"
            )
        }

        if let collectionCell = findAncestor(of: view, as: UICollectionViewCell.self),
           let collectionView = findAncestor(of: collectionCell, as: UICollectionView.self),
           let indexPath = collectionView.indexPath(for: collectionCell) {
            if let delegate = collectionView.delegate,
               delegate.responds(to: #selector(UICollectionViewDelegate.collectionView(_:shouldSelectItemAt:))),
               delegate.collectionView?(collectionView, shouldSelectItemAt: indexPath) == false {
                return ActivationResult(
                    succeeded: false,
                    method: "UICollectionViewDelegate.shouldSelectItemAt blocked (\(indexPath.section),\(indexPath.item))"
                )
            }

            collectionView.selectItem(at: indexPath, animated: true, scrollPosition: [])
            collectionView.delegate?.collectionView?(collectionView, didSelectItemAt: indexPath)
            return ActivationResult(
                succeeded: true,
                method: "UICollectionViewDelegate.didSelectItemAt (\(indexPath.section),\(indexPath.item))"
            )
        }

        return nil
    }

    // MARK: - Helpers

    @MainActor
    private func findAncestor<T: UIView>(of view: UIView, as type: T.Type) -> T? {
        var current: UIView? = view
        while let node = current {
            if let matched = node as? T {
                return matched
            }
            current = node.superview
        }
        return nil
    }

    /// Returns the first UIScrollView in the target ancestry (including the target view itself).
    @MainActor
    func firstScrollableView(startingAt view: UIView) -> UIScrollView? {
        var current: UIView? = view
        while let candidate = current {
            if let scrollView = candidate as? UIScrollView {
                return scrollView
            }
            current = candidate.superview
        }
        return nil
    }

    /// Recursively find a view by its accessibilityIdentifier.
    @MainActor
    static func findView(byIdentifier identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier {
            return view
        }
        for subview in view.subviews {
            if let found = findView(byIdentifier: identifier, in: subview) {
                return found
            }
        }
        return nil
    }

    /// Recursively find a view by its accessibilityLabel.
    /// Prefers interactive views (UIControl, views with gesture recognizers) over static labels.
    @MainActor
    static func findView(byLabel label: String, in view: UIView) -> UIView? {
        var firstMatch: UIView?

        func search(in current: UIView) -> UIView? {
            if current.accessibilityLabel == label {
                // Prefer interactive views — return immediately if tappable
                if current is UIControl || current.gestureRecognizers?.isEmpty == false {
                    return current
                }
                if firstMatch == nil {
                    firstMatch = current
                }
            }
            for subview in current.subviews {
                if let found = search(in: subview) {
                    return found
                }
            }
            return nil
        }

        return search(in: view) ?? firstMatch
    }

    /// Find the current first responder in the view hierarchy.
    @MainActor
    private func findFirstResponder(in view: UIView?) -> UIView? {
        guard let view = view else { return nil }
        if view.isFirstResponder { return view }
        for subview in view.subviews {
            if let found = findFirstResponder(in: subview) {
                return found
            }
        }
        return nil
    }

    /// Convert our Direction enum to UIAccessibilityScrollDirection.
    private func accessibilityScrollDirection(for direction: Direction) -> UIAccessibilityScrollDirection {
        switch direction {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        }
    }

    /// Manually scroll a UIScrollView by a page-sized offset.
    @MainActor
    private func performManualScroll(scrollView: UIScrollView, direction: Direction) {
        let bounds = scrollView.bounds
        var offset = scrollView.contentOffset
        let pageAmount: CGFloat = 0.8 // scroll 80% of visible area

        switch direction {
        case .up:
            offset.y = max(offset.y - bounds.height * pageAmount, -scrollView.adjustedContentInset.top)
        case .down:
            let maxY = scrollView.contentSize.height - bounds.height + scrollView.adjustedContentInset.bottom
            offset.y = min(offset.y + bounds.height * pageAmount, maxY)
        case .left:
            offset.x = max(offset.x - bounds.width * pageAmount, -scrollView.adjustedContentInset.left)
        case .right:
            let maxX = scrollView.contentSize.width - bounds.width + scrollView.adjustedContentInset.right
            offset.x = min(offset.x + bounds.width * pageAmount, maxX)
        }

        scrollView.setContentOffset(offset, animated: true)
    }

    @MainActor
    private func viewName(_ view: UIView) -> String {
        String(describing: type(of: view))
    }
}
#endif
