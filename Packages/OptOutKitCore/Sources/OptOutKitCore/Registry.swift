import Foundation
import Yams

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

public enum Queue {
    /// Easiest tier first so users bank quick wins; ties break by name. TODO: weight by family size and priority.
    public static func ordered(_ brokers: [Broker]) -> [Broker] {
        brokers.sorted { ($0.tier, $0.name) < ($1.tier, $1.name) }
    }
}
