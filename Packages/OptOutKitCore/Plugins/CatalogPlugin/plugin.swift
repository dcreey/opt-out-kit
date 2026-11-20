import Foundation
import PackagePlugin

/// Builds the app's Catalog.sqlite from the repository's data (see `Catalog` and `catalog-builder`) as a step of the app's own Xcode build, so the
/// app ships the compiled catalog and no YAML. Xcode reruns it only when one of the data files changed. Applied to the app target in project.yml.
@main
struct CatalogPlugin: BuildToolPlugin {
    // The package's own targets do not use it.
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] { [] }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension CatalogPlugin: XcodeBuildToolPlugin {
    /// The folders and files the catalog is built from, relative to the repository (the Xcode project's folder).
    static let sources = ["directory", "brokers", "platforms", "jurisdictions", "terms", "registries/summary.json"]

    func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws -> [Command] {
        let root = context.xcodeProject.directory
        var inputs: [Path] = []
        for source in Self.sources {
            let path = root.appending(subpath: source)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path.string, isDirectory: &isFolder) else { continue }
            if !isFolder.boolValue { inputs.append(path); continue }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: path.string)) ?? []
            inputs += names.filter { $0.hasSuffix(".yml") || $0.hasSuffix(".json") }.sorted().map { path.appending(subpath: $0) }
        }
        let output = context.pluginWorkDirectory.appending(subpath: "Catalog.sqlite")
        return [.buildCommand(displayName: "Compile the data catalog", executable: try context.tool(named: "catalog-builder").path,
                              arguments: [root.string, output.string], inputFiles: inputs, outputFiles: [output])]
    }
}
#endif
