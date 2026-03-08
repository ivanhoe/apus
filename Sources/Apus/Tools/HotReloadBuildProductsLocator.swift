#if DEBUG
import Foundation

struct HotReloadBuildProductsResolution {
    let foundPath: String?
    let searchedPaths: [String]
    let hasApusSwiftmodule: Bool
}

enum HotReloadBuildProductsLocator {
    private static let buildConfigurations = [
        "Debug-iphonesimulator",
        "Debug-iphoneos",
        "Release-iphonesimulator"
    ]

    static func resolve(
        appName: String,
        projectRoot: String?,
        packageRoot: String? = packageRootFromFilePath(#filePath),
        fileManager: FileManager = .default
    ) -> HotReloadBuildProductsResolution {
        var candidates: [String] = []

        func appendUnique(_ path: String) {
            if !candidates.contains(path) {
                candidates.append(path)
            }
        }

        func addProductsBase(_ base: String) {
            for config in buildConfigurations {
                appendUnique(base + "/" + config)
            }
        }

        if let projectRoot {
            addProductsBase(projectRoot + "/build/Build/Products")
            addProductsBase(projectRoot + "/DerivedData/Build/Products")
            addProductsBase(projectRoot + "/.build/Build/Products")
            addProductsBase(projectRoot + "/.build/DerivedData/Build/Products")
        }

        if let packageRoot {
            addProductsBase(packageRoot + "/ExampleApp/build/Build/Products")
            addProductsBase(packageRoot + "/build/Build/Products")
            addProductsBase(packageRoot + "/DerivedData/Build/Products")
            addProductsBase(packageRoot + "/.build/Build/Products")
            addProductsBase(packageRoot + "/.build/DerivedData/Build/Products")
            addProductsBase(packageRoot + "/ExampleApp/.build/Build/Products")
            addProductsBase(packageRoot + "/ExampleApp/.build/DerivedData/Build/Products")
        }

        let derivedDataRoot = NSHomeDirectory() + "/Library/Developer/Xcode/DerivedData"
        if let entries = try? fileManager.contentsOfDirectory(atPath: derivedDataRoot) {
            let normalizedAppName = appName.lowercased()
            for entry in entries {
                let normalizedEntry = entry.lowercased()
                guard normalizedEntry.hasPrefix(normalizedAppName) || normalizedEntry.contains(normalizedAppName + "-") else {
                    continue
                }
                addProductsBase(derivedDataRoot + "/" + entry + "/Build/Products")
            }
        }

        var foundPath: String?

        // Prefer locations with Apus.swiftmodule for source_code compilation mode.
        for candidate in candidates {
            if fileManager.fileExists(atPath: candidate + "/Apus.swiftmodule") {
                foundPath = candidate
                break
            }
        }

        if foundPath == nil {
            for candidate in candidates {
                if fileManager.fileExists(atPath: candidate + "/\(appName).app") {
                    foundPath = candidate
                    break
                }
            }
        }

        if foundPath == nil {
            foundPath = candidates.first(where: { fileManager.fileExists(atPath: $0) })
        }

        let hasApusSwiftmodule: Bool
        if let foundPath {
            hasApusSwiftmodule = fileManager.fileExists(atPath: foundPath + "/Apus.swiftmodule")
        } else {
            hasApusSwiftmodule = false
        }

        return HotReloadBuildProductsResolution(
            foundPath: foundPath,
            searchedPaths: candidates,
            hasApusSwiftmodule: hasApusSwiftmodule
        )
    }

    static func packageRootFromFilePath(_ filePath: String) -> String {
        var path = (filePath as NSString).deletingLastPathComponent // Tools
        path = (path as NSString).deletingLastPathComponent         // Apus
        path = (path as NSString).deletingLastPathComponent         // Sources
        return (path as NSString).deletingLastPathComponent         // package root
    }
}
#endif
