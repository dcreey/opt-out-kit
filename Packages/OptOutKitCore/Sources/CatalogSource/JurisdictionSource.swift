import Foundation
import OptOutKitCore
import Yams

public enum JurisdictionLoader {
    struct File: Decodable { var kind: String?; var reviewed: String?; var jurisdictions: [Jurisdiction] }

    /// Every jurisdiction in every `*.yml` in the folder.
    public static func load(directory: URL) throws -> [Jurisdiction] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "yml" }
        var out: [Jurisdiction] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let f = try YAMLDecoder().decode(File.self, from: String(contentsOf: file, encoding: .utf8))
            out += f.jurisdictions.map { var j = $0; if j.kind == nil { j.kind = f.kind }; return j }
        }
        var seen = Set<String>()
        for j in out where !seen.insert(j.id).inserted { throw RegistryError.duplicateID(j.id) }
        return out
    }

    public static func loadSummary(_ url: URL) -> RegistrySummary? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(RegistrySummary.self, from: $0) }
    }
}
