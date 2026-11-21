import Foundation
import OptOutKitCore
import CatalogSource

/// The compiled catalog the model's Mac tests read, built once from the repository's own data (the app gets the same file from its build step, `CatalogPlugin`).
enum MacCatalog {
    static let built: URL? = {
        // Packages/AssistedRunLogic/Sources/AssistedRunLogic/MacCatalog.swift: five folders below the repository.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ook-model-catalog-\(UUID())")
        let file = dir.appendingPathComponent(Catalog.fileName)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Catalog.write(try Catalog.load(repository: root), to: file)
            return file
        } catch { return nil }
    }()
}
