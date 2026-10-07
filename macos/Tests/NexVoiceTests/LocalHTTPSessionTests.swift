import Foundation
import XCTest
@testable import NexVoice

/// Answers every request with HTTP 503 without touching the network, and counts
/// how many requests actually went through a session.
final class CountingStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        count = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://127.0.0.1/")!,
            statusCode: 503,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "0"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Streams a configurable HTTP 200 body in chunks from a background queue,
/// stopping as soon as the client cancels -- lets tests observe whether a
/// size limit is enforced mid-stream rather than after buffering.
final class StreamingStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Config {
        var totalBytes = 0
        var chunkBytes = 16 * 1_024
        var declareContentLength = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var config = Config()
    nonisolated(unsafe) private static var sent = 0

    static func configure(_ value: Config) {
        lock.lock(); defer { lock.unlock() }
        config = value
        sent = 0
    }

    static var bytesSent: Int {
        lock.lock(); defer { lock.unlock() }
        return sent
    }

    private let stateLock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let config = Self.config
        Self.lock.unlock()
        var headers: [String: String] = [:]
        if config.declareContentLength { headers["Content-Length"] = String(config.totalBytes) }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://127.0.0.1/")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        DispatchQueue.global().async {
            var remaining = config.totalBytes
            while remaining > 0 {
                self.stateLock.lock()
                let stopped = self.stopped
                self.stateLock.unlock()
                if stopped { return }
                let size = min(config.chunkBytes, remaining)
                self.client?.urlProtocol(self, didLoad: Data(repeating: 0x20, count: size))
                Self.lock.lock(); Self.sent += size; Self.lock.unlock()
                remaining -= size
                usleep(200)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stateLock.lock(); defer { stateLock.unlock() }
        stopped = true
    }
}

final class LocalHTTPSessionTests: XCTestCase {
    /// claude-c13r: every health probe used to build (and leak) a new
    /// URLSession. 1000 probes must go through exactly one session.
    func testRepeatedProbesReuseOneSession() async throws {
        try XCTSkipIf(
            LocalRuntimeToken.current == nil,
            "probe returns before networking without a local runtime token"
        )
        CountingStubURLProtocol.reset()
        let provider = SharedURLSessionProvider {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [CountingStubURLProtocol.self]
            return URLSession(configuration: configuration)
        }
        let manifest = LocalRuntimeManifest(
            schema: 1,
            contractVersion: 2,
            runtimeBuild: "sha256:" + String(repeating: "c", count: 64)
        )

        for _ in 0..<1_000 {
            let result = await LocalRuntimeContract.probe(
                expected: manifest,
                timeout: 1,
                sessionProvider: provider
            )
            XCTAssertEqual(result, .occupied("本機 runtime HTTP 503"))
        }

        // Every probe really went over the (stubbed) wire ...
        XCTAssertEqual(CountingStubURLProtocol.requestCount, 1_000)
        // ... through a single session.
        XCTAssertEqual(provider.sessionsCreated, 1)
    }

    private func streamingProvider() -> SharedURLSessionProvider {
        SharedURLSessionProvider {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StreamingStubURLProtocol.self]
            return URLSession(configuration: configuration)
        }
    }

    func testBodyWithinLimitIsReturned() async throws {
        StreamingStubURLProtocol.configure(.init(totalBytes: 100_000))
        let request = URLRequest(url: URL(string: "http://127.0.0.1:5112/health")!)
        let (data, response) = try await LocalHTTP.data(
            for: request, maxBytes: 256 * 1_024, provider: streamingProvider()
        )
        XCTAssertEqual(data.count, 100_000)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    /// No Content-Length, endless-ish body: the limit must trip while
    /// streaming and cancel the transfer long before the sender is done.
    func testOversizedStreamIsCancelledMidStream() async throws {
        let total = 64 * 1_024 * 1_024
        StreamingStubURLProtocol.configure(.init(totalBytes: total))
        let request = URLRequest(url: URL(string: "http://127.0.0.1:5112/health")!)
        do {
            _ = try await LocalHTTP.data(for: request, maxBytes: 256 * 1_024, provider: streamingProvider())
            XCTFail("expected responseTooLarge")
        } catch let error as LocalHTTPError {
            XCTAssertEqual(error, .responseTooLarge(limit: 256 * 1_024))
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertLessThan(StreamingStubURLProtocol.bytesSent, total / 4)
    }

    func testDeclaredOversizedContentLengthIsRejected() async throws {
        StreamingStubURLProtocol.configure(.init(totalBytes: 300_000, declareContentLength: true))
        let request = URLRequest(url: URL(string: "http://127.0.0.1:5112/health")!)
        do {
            _ = try await LocalHTTP.data(for: request, maxBytes: 256 * 1_024, provider: streamingProvider())
            XCTFail("expected responseTooLarge")
        } catch let error as LocalHTTPError {
            XCTAssertEqual(error, .responseTooLarge(limit: 256 * 1_024))
        }
    }

    /// An over-limit /health must surface as its own result, never as
    /// `.occupied` (which the app reads as a foreign/legacy runtime).
    func testOversizedHealthIsNotReportedAsOccupied() async throws {
        try XCTSkipIf(
            LocalRuntimeToken.current == nil,
            "probe returns before networking without a local runtime token"
        )
        StreamingStubURLProtocol.configure(.init(totalBytes: 300_000))
        let manifest = LocalRuntimeManifest(
            schema: 1,
            contractVersion: 2,
            runtimeBuild: "sha256:" + String(repeating: "c", count: 64)
        )
        let result = await LocalRuntimeContract.probe(
            expected: manifest, timeout: 2, sessionProvider: streamingProvider()
        )
        XCTAssertEqual(result, .oversizedResponse(limit: LocalRuntimeContract.maxResponseBytes))
        XCTAssertEqual(LocalRuntimeContract.maxResponseBytes, 256 * 1_024)
    }

    func testProviderCreatesLazilyAndOnce() {
        let provider = SharedURLSessionProvider { URLSession(configuration: .ephemeral) }
        XCTAssertEqual(provider.sessionsCreated, 0)
        let first = provider.session
        for _ in 0..<1_000 { XCTAssertTrue(provider.session === first) }
        XCTAssertEqual(provider.sessionsCreated, 1)
    }
}

final class HealthPollBackoffTests: XCTestCase {
    func testBacksOffAfterFiveHealthyChecksAndResetsOnFailure() {
        var backoff = HealthPollBackoff()
        for _ in 0..<4 { XCTAssertEqual(backoff.record(healthy: true), 5) }
        XCTAssertEqual(backoff.record(healthy: true), 30)
        XCTAssertEqual(backoff.record(healthy: true), 30)
        XCTAssertEqual(backoff.record(healthy: false), 5)
        XCTAssertEqual(backoff.record(healthy: true), 5)
    }
}
