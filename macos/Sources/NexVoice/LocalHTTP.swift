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

    /// Request with a response-size ceiling enforced while the body streams
    /// in: the task is cancelled as soon as the declared Content-Length or the
    /// bytes received so far exceed `maxBytes`, so a misbehaving listener on a
    /// local port can never make us buffer more than `maxBytes` (+ one chunk).
    /// Throws `LocalHTTPError.responseTooLarge` for that case, distinct from
    /// transport errors (URLError).
    static func data(
        for request: URLRequest,
        maxBytes: Int,
        provider: SharedURLSessionProvider = shared
    ) async throws -> (Data, URLResponse) {
        let task = provider.session.dataTask(with: request)
        let collector = BoundedDataCollector(maxBytes: maxBytes)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collector.install(continuation)
                // Task-specific delegate (macOS 12+): receives this task's
                // data/completion callbacks; the task retains it until done.
                task.delegate = collector
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

enum LocalHTTPError: Error, Equatable, LocalizedError {
    case responseTooLarge(limit: Int)

    var errorDescription: String? {
        switch self {
        case .responseTooLarge(let limit):
            "回應超過 \(limit / 1_024) KB 上限"
        }
    }
}

private final class BoundedDataCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let maxBytes: Int
    private var buffer = Data()
    private var exceeded = false
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?

    init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }

    func install(_ continuation: CheckedContinuation<(Data, URLResponse), Error>) {
        lock.lock(); defer { lock.unlock() }
        self.continuation = continuation
    }

    private func declaredTooLarge(_ response: URLResponse?) -> Bool {
        guard let response else { return false }
        return response.expectedContentLength > Int64(maxBytes)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if exceeded {
            lock.unlock()
            return
        }
        if declaredTooLarge(dataTask.response) || buffer.count + data.count > maxBytes {
            exceeded = true
            buffer = Data()
            lock.unlock()
            dataTask.cancel()
            return
        }
        buffer.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let tooLarge = exceeded || declaredTooLarge(task.response)
        let body = buffer
        buffer = Data()
        lock.unlock()
        guard let continuation else { return }

        if tooLarge {
            continuation.resume(throwing: LocalHTTPError.responseTooLarge(limit: maxBytes))
        } else if let error {
            continuation.resume(throwing: error)
        } else if let response = task.response {
            continuation.resume(returning: (body, response))
        } else {
            continuation.resume(throwing: URLError(.badServerResponse))
        }
    }
}
