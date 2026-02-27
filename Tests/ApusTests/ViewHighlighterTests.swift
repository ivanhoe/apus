#if canImport(UIKit) && !os(watchOS)
import XCTest
import UIKit
@testable import Apus

@MainActor
final class ViewHighlighterTests: XCTestCase {

    func testFindView_resolvesValidPath() {
        let window = UIWindow(frame: .init(x: 0, y: 0, width: 100, height: 100))
        let child = UIView()
        let grandchild = UIView()
        child.addSubview(grandchild)
        window.addSubview(child)

        let found = ViewHighlighter.findView(at: "0.0", in: window)
        XCTAssertEqual(found, grandchild)
    }

    func testFindView_rejectsNegativeIndex() {
        let window = UIWindow(frame: .init(x: 0, y: 0, width: 100, height: 100))
        window.addSubview(UIView())

        let found = ViewHighlighter.findView(at: "-1", in: window)
        XCTAssertNil(found)
    }

    func testFindView_rejectsNonNumericSegment() {
        let window = UIWindow(frame: .init(x: 0, y: 0, width: 100, height: 100))
        window.addSubview(UIView())

        let found = ViewHighlighter.findView(at: "0.foo", in: window)
        XCTAssertNil(found)
    }

    func testFindView_rejectsEmptySegment() {
        let window = UIWindow(frame: .init(x: 0, y: 0, width: 100, height: 100))
        window.addSubview(UIView())

        let found = ViewHighlighter.findView(at: "0..1", in: window)
        XCTAssertNil(found)
    }
}
#endif
