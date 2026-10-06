import XCTest
import WebKit
import JavaScriptCore
@testable import Searchy

final class OmniboxTests: XCTestCase {
    func url(_ s: String) -> String? { if case .url(let u) = Omnibox.classify(s) { return u.absoluteString } else { return nil } }
    func isSearch(_ s: String) -> Bool { if case .search = Omnibox.classify(s) { return true } else { return false } }

    func testDomainsBecomeHTTPS() {
        XCTAssertEqual(url("example.com"), "https://example.com")
        XCTAssertEqual(url("news.ycombinator.com/item?id=1"), "https://news.ycombinator.com/item?id=1")
        XCTAssertEqual(url("github.com/anthropics"), "https://github.com/anthropics")
    }
    func testLocalAddressesUseHTTP() {
        XCTAssertEqual(url("localhost:3000"), "http://localhost:3000")
        XCTAssertEqual(url("192.168.1.1"), "http://192.168.1.1")
        XCTAssertEqual(url("myserver:8080/x"), "http://myserver:8080/x")
    }
    func testExplicitSchemesKept() {
        XCTAssertEqual(url("http://example.com/a"), "http://example.com/a")
        XCTAssertEqual(url("https://example.com"), "https://example.com")
    }
    func testSentencesAndFilenamesAreSearches() {
        XCTAssertTrue(isSearch("how tall is everest"))
        XCTAssertTrue(isSearch("index.html"))
        XCTAssertTrue(isSearch("node.js"))
        XCTAssertTrue(isSearch("swiftui"))
        XCTAssertTrue(isSearch("v1.2.3"))
    }
    func testSearchURLEncoding() {
        let e = SearchEngine.named("duckduckgo")
        XCTAssertEqual(e.searchURL(for: "a&b c").absoluteString, "https://duckduckgo.com/?q=a%26b%20c")
    }
}

final class QuickSearchTests: XCTestCase {
    func testShortcuts() {
        let (yt, rest) = QuickSearch.match("yt lofi beats")!
        XCTAssertEqual(yt.name, "YouTube")
        XCTAssertEqual(rest, "lofi beats")
        XCTAssertEqual(QuickSearch.match("!gh swiftui")?.0.name, "GitHub")
        XCTAssertNil(QuickSearch.match("yt"))              // needs a query
        XCTAssertNil(QuickSearch.match("hello world"))
    }
}

final class HTTPMessageTests: XCTestCase {
    func testRequestRoundTrip() {
        let raw = "POST /login?x=1 HTTP/1.1\r\nHost: example.com\r\nContent-Type: application/json\r\n\r\n{\"a\":1}"
        let m = HTTPRequestMessage.parse(rawText: raw)!
        XCTAssertEqual(m.method, "POST")
        XCTAssertEqual(m.target, "/login?x=1")
        XCTAssertEqual(m.header("host"), "example.com")
        XCTAssertEqual(m.bodyText, "{\"a\":1}")
        XCTAssertEqual(m.header("Content-Length"), "7")
        XCTAssertTrue(m.rawText.contains("POST /login?x=1 HTTP/1.1"))
    }
    func testEditorLineEndingsTolerated() {
        let m = HTTPRequestMessage.parse(rawText: "GET / HTTP/1.1\nHost: a.test\n\n")!
        XCTAssertEqual(m.headers.count, 1)
    }
    func testBinaryBodyIsPreserved() {
        var original = HTTPRequestMessage(method: "POST", target: "/u", headers: [HTTPHeader(name: "Host", value: "a")])
        original.body = Data([0xff, 0xfe, 0x00, 0x01])
        let edited = original.rawText.replacingOccurrences(of: "POST /u", with: "PUT /u")
        let parsed = HTTPRequestMessage.parse(rawText: edited, originalBody: original.body)!
        XCTAssertEqual(parsed.method, "PUT")
        XCTAssertEqual(parsed.body, original.body)
    }
    func testResponseParse() {
        let r = HTTPResponseMessage.parse(rawText: "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n\r\nnope")!
        XCTAssertEqual(r.status, 404)
        XCTAssertEqual(r.reason, "Not Found")
        XCTAssertEqual(r.bodyText, "nope")
    }
    func testChunkedDecoding() {
        let body = "4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n"
        let (decoded, used) = HTTPWire.decodeChunked(Data(body.utf8))!
        XCTAssertEqual(String(data: decoded, encoding: .utf8), "Wikipedia")
        XCTAssertEqual(used, body.utf8.count)
        XCTAssertNil(HTTPWire.decodeChunked(Data("4\r\nWi".utf8)))      // incomplete
    }
    func testSetCookieSplitting() {
        let combined = "a=1; Path=/; Expires=Wed, 21 Oct 2026 07:28:00 GMT, b=2; HttpOnly, c=3; Secure"
        let parts = Upstream.splitSetCookie(combined)
        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts[0].contains("Expires=Wed, 21 Oct"))        // the comma inside the date survives
    }
}

