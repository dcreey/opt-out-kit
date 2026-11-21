import Foundation
import OptOutKitCore
import Yams

/// Reads the repository's YAML (docs/DIRECTORY.md): used at build time by `catalog-builder` and by tests, never by the app, which reads Catalog.sqlite.
public enum RegistryError: Error, Equatable {
    case emptyID(file: String)
    case duplicateID(String)
    case noSteps(String)
}

public enum Registry {
    /// Decodes one broker definition from YAML text.
    public static func decode(yaml: String) throws -> Broker {
        try YAMLDecoder().decode(Broker.self, from: yaml)
    }

    /// Loads every `*.yml` in a directory, validates basic invariants, and returns the queue order.
    public static func load(directory: URL) throws -> [Broker] {
        let files = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "yml" }
        let brokers = try files.map { file -> Broker in
            let broker = try decode(yaml: String(contentsOf: file, encoding: .utf8))
            if broker.id.isEmpty { throw RegistryError.emptyID(file: file.lastPathComponent) }
            if broker.steps.isEmpty { throw RegistryError.noSteps(broker.id) }
            return broker
        }
        var seen = Set<String>()
        for b in brokers where !seen.insert(b.id).inserted { throw RegistryError.duplicateID(b.id) }
        return Queue.ordered(brokers)
    }
}

public extension Registry {
    /// Loads every `*.yml` in the directory folder. Files that fail to decode are an error, not skipped.
    static func loadDirectory(_ directory: URL) throws -> [DirectoryEntry] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "yml" }
        let entries = try files.map { file -> DirectoryEntry in
            var e = try YAMLDecoder().decode(DirectoryEntry.self, from: String(contentsOf: file, encoding: .utf8))
            e.contactEmail = ContactEmail.cleaned(e.contactEmail)      // a trailing "." from the sentence it was found in would make the address invalid
            return e
        }
        var seen = Set<String>()
        for e in entries where !seen.insert(e.id).inserted { throw RegistryError.duplicateID(e.id) }
        return entries.sorted { $0.domain < $1.domain }
    }
}
