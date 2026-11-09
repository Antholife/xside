import Foundation
import Testing
@testable import XSideCore

/// A local `URLProtocol`: answers from a table keyed by URL, never touches the network. Each test
/// uses its own host so parallel tests don't share entries.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case body(status: Int, headers: [String: String], chunks: [Data])
        case redirect(to: String, status: Int)
    }
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var seen: [String] = []
    private static let lock = NSLock()

    static func set(_ url: String, _ reply: Reply) { lock.withLock { replies[url] = reply } }
    static func requests(host: String) -> [String] { lock.withLock { seen.filter { URL(string: $0)?.host == host } } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var stopped = false
    private let stopLock = NSLock()

    override func startLoading() {
        let url = request.url!.absoluteString
        let reply = Self.lock.withLock { () -> Reply? in Self.seen.append(url); return Self.replies[url] }
        guard let client else { return }
        switch reply {
        case nil:
            client.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        case .redirect(let to, let status)?:
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": to])!
            client.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: to)!), redirectResponse: response)
            client.urlProtocolDidFinishLoading(self)
        case .body(let status, let headers, let chunks)?:
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks {
                if stopLock.withLock({ stopped }) { return }
                client.urlProtocol(self, didLoad: chunk)
            }
            client.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() { stopLock.withLock { stopped = true } }
}

struct HTTPFetcherTests {
    private let fetcher = URLSessionFetcher(userAgent: "XSide/test", protocolClasses: [StubURLProtocol.self])

    private func host() -> String { "h\(UUID().uuidString.prefix(8).lowercased()).test" }

    @Test func redirectPolicy() {
        #expect(RedirectPolicy.maxRedirects == 3)
        #expect(!RedirectPolicy.allows(URL(string: "http://cdn.x/a.deb")!, count: 1))
        #expect(RedirectPolicy.allows(URL(string: "https://cdn.x/")!, count: 1))
        #expect(RedirectPolicy.allows(URL(string: "HTTPS://cdn.x/")!, count: 3))
        #expect(!RedirectPolicy.allows(URL(string: "https://cdn.x/")!, count: 4))
        #expect(!RedirectPolicy.allows(URL(string: "ftp://cdn.x/")!, count: 1))
        #expect(!RedirectPolicy.allows(URL(string: "https:///nohost")!, count: 1))
    }

    @Test func fetchesAndReturnsTheBytes() async throws {
        try await withTemporaryDirectory("http") { dir in
            let h = host()
            StubURLProtocol.set("https://\(h)/Release", .body(status: 200, headers: [:], chunks: [Data("ab".utf8), Data("cd".utf8)]))
            let out = dir.appendingPathComponent("r")
            let final = try await fetcher.fetch(URL(string: "https://\(h)/Release")!, maxBytes: 4, to: out)
            #expect(final.absoluteString == "https://\(h)/Release")
            #expect(try Data(contentsOf: out) == Data("abcd".utf8))
        }
    }

