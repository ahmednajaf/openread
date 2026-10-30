// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Source builds can override the published runtime by running the build script.
let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let runtime: Target = FileManager.default.fileExists(atPath: folder.appendingPathComponent("Kitten2Runtime.xcframework").path)
    ? .binaryTarget(name: "Kitten2Runtime", path: "Kitten2Runtime.xcframework")
    : .binaryTarget(name: "Kitten2Runtime",
        url: "https://github.com/ahmednajaf/openread/releases/download/kitten2-runtime-2026-10-30-sampling/Kitten2Runtime.xcframework.zip",
        checksum: "ccb0c9d15acb7ea70d39f0046aa7974955858260326663bc20d33070e20e2c7b")

let package = Package(
    name: "OpenReadKitten2",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "OpenReadKitten2", targets: ["OpenReadKitten2"])],
    targets: [
        runtime,
        .target(name: "OpenReadKitten2", dependencies: ["Kitten2Runtime"], path: "swift",
                linkerSettings: [.linkedFramework("Accelerate"), .linkedFramework("Metal"),
                                 .linkedFramework("MetalKit"), .linkedFramework("Foundation"), .linkedLibrary("c++"), .linkedLibrary("sqlite3")])
    ]
)
