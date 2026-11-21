// swift-tools-version:5.10
import PackageDescription

// The assisted run's state machine (runner, email handoff) and the app's model (`AppModel`, Shared/Model) compiled for the Mac so their tests run with `swift test`, no simulator.
// The sources are the app's own: Sources/AssistedRunLogic is a link to Shared/AssistedRun. Loc is stubbed by LocStub.swift.
let package = Package(
    name: "AssistedRunLogic",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../OptOutKitCore")],
    targets: [
        .target(name: "AssistedRunLogic", dependencies: [.product(name: "OptOutKitCore", package: "OptOutKitCore"), .product(name: "CatalogSource", package: "OptOutKitCore")], path: "Sources/AssistedRunLogic"),
        .testTarget(name: "AssistedRunLogicTests", dependencies: ["AssistedRunLogic", .product(name: "OptOutKitCore", package: "OptOutKitCore")]),
    ]
)
