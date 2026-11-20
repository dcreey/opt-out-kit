// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "OptOutKitCore",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OptOutKitCore", targets: ["OptOutKitCore"]),
        .executable(name: "broker-pipeline", targets: ["broker-pipeline"]),
        .executable(name: "catalog-builder", targets: ["catalog-builder"]),
        // Builds Catalog.sqlite into the app at build time (applied to the app target in project.yml).
        .plugin(name: "CatalogPlugin", targets: ["CatalogPlugin"]),
    ],
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0")],
    targets: [
        .target(name: "OptOutKitCore", dependencies: ["Yams"], resources: [.process("Resources")]),
        .executableTarget(name: "broker-pipeline", dependencies: ["OptOutKitCore"]),
        .executableTarget(name: "catalog-builder", dependencies: ["OptOutKitCore"]),
        .plugin(name: "CatalogPlugin", capability: .buildTool(), dependencies: ["catalog-builder"]),
        .testTarget(name: "OptOutKitCoreTests", dependencies: ["OptOutKitCore"]),
    ]
)
