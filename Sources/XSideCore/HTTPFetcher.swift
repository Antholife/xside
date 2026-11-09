import Foundation

/// Why a trusted-repo lookup or download stopped.
public enum RepoError: Error, Equatable {
    case notHTTPS, tooManyRedirects, tooLarge, timedOut, httpStatus(Int), noIndex, indexHashMismatch,
         notFound(String), noVersionSatisfying(String), badFilename, sizeMismatch, hashMismatch, notAllowlisted
}

/// Downloads one URL into a file, capped.
public protocol HTTPFetching: Sendable {
    /// Writes the body to `file` and returns the final URL after redirects. Past `maxBytes` (or a
    /// declared `Content-Length` over it) it stops with `RepoError.tooLarge`; on any throw `file` is gone.
    /// With `origin`, a redirect hop to another scheme, host or port is refused before it is
    /// followed (`RepoError.notAllowlisted`).
    func fetch(_ url: URL, maxBytes: Int, to file: URL, stayingOn origin: URL?) async throws -> URL
}

extension HTTPFetching {
    /// Redirects may go to any HTTPS host (within `RedirectPolicy`).
    public func fetch(_ url: URL, maxBytes: Int, to file: URL) async throws -> URL {
        try await fetch(url, maxBytes: maxBytes, to: file, stayingOn: nil)
    }
}

/// URLs as they appear in the log: no user info, query or fragment (CDN links carry signatures).
enum RepoLog {
    static func display(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return "<url>" }
        c.user = nil; c.password = nil; c.query = nil; c.fragment = nil
        return c.string ?? "<url>"
    }
}

/// Redirects: `https` only (with a host), at most `maxRedirects` hops.
public enum RedirectPolicy {
    public static let maxRedirects = 3

    /// `count` is the number of this redirect (1 for the first).
    public static func allows(_ url: URL, count: Int) -> Bool {
        isHTTPS(url) && count >= 1 && count <= maxRedirects
    }

    static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty
    }

    /// Same scheme (https), host and port.
    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        isHTTPS(a) && isHTTPS(b) && a.host?.lowercased() == b.host?.lowercased() && a.port == b.port
    }
}

/// The real fetcher: an ephemeral `URLSession` (no cookies, cache or credentials), 15 s per
/// request, 120 s per download, the body streamed to disk and counted.
public struct URLSessionFetcher: HTTPFetching {
    public static let defaultUserAgent =
        "XSide/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")"

    private let userAgent: String
    /// Tests only: a local `URLProtocol` instead of the network.
    nonisolated(unsafe) private let protocolClasses: [AnyClass]?
    private let log = Log("repo")

    public init(userAgent: String = URLSessionFetcher.defaultUserAgent) {
        self.init(userAgent: userAgent, protocolClasses: nil)
    }

    init(userAgent: String, protocolClasses: [AnyClass]?) {
        self.userAgent = userAgent
        self.protocolClasses = protocolClasses
    }

    static func configuration(protocolClasses: [AnyClass]?) -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCache = nil
        c.urlCredentialStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 120
        c.waitsForConnectivity = false
        if let protocolClasses { c.protocolClasses = protocolClasses }
        return c
    }

    public func fetch(_ url: URL, maxBytes: Int, to file: URL, stayingOn origin: URL?) async throws -> URL {
        try? FileManager.default.removeItem(at: file)
        guard RedirectPolicy.isHTTPS(url) else {
            log.error("refused (not https): \(RepoLog.display(url))")
            throw RepoError.notHTTPS
        }
        guard maxBytes >= 0 else { throw RepoError.tooLarge }
        try Task.checkCancellation()
        log.info("GET \(RepoLog.display(url)) (cap \(maxBytes) bytes)")
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        let delegate = FetchDelegate(file: file, maxBytes: maxBytes, origin: origin)
        let session = URLSession(configuration: Self.configuration(protocolClasses: protocolClasses),
                                 delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        do {
            let final = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                    delegate.start(c)
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
            log.info("got \(RepoLog.display(url)): status \(delegate.status ?? 0), \(delegate.bytes) bytes, final \(RepoLog.display(final))")
            return final
        } catch {
            try? FileManager.default.removeItem(at: file)
            log.error("failed \(RepoLog.display(url)): status \(delegate.status.map(String.init) ?? "-"), \(delegate.bytes) bytes, \(error)")
            throw error
        }
    }
}