    @Test func capStopsAndDeletes() async throws {
        try await withTemporaryDirectory("http") { dir in
            let h = host()
            let chunks = Array(repeating: Data(repeating: 7, count: 64 * 1024), count: 16)
            StubURLProtocol.set("https://\(h)/big", .body(status: 200, headers: [:], chunks: chunks))
            let out = dir.appendingPathComponent("big")
            await #expect(throws: RepoError.tooLarge) {
                try await fetcher.fetch(URL(string: "https://\(h)/big")!, maxBytes: 100 * 1024, to: out)
            }
            #expect(!FileManager.default.fileExists(atPath: out.path))
        }
    }

    @Test func plainHTTPRequestIsRefusedBeforeConnecting() async throws {
        try await withTemporaryDirectory("http") { dir in
            let h = host()
            StubURLProtocol.set("http://\(h)/Release", .body(status: 200, headers: [:], chunks: [Data("x".utf8)]))
            let out = dir.appendingPathComponent("r")
            await #expect(throws: RepoError.notHTTPS) {
                try await fetcher.fetch(URL(string: "http://\(h)/Release")!, maxBytes: 10, to: out)
            }
            #expect(StubURLProtocol.requests(host: h).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: out.path))
        }
    }

    @Test func contentLengthOverCapIsRefused() async throws {
        try await withTemporaryDirectory("http") { dir in
            let h = host()
            StubURLProtocol.set("https://\(h)/x", .body(status: 200, headers: ["Content-Length": "1000000"], chunks: [Data("x".utf8)]))
            let out = dir.appendingPathComponent("x")
            await #expect(throws: RepoError.tooLarge) {
                try await fetcher.fetch(URL(string: "https://\(h)/x")!, maxBytes: 1000, to: out)
            }
            #expect(!FileManager.default.fileExists(atPath: out.path))
        }
    }

    @Test func nonSuccessStatusIsAnError() async throws {
        try await withTemporaryDirectory("http") { dir in
            let h = host()
            StubURLProtocol.set("https://\(h)/gone", .body(status: 404, headers: [:], chunks: [Data("not found".utf8)]))
            let out = dir.appendingPathComponent("g")
            await #expect(throws: RepoError.httpStatus(404)) {
                try await fetcher.fetch(URL(string: "https://\(h)/gone")!, maxBytes: 1000, to: out)
            }
            #expect(!FileManager.default.fileExists(atPath: out.path))
        }
    }

    @Test func redirectToPlainHTTPIsRefused() async throws {
        try await withTemporaryDirectory("http") { dir in
            let h = host()
            StubURLProtocol.set("https://\(h)/a", .redirect(to: "http://\(h)/b", status: 302))
            StubURLProtocol.set("http://\(h)/b", .body(status: 200, headers: [:], chunks: [Data("x".utf8)]))
            let out = dir.appendingPathComponent("a")
            await #expect(throws: RepoError.notHTTPS) {
                try await fetcher.fetch(URL(string: "https://\(h)/a")!, maxBytes: 10, to: out)
            }
            #expect(!StubURLProtocol.requests(host: h).contains("http://\(h)/b"))
            #expect(!FileManager.default.fileExists(atPath: out.path))
        }
    }

    @Test func redirectsAreFollowedUpToThree() async throws {
        try await withTemporaryDirectory("http") { dir in
            let h = host()
            for i in 0..<4 { StubURLProtocol.set("https://\(h)/r\(i)", .redirect(to: "https://\(h)/r\(i + 1)", status: 302)) }
            StubURLProtocol.set("https://\(h)/r3", .body(status: 200, headers: [:], chunks: [Data("ok".utf8)]))
            let out = dir.appendingPathComponent("r")
            let final = try await fetcher.fetch(URL(string: "https://\(h)/r0")!, maxBytes: 10, to: out)
            #expect(final.absoluteString == "https://\(h)/r3")
            #expect(try Data(contentsOf: out) == Data("ok".utf8))
            // One more hop is one too many.
            StubURLProtocol.set("https://\(h)/r4", .body(status: 200, headers: [:], chunks: [Data("ok".utf8)]))
            StubURLProtocol.set("https://\(h)/r3", .redirect(to: "https://\(h)/r4", status: 302))
            await #expect(throws: RepoError.tooManyRedirects) {
                try await fetcher.fetch(URL(string: "https://\(h)/r0")!, maxBytes: 10, to: out)
            }
            #expect(!FileManager.default.fileExists(atPath: out.path))
        }
    }

    @Test func sessionIsEphemeralWithTimeouts() {
        let c = URLSessionFetcher.configuration(protocolClasses: nil)
        #expect(c.timeoutIntervalForRequest == 15)
        #expect(c.timeoutIntervalForResource == 120)
        #expect(c.httpCookieStorage == nil && !c.httpShouldSetCookies)
        #expect(c.urlCache == nil && c.urlCredentialStorage == nil)
        #expect(c.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(URLSessionFetcher.defaultUserAgent.hasPrefix("XSide/"))
    }
}
