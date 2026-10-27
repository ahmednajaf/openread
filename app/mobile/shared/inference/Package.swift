// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenReadInference",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "OpenReadInference", targets: ["OpenReadInference"])],
    dependencies: [.package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2")],
    targets: [.target(name: "OpenReadInference", dependencies: [.product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")], path: ".", sources: ["inference.cpp"], publicHeadersPath: "include")],
    cxxLanguageStandard: .cxx17
)
