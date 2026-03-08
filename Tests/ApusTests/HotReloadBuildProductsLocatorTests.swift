import XCTest
@testable import Apus

final class HotReloadBuildProductsLocatorTests: XCTestCase {

    func testResolveFindsDotBuildDerivedDataInProjectRoot() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let products = root
            .appendingPathComponent(".build/DerivedData/Build/Products/Debug-iphonesimulator")
        let moduleDir = products.appendingPathComponent("Apus.swiftmodule")

        try FileManager.default.createDirectory(at: moduleDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: moduleDir.appendingPathComponent("arm64-apple-ios-simulator.swiftmodule").path,
            contents: Data("module".utf8)
        )

        let resolution = HotReloadBuildProductsLocator.resolve(
            appName: "ApusFresh",
            projectRoot: root.path,
            packageRoot: nil
        )

        XCTAssertEqual(resolution.foundPath, products.path)
        XCTAssertTrue(resolution.hasApusSwiftmodule)
        XCTAssertTrue(resolution.searchedPaths.contains(products.path))
    }

    func testResolveFindsDotBuildDerivedDataInPackageRoot() throws {
        let packageRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: packageRoot) }

        let products = packageRoot
            .appendingPathComponent(".build/DerivedData/Build/Products/Debug-iphonesimulator")
        let moduleDir = products.appendingPathComponent("Apus.swiftmodule")

        try FileManager.default.createDirectory(at: moduleDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: moduleDir.appendingPathComponent("arm64-apple-ios-simulator.swiftmodule").path,
            contents: Data("module".utf8)
        )

        let resolution = HotReloadBuildProductsLocator.resolve(
            appName: "ApusFresh",
            projectRoot: nil,
            packageRoot: packageRoot.path
        )

        XCTAssertEqual(resolution.foundPath, products.path)
        XCTAssertTrue(resolution.hasApusSwiftmodule)
        XCTAssertTrue(resolution.searchedPaths.contains(products.path))
    }

    private func makeTempDirectory() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("hot-reload-locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
