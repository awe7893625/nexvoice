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
