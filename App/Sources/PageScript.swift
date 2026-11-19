import Foundation

/// The JavaScript the app runs inside a web page (reading forms, filling them, finding checks and confirmations) lives in `App/PageScripts/*.js`, one
/// file per script, so it can be unit tested on its own: `tools/pagescripts` runs every file against test pages in a headless DOM (docs/TESTING.md,
/// "Page scripts"). Two kinds of file:
///
/// - A plain script is one expression, run as it is (`PageScript.source`), exactly the text that was once a Swift string.
/// - A script that takes values is a function expression, `(function(token, step){ ... })`, called with its values as JSON (`PageScript.call`). The
///   values are encoded once, here, the same way the Swift strings used to escape them; nothing is left on the page after it runs.
///
/// A line `//#include name` is replaced with the text of `name.js` (a fragment shared by several scripts). Files are read from the app bundle once and kept.
enum PageScript {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String: String] = [:]

    /// The script's text, with its includes resolved.
    static func source(_ name: String) -> String {
        lock.lock(); if let s = cache[name] { lock.unlock(); return s }; lock.unlock()
        let text = resolve(load(name), depth: 0)
        lock.lock(); cache[name] = text; lock.unlock()
        return text
    }

    /// The call of a function script with these values, in order, each passed as JSON (a string, number, bool, array or dictionary).
    static func call(_ name: String, _ values: Any...) -> String {
        "(" + source(name) + ")(" + values.map(json).joined(separator: ",") + ");"
    }

    /// The same, with values that are already JSON text (a list the caller encoded), passed as they are.
    static func call(_ name: String, json values: [String]) -> String {
        "(" + source(name) + ")(" + values.joined(separator: ",") + ");"
    }

    /// JSON for a page script, safe inside script text.
    static func json(_ value: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]),
              let s = String(data: d, encoding: .utf8) else { return "null" }
        // The two line separators are valid in JSON but ended a script string in older engines; escaped, they mean the same.
        return s.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// Every script the app has (for the test that each one loads).
    static var names: [String] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "js", subdirectory: "PageScripts") ?? []
        return urls.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    private static func load(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "PageScripts"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            assertionFailure("page script \(name).js is missing from the app bundle")
            return "null"
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolve(_ text: String, depth: Int) -> String {
        guard depth < 4, text.contains("//#include ") else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("//#include ") else { return String(line) }
            return resolve(load(String(t.dropFirst("//#include ".count)).trimmingCharacters(in: .whitespaces)), depth: depth + 1)
        }.joined(separator: "\n")
    }
}
