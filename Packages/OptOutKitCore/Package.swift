// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "OptOutKitCore",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OptOutKitCore", targets: ["OptOutKitCore"]),
        // Reads the repository's YAML into a catalog: the Mac tests of the model build one (`Packages/AssistedRunLogic`); the app links neither this nor Yams.
        .library(name: "CatalogSource", targets: ["CatalogSource"]),
        .executable(name: "broker-pipeline", targets: ["broker-pipeline"]),
        .executable(name: "catalog-builder", targets: ["catalog-builder"]),
        // Builds Catalog.sqlite into the app at build time (applied to the app target in project.yml).
        .plugin(name: "CatalogPlugin", targets: ["CatalogPlugin"]),
    ],
    // Yams reads the repository's YAML for CatalogSource (build time and tests only); the app itself links neither.
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0")],
    targets: [
        .target(name: "OptOutKitCore", resources: [.process("Resources")]),
        // Reads the repository's YAML and compiles it into Catalog.sqlite; used by catalog-builder, broker-pipeline and tests, never linked into the app.
        .target(name: "CatalogSource", dependencies: ["OptOutKitCore", "Yams"]),
        .executableTarget(name: "broker-pipeline", dependencies: ["OptOutKitCore", "CatalogSource"]),
        .executableTarget(name: "catalog-builder", dependencies: ["OptOutKitCore", "CatalogSource"]),
        .plugin(name: "CatalogPlugin", capability: .buildTool(), dependencies: ["catalog-builder"]),
        .testTarget(name: "OptOutKitCoreTests", dependencies: ["OptOutKitCore", "CatalogSource"]),
    ]
)
