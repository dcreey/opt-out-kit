import Foundation

/// When a page has settled enough to be read: the app waits for it after loading a page and after each click (`WebViewSession.settlePage`).
public enum PageSettle {
    /// How often the page is looked at while waiting.
    public static let pollEvery: TimeInterval = 0.25
    /// How long the page must stay the same (loaded, its text unchanged, no "Loading…" showing) to count as settled.
    public static let quietFor: TimeInterval = 1.5

    private static let loadingWords = try! NSRegularExpression(pattern: #"\b(loading|please wait|searching)\b"#, options: [.caseInsensitive])

    /// Whether the page's visible text says it is still working ("Loading…", "Please wait", "Searching…"). Whole words only: a page that mentions
    /// "downloading your data" or "uploading" is not loading. Build 48 matched any text containing "loading", so such a page was waited on for the
    /// full limit at every step and the background run ran out of time on it.
    public static func stillLoading(_ text: String) -> Bool {
        loadingWords.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Whether one look at the page counts toward "settled": loaded, its text the same as the last look, no "Loading…" showing, and no navigation under way.
    /// The last is what makes a sent form's answer count: right after send is pressed the old page is still loaded and unchanged while the answer is on its way,
    /// and on a slow machine it looked settled before the answer arrived ("nothing on the page changed after sending" for a form the site had taken).
    public static func quietLook(ready: Bool, navigating: Bool, sameText: Bool, text: String) -> Bool {
        ready && !navigating && sameText && !stillLoading(text)
    }

    /// Whether a page probed as `(readyState, text)` is settled, given how many probes in a row it has looked the same.
    public static func settled(sameFor probes: Int) -> Bool { Double(probes) * pollEvery >= quietFor }
}