final class RewriterAndScopeTests: XCTestCase {
    func testHeaderRewrite() {
        var req = HTTPRequestMessage(method: "GET", target: "/", headers: [HTTPHeader(name: "User-Agent", value: "Old")])
        let rule = RewriteRule(enabled: true, target: .requestHeader, pattern: "User-Agent: Old", replacement: "User-Agent: New")
        Rewriter.apply([rule], to: &req)
        XCTAssertEqual(req.header("User-Agent"), "New")
    }
    func testResponseBodyRegex() {
        var resp = HTTPResponseMessage(status: 200, reason: "OK", headers: [])
        resp.body = Data("price: 100".utf8)
        let rule = RewriteRule(enabled: true, target: .responseBody, pattern: "\\d+", replacement: "0", isRegex: true)
        Rewriter.apply([rule], to: &resp)
        XCTAssertEqual(resp.bodyText, "price: 0")
    }
    func testScopePatterns() {
        XCTAssertTrue(TrafficLab.matches(pattern: "example.com", host: "api.example.com"))
        XCTAssertTrue(TrafficLab.matches(pattern: "*.example.com", host: "example.com"))
        XCTAssertFalse(TrafficLab.matches(pattern: "example.com", host: "notexample.com"))
        XCTAssertTrue(TrafficLab.matches(pattern: "api.*.test", host: "api.v2.test"))
    }
}

final class OfflineKeyTests: XCTestCase {
    func testKeyIgnoresFragmentAndTrailingSlash() {
        let a = OfflineStore.key(URL(string: "https://Example.com/path/#top"))
        let b = OfflineStore.key(URL(string: "https://example.com/path"))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(OfflineStore.key(URL(string: "https://example.com/a")), OfflineStore.key(URL(string: "https://example.com/b")))
    }
}

/// Every rule list must compile in WebKit, or blocking silently stops working.
@MainActor
final class RuleListTests: XCTestCase {
    private func compiles(_ json: String, _ id: String) async throws {
        let store = WKContentRuleListStore.default()!
        defer { Task { try? await store.removeContentRuleList(forIdentifier: id) } }
        _ = try await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json)
    }
    func testAdRules() async throws {
        XCTAssertGreaterThan(BlockLists.domains.count, 200)
        try await compiles(ContentBlocker.adRulesJSON(allowlist: ["example.com"]), "test.ads")
    }
    func testLiteRules() async throws {
        try await compiles(ContentBlocker.liteRulesJSON(level: .lite, allowImages: []), "test.lite")
        try await compiles(ContentBlocker.liteRulesJSON(level: .textOnly, allowImages: ["example.com"]), "test.text")
    }
    func testHiddenRules() async throws {
        try await compiles(ContentBlocker.hiddenRulesJSON(["example.com": ["#banner", "div.ad > a:nth-of-type(2)"]]), "test.hidden")
    }
}

/// The page scripts are plain JS files; a syntax slip would silently disable a feature.
final class ScriptSyntaxTests: XCTestCase {
    func testScriptsParse() throws {
        let names = ["bridge", "picker", "reader"]
        for name in names {
            let url = try XCTUnwrap(Bundle(for: WebEngine.self).url(forResource: name, withExtension: "js"), "missing \(name).js")
            let source = try String(contentsOf: url, encoding: .utf8)
            let context = try XCTUnwrap(JSContext())
            var failure: String?
            context.exceptionHandler = { _, e in failure = e?.toString() }
            _ = context.evaluateScript("new Function(\(try jsonString(source)))")
            XCTAssertNil(failure, "\(name).js: \(failure ?? "")")
        }
    }
    private func jsonString(_ s: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [s], options: [])
        let arr = String(data: data, encoding: .utf8)!
        return String(arr.dropFirst().dropLast())
    }
}