/// One download's state. URLSession calls it on its own serial queue; the lock covers the reads
/// made from `fetch` once it is done.
private final class FetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let file: URL
    private let maxBytes: Int
    private let origin: URL?
    private var handle: FileHandle?
    private var written = 0
    private var redirects = 0
    private var failure: Error?
    private var _status: Int?
    private var continuation: CheckedContinuation<URL, Error>?

    init(file: URL, maxBytes: Int, origin: URL?) {
        self.file = file
        self.maxBytes = maxBytes
        self.origin = origin
    }

    var bytes: Int { lock.withLock { written } }
    var status: Int? { lock.withLock { _status } }

    func start(_ c: CheckedContinuation<URL, Error>) { lock.withLock { continuation = c } }

    /// Keeps the first reason only.
    private func fail(_ error: Error, _ task: URLSessionTask) {
        lock.withLock { if failure == nil { failure = error } }
        task.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let count = lock.withLock { redirects += 1; return redirects }
        guard let next = request.url, RedirectPolicy.allows(next, count: count) else {
            let https = request.url.map(RedirectPolicy.isHTTPS) ?? false
            Log("repo").error("redirect refused (\(https ? "too many" : "not https")): \(request.url.map(RepoLog.display) ?? "?")")
            fail(https ? RepoError.tooManyRedirects : RepoError.notHTTPS, task)
            completionHandler(nil)
            return
        }
        if let origin, !RedirectPolicy.sameOrigin(next, origin) {
            Log("repo").error("redirect refused (off \(RepoLog.display(origin))): \(RepoLog.display(next))")
            fail(RepoError.notAllowlisted, task)
            completionHandler(nil)
            return
        }
        Log("repo").info("redirect \(count) (\(response.statusCode)) -> \(RepoLog.display(next))")
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            fail(RepoError.httpStatus(0), dataTask); completionHandler(.cancel); return
        }
        lock.withLock { _status = http.statusCode }
        guard (200..<300).contains(http.statusCode) else {
            fail(RepoError.httpStatus(http.statusCode), dataTask); completionHandler(.cancel); return
        }
        if response.expectedContentLength > Int64(maxBytes) {
            fail(RepoError.tooLarge, dataTask); completionHandler(.cancel); return
        }
        guard response.url.map(RedirectPolicy.isHTTPS) ?? false else {
            fail(RepoError.notHTTPS, dataTask); completionHandler(.cancel); return
        }
        try? FileManager.default.removeItem(at: file)
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let h = try? FileHandle(forWritingTo: file) else {
            fail(CocoaError(.fileWriteUnknown), dataTask); completionHandler(.cancel); return
        }
        lock.withLock { handle = h }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let (h, over): (FileHandle?, Bool) = lock.withLock {
            guard failure == nil else { return (nil, false) }
            let (sum, overflow) = written.addingReportingOverflow(data.count)
            if overflow || sum > maxBytes { return (nil, true) }
            written = sum
            return (handle, false)
        }
        if over { fail(RepoError.tooLarge, dataTask); return }
        guard let h else { return }
        do { try h.write(contentsOf: data) } catch { fail(error, dataTask) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (c, h, stored) = lock.withLock { () -> (CheckedContinuation<URL, Error>?, FileHandle?, Error?) in
            defer { continuation = nil; handle = nil }
            return (continuation, handle, failure)
        }
        try? h?.close()
        var outcome: Error? = stored
        if outcome == nil, let error {
            if let u = error as? URLError {
                switch u.code {
                case .timedOut: outcome = RepoError.timedOut
                case .cancelled: outcome = CancellationError()
                default: outcome = u
                }
            } else {
                outcome = error
            }
        }
        if outcome == nil, h == nil { outcome = RepoError.httpStatus(0) }   // no response at all
        if let outcome {
            try? FileManager.default.removeItem(at: file)
            c?.resume(throwing: outcome)
        } else {
            c?.resume(returning: task.currentRequest?.url ?? task.response?.url ?? task.originalRequest?.url ?? file)
        }
    }
}
