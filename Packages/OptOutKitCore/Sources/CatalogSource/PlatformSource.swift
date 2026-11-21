import Foundation
import OptOutKitCore
import Yams

public enum PlatformLoader {
    struct Meta: Decodable {
        struct Body: Decodable {
            var shortName: String
            var jurisdiction: String
            var states: [String]
            var requestURL: URL
            var holdDays: Int
            var live: Bool?
            var summary: String
            var coverageFile: String?
            enum CodingKeys: String, CodingKey {
                case jurisdiction, states, summary, live
                case shortName = "short_name"
                case requestURL = "request_url", holdDays = "hold_days", coverageFile = "coverage_file"
            }
        }
        var platform: Body
    }

    struct CoverageFile: Decodable {
        var registered: Int
        var covered: [String: Platform.Coverage]
    }

    /// Loads every `*.yml` in `platforms/`. Each file is a broker walkthrough with a `platform:` block, plus the coverage JSON it names.
    public static func load(directory: URL) throws -> [Platform] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "yml" }
        return try files.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { file in
            let text = try String(contentsOf: file, encoding: .utf8)
            let broker = try YAMLDecoder().decode(Broker.self, from: text)
            if broker.id.isEmpty { throw RegistryError.emptyID(file: file.lastPathComponent) }
            if broker.steps.isEmpty { throw RegistryError.noSteps(broker.id) }
            let meta = try YAMLDecoder().decode(Meta.self, from: text).platform
            var coverage: [String: Platform.Coverage] = [:]
            var registered = 0
            if let name = meta.coverageFile {
                let data = try Data(contentsOf: directory.appendingPathComponent(name))
                let file = try JSONDecoder().decode(CoverageFile.self, from: data)
                coverage = file.covered; registered = file.registered
            }
            return Platform(walkthrough: broker, shortName: meta.shortName, jurisdiction: meta.jurisdiction, states: meta.states, requestURL: meta.requestURL,
                            holdDays: meta.holdDays, live: meta.live ?? true, summary: meta.summary, registered: registered, coverage: coverage)
        }
    }
}
