import Foundation

/// How to ask one broker "is this person still listed?" with no input from the user.
/// Lives in the broker YAML next to the opt-out steps.
public struct Recheck: Codable, Equatable, Sendable {
    /// Search URL with placeholders: {first} {last} {full} {city} {state} {state_name} (Illinois),
    /// {city_slug} (New-York) and {state_slug} (North-Carolina).
    public var searchURL: String
    /// At least one must appear on a genuine results page. Without it we cannot tell "no results"
    /// from "the site changed or blocked us", so the answer is inconclusive, never "removed".
    public var validPage: [String]
    /// Phrases the site shows when nothing matched. Optional; absence of the person also counts.
    public var noResults: [String]?
    /// Page is built by JavaScript, so it needs a real web view instead of a plain request.
    public var needsBrowser: Bool?
    /// "GET" (default) or "POST". For POST, `body` is the form-encoded template sent to `searchURL`.
    public var method: String?
    public var body: String?
    /// The site's search has no city or state, so a name match alone counts as a listing.
    public var ignoreLocation: Bool?
    /// A known listed name, so the pipeline can prove the check still finds people ("positive control").
    public var calibration: Calibration?

    public struct Calibration: Codable, Equatable, Hashable, Sendable {
        public var listedName: String
        public var city: String?
        public var state: String?
        enum CodingKeys: String, CodingKey { case listedName = "listed_name", city, state }
        public init(listedName: String, city: String? = nil, state: String? = nil) {
            self.listedName = listedName; self.city = city; self.state = state
        }
    }

    enum CodingKeys: String, CodingKey {
        case searchURL = "search_url", validPage = "valid_page", noResults = "no_results", needsBrowser = "needs_browser"
        case ignoreLocation = "ignore_location", calibration, method, body
    }

    public init(searchURL: String, validPage: [String], noResults: [String]? = nil, needsBrowser: Bool? = nil,
                ignoreLocation: Bool? = nil, calibration: Calibration? = nil, method: String? = nil, body: String? = nil) {
        self.searchURL = searchURL; self.validPage = validPage
        self.noResults = noResults; self.needsBrowser = needsBrowser
        self.ignoreLocation = ignoreLocation; self.calibration = calibration
        self.method = method; self.body = body
    }
}

public struct FetchedPage: Sendable {
    public var status: Int
    public var text: String
    public init(status: Int, text: String) { self.status = status; self.text = text }
}

/// Supplies pages. The app backs it with URLSession (or a web view); tests use fixtures.
public protocol PageFetcher: Sendable {
    func fetch(_ url: URL) async throws -> FetchedPage
    /// POST a form-encoded body. Fetchers that cannot POST keep the default, which fails the request.
    func post(_ url: URL, body: String) async throws -> FetchedPage
}

public extension PageFetcher {
    func post(_ url: URL, body: String) async throws -> FetchedPage { throw URLError(.unsupportedURL) }
}

public enum CheckResult: String, Codable, Equatable, Sendable {
    case removed, stillListed, inconclusive
}

public enum InconclusiveReason: String, Equatable, Sendable {
    case blocked, unrecognizedPage, network, noRecheckSpec, missingProfileData, needsBrowser, termsGate
}

public struct CheckOutcome: Equatable, Sendable {
    public var result: CheckResult
    public var reason: InconclusiveReason?
    public static let removed = CheckOutcome(result: .removed, reason: nil)
    public static let stillListed = CheckOutcome(result: .stillListed, reason: nil)
    public static func inconclusive(_ r: InconclusiveReason) -> CheckOutcome { .init(result: .inconclusive, reason: r) }
}

/// Runs a re-check. It only reports what it can prove: anything unclear is inconclusive.
public struct Rechecker: Sendable {
    private let fetcher: PageFetcher
    private let browserFetcher: PageFetcher?
    /// `browserFetcher` reads pages built by JavaScript (the app's hidden web view). Without one, a spec that needs a
    /// browser is inconclusive rather than guessed at.
    public init(fetcher: PageFetcher, browserFetcher: PageFetcher? = nil) {
        self.fetcher = fetcher; self.browserFetcher = browserFetcher
    }

    /// A fetcher that reached an "I agree to our terms" prompt it was not allowed to accept appends this to the page text.
    public static let termsGateMarker = "optoutkit-terms-gate"

    /// Phrases that only a bot-check page shows. Used where we are not also expecting normal page text.
    static let hardChallengeMarkers = ["just a moment", "attention required", "verify you are human", "are you a human",
                                       "checking your browser", "performing security verification", "security challenge"]

    static let challengeMarkers = ["just a moment", "attention required", "verify you are human",
                                   "are you a human", "checking your browser", "captcha", "access denied"]

