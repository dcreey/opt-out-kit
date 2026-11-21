import XCTest
import JavaScriptCore
@testable import AssistedRunLogic

/// The page scripts load from the compiled catalog and are valid JavaScript, and a value passed to one arrives exactly as given, whatever it holds.
/// (What each script does to a page is tested in tools/pagescripts, in a headless DOM; docs/TESTING.md, "Page scripts".)
final class PageScriptTests: XCTestCase {
    override func setUp() { AppCatalog.ensureOpen() }

    func testEveryScriptInTheCatalogLoadsAndIsValidJavaScript() {
        let names = PageScript.names
        XCTAssertGreaterThanOrEqual(names.count, 50, "the scripts are in the catalog: \(names.count)")
        for name in names {
            let source = PageScript.source(name)
            XCTAssertFalse(source.isEmpty || source == "null", "\(name) loaded")
            XCTAssertFalse(source.contains("//#include "), "\(name)'s includes were resolved")
            let ctx = JSContext()!
            var exception: JSValueRef?
            let ok = JSCheckScriptSyntax(ctx.jsGlobalContextRef, JSStringCreateWithCFString(source as CFString), nil, 1, &exception)
            XCTAssertTrue(ok, "\(name) is valid JavaScript")
        }
    }

    func testTheSharedFragmentIsIncludedWhereItIsUsed() {
        for name in ["choose-tile-buttons", "choose-request-options"] {
            XCTAssertTrue(PageScript.source(name).contains("window.__ookUserWatch"), "\(name) has the ownership fragment")
        }
    }

    /// A value is handed over as JSON, so an apostrophe, quotes, a backslash, a line separator or a non-English name arrive as they were.
    func testAValueArrivesExactlyAsGivenWhateverItHolds() {
        let ctx = JSContext()!
        for value in ["O'Brien", "Say \"hi\"", "back\\slash", "a\u{2028}b\u{2029}c", "José Ñúñez 李", "</script>", ""] {
            let js = "(function(x){return x;})(" + PageScript.json(value) + ")"
            XCTAssertEqual(ctx.evaluateScript(js)?.toString(), value, "\(value.debugDescription) round-trips")
        }
        XCTAssertEqual(ctx.evaluateScript("(function(a,b,c){return [a,b,c].join('|');})(" + [PageScript.json(3), PageScript.json(true), PageScript.json(["x": 1])].joined(separator: ",") + ")")?.toString(),
                       "3|true|[object Object]", "numbers, true/false and dictionaries keep their kind")
    }
}
