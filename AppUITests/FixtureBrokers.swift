import Foundation
import XCTest

/// The fixture brokers the end-to-end tests run against: a local web server (fixtures/server.py) serving the sites of fixtures/sites, and the catalog that
/// carries them (fixtures/build_catalog.sh). tools/run_e2e.sh starts the server, builds the catalog and runs the tests with `OPTOUT_FIXTURE_CATALOG` and
/// `OPTOUT_FIXTURE_URL` set (passed to the test runner as TEST_RUNNER_...). This asks the server what it received. docs/TESTING.md, "End-to-end tests against fixture pages".
struct FixtureBrokers {
    /// One request a fixture page received.
    struct Received: Equatable {
        let site: String
        let path: String
        let fields: [String: String]
        /// When the broker received it (seconds since 1970, this machine's clock, which the app and the tests share).
        var at: TimeInterval = 0
    }

    let url: URL
    let catalog: String

    /// The brokers, ready and with nothing received yet; fails the test with the way to start them when they are not running.
    static func start(file: StaticString = #filePath, line: UInt = #line) throws -> FixtureBrokers {
        let env = ProcessInfo.processInfo.environment
        guard let catalog = env["OPTOUT_FIXTURE_CATALOG"], let address = env["OPTOUT_FIXTURE_URL"], let url = URL(string: address) else {
            XCTFail("the fixture brokers are not set up: run these tests with tools/run_e2e.sh", file: file, line: line); throw URLError(.cannotConnectToHost)
        }
        let brokers = FixtureBrokers(url: url, catalog: catalog)
        guard brokers.get("__ready") != nil else {
            XCTFail("the fixture server is not answering at \(url): tools/run_e2e.sh starts it (python3 fixtures/server.py)", file: file, line: line); throw URLError(.cannotConnectToHost)
        }
        _ = brokers.send("POST", "__reset")
        return brokers
    }

    /// The launch arguments that point the app at the fixture catalog.
    var launchArguments: [String] { ["-uitest-catalog", catalog] }

    /// Everything the pages received, oldest first.
    var requests: [Received] {
        guard let data = get("__received"), let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return list.map { Received(site: $0["site"] as? String ?? "", path: $0["path"] as? String ?? "", fields: $0["fields"] as? [String: String] ?? [:], at: $0["at"] as? TimeInterval ?? 0) }
    }

    /// One report from a long fixture page: where it was scrolled to, and whether a finger or wheel was moving it (`user`) when it moved.
    struct Scroll: Equatable {
        let site: String
        let y: Int
        let ms: Int
        let user: Bool
        let kind: String
        let max: Int
        var at: TimeInterval = 0
    }

    /// Every scroll report the long pages sent, in order.
    var scrolls: [Scroll] {
        guard let data = get("__scrolls"), let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: String]] else { return [] }
        return list.map { Scroll(site: $0["site"] ?? "", y: Int($0["y"] ?? "") ?? 0, ms: Int($0["t"] ?? "") ?? 0, user: $0["user"] == "1", kind: $0["kind"] ?? "", max: Int($0["max"] ?? "") ?? 0, at: TimeInterval($0["at"] ?? "") ?? 0) }
    }

    /// The sites whose request form was sent, in the order they were sent.
    var sentSites: [String] { requests.filter { $0.path == "send" }.map(\.site) }

    /// Waits until `condition` holds of the sent sites (the app works in the background of the test), up to `timeout` seconds.
    func waitForSent(timeout: TimeInterval, _ condition: ([String]) -> Bool) -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if condition(sentSites) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return condition(sentSites)
    }

    private func get(_ path: String) -> Data? { send("GET", path) }

    private func send(_ method: String, _ path: String) -> Data? {
        var request = URLRequest(url: url.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 5
        var result: Data?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { result = data }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        return result
    }
}