    public func check(_ broker: Broker, for person: Person) async -> CheckOutcome {
        guard let spec = broker.recheck else { return .inconclusive(.noRecheckSpec) }
        return await check(spec: spec, for: person)
    }

    /// Checks one person against a spec on its own, for directory sites that have no hand-written broker flow.
    public func check(spec: Recheck, for person: Person) async -> CheckOutcome {
        let source: PageFetcher
        if spec.needsBrowser == true {
            guard let browserFetcher else { return .inconclusive(.needsBrowser) }
            source = browserFetcher
        } else { source = fetcher }
        let names = person.allNames.filter { $0.split(separator: " ").count >= 2 }
        guard !names.isEmpty else { return .inconclusive(.missingProfileData) }
        let place = spec.ignoreLocation == true ? nil : person.addresses.first

        var outcomes: [CheckOutcome] = []
        for name in names {
            guard let url = Self.url(spec.searchURL, name: name, city: place?.city, state: place?.state) else {
                return .inconclusive(.missingProfileData)
            }
            var body: String?
            if spec.method?.uppercased() == "POST" {
                guard let template = spec.body,
                      let filled = Self.fill(template, name: name, city: place?.city, state: place?.state, encoding: .form) else {
                    return .inconclusive(.missingProfileData)
                }
                body = filled
            }
            outcomes.append(await checkOne(spec, source: source, url: url, body: body, name: name, city: place?.city))
        }
        // One listing under any known name is enough to say still listed.
        if outcomes.contains(.stillListed) { return .stillListed }
        if outcomes.allSatisfy({ $0 == .removed }) { return .removed }
        return outcomes.first { $0.result == .inconclusive } ?? .inconclusive(.unrecognizedPage)
    }

    private func checkOne(_ spec: Recheck, source fetcher: PageFetcher, url: URL, body: String?, name: String, city: String?) async -> CheckOutcome {
        var page: FetchedPage?
        for attempt in 0..<2 {                       // one retry for a flaky network
            let fetched: FetchedPage? = if let body { try? await fetcher.post(url, body: body) } else { try? await fetcher.fetch(url) }
            if let p = fetched { page = p; break }
            if attempt == 0 { try? await Task.sleep(nanoseconds: 200_000_000) }
        }
        guard let page else { return .inconclusive(.network) }
        let text = page.text.lowercased()
        if text.contains(Self.termsGateMarker) { return .inconclusive(.termsGate) }

        if [403, 429, 503].contains(page.status) || Self.challengeMarkers.contains(where: text.contains) && !spec.validPage.contains(where: { text.contains($0.lowercased()) }) {
            return .inconclusive(.blocked)
        }
        // Some sites answer "no results" with a 404, so the status alone proves nothing: the marker decides.
        guard spec.validPage.contains(where: { text.contains($0.lowercased()) }) else {
            return .inconclusive(.unrecognizedPage)
        }
        if (spec.noResults ?? []).contains(where: { text.contains($0.lowercased()) }) { return .removed }

        let nameHit = name.lowercased().split(separator: " ").allSatisfy { text.contains($0) }
        let placeHit = city.map { text.contains($0.lowercased()) } ?? true   // no city known or needed: name decides
        return nameHit && placeHit ? .stillListed : .removed
    }

    public enum Encoding { case path, form }

    /// Fills {first} {last} {full} {city} {state} {state_name} {city_slug} {state_slug}. Nil when a placeholder the
    /// template uses has no value (for example {city} for a person with no address).
    public static func fill(_ template: String, name: String, city: String?, state: String?, encoding: Encoding) -> String? {
        let parts = name.split(separator: " ").map(String.init)
        guard let first = parts.first, let last = parts.last else { return nil }
        var allowed = encoding == .path ? CharacterSet.urlPathAllowed : CharacterSet.alphanumerics
        if encoding == .form { allowed.insert(charactersIn: "-._~") }
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        let stateName = USStates.name(for: state ?? "") ?? ""
        func slug(_ v: String) -> String { v.split(separator: " ").joined(separator: "-") }
        var out = template
        for (key, value) in [("{first}", first), ("{last}", last), ("{full}", name),
                             ("{city_slug}", slug(city ?? "")), ("{state_slug}", slug(stateName)),
                             ("{city}", city ?? ""), ("{state_name}", stateName), ("{state}", state ?? "")] {
            if out.contains(key) && value.isEmpty { return nil }
            out = out.replacingOccurrences(of: key, with: enc(value))
        }
        return out
    }

    static func url(_ template: String, name: String, city: String?, state: String?) -> URL? {
        fill(template, name: name, city: city, state: state, encoding: .path).flatMap(URL.init(string:))
    }
}
