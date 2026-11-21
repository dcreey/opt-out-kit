import Foundation
import CatalogSource
import OptOutKitCore

// Compiles the repository's data (YAML and the registry summary) into the app's Catalog.sqlite. Run by the CatalogPlugin build tool at every build
// whose data changed, and by hand:  swift run --package-path Packages/OptOutKitCore catalog-builder <repository> <output.sqlite>
// It writes the file, reads it back, and fails (so the build fails) unless what it reads equals what the loaders gave: a value the catalog cannot
// carry exactly is caught here, not on a phone.
let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: catalog-builder <repository> <output.sqlite>\n".utf8)); exit(2)
}
let root = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
do {
    let start = Date()
    let source = try Catalog.load(repository: root)
    try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Catalog.write(source, to: out)
    try Catalog.verify(source, at: out)
    let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
    let c = source.contents
    print("catalog: \(c.sites.count) sites, \(c.brokers.count) flows, \(c.platforms.count) platforms, \(c.jurisdictions.count) jurisdictions, \(source.scripts.count) page scripts, \(source.zips.count) ZIP codes, \(size / 1024) KB, \(Int(Date().timeIntervalSince(start) * 1000)) ms")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1)
}
