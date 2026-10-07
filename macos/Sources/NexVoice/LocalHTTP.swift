import Foundation

/// Lazily creates one URLSession and hands the same instance back forever.
///
/// claude-c13r: probes, vocab calls and the provider tester used to build a new
/// `URLSession` per call and never invalidate it. The 5-second health loop alone
/// leaked ~170k sessions over 19 days of uptime. The factory is injectable so a
/// test can count how many sessions actually get created.
final class SharedURLSessionProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let factory: @Sendable () -> URLSession
    private var cached: URLSession?
    private var creations = 0

    init(factory: @escaping @Sendable () -> URLSession) {
        self.factory = factory
    }

    var session: URLSession {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let created = factory()
        creations += 1
        cached = created
        return created
    }

    var sessionsCreated: Int {
        lock.lock(); defer { lock.unlock() }
        return creations
    }
}

enum LocalHTTP {
    /// Shared ephemeral session for short control-plane calls (runtime health
    /// probes, shutdown, vocab, provider connection tests). Per-call deadlines
    /// come from `URLRequest.timeoutInterval`; the resource ceiling here only
    /// bounds the slowest caller (provider tester).
    static let shared = SharedURLSessionProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration)
    }

    /// Buffered request with a response-size ceiling. Rejects up front when the
    /// declared Content-Length is too large, and again after the body arrives.
    static func data(
        for request: URLRequest,
        maxBytes: Int,
        provider: SharedURLSessionProvider = shared
    ) async throws -> (Data, URLResponse) {
        let (data, response) = try await provider.session.data(for: request)
        guard response.expectedContentLength <= Int64(maxBytes),
              data.count <= maxBytes
        else { throw VoiceAPIError.responseTooLarge }
        return (data, response)
    }
}
