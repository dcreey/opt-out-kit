import Foundation

/// Plain HTTPS fetcher: no cookies, no cache, no tracking, an honest user agent, and a size cap.
/// A site that blocks it gets an inconclusive result; we do not disguise the request.
public struct URLSessionFetcher: PageFetcher {
    private let session: URLSession
    private let maxBytes: Int

    public init(maxBytes: Int = 3_000_000) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.httpAdditionalHeaders = ["User-Agent": "OptOutKit/1.0 (open source; local check)",
                                        "Accept": "text/html,application/xhtml+xml"]
        session = URLSession(configuration: config)
        self.maxBytes = maxBytes
    }

    public func fetch(_ url: URL) async throws -> FetchedPage {
        guard url.scheme == "https" else { throw URLError(.unsupportedURL) }
        return try await send(URLRequest(url: url))
    }

    public func post(_ url: URL, body: String) async throws -> FetchedPage {
        guard url.scheme == "https" else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> FetchedPage {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return FetchedPage(status: status, text: String(decoding: data.prefix(maxBytes), as: UTF8.self))
    }
}
