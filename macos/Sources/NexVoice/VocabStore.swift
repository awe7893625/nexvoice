import Darwin
import Foundation

struct VocabEntry: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    var phrase: String
    var soundsLike: String
    var enabled: Int
    var ts: String?

    enum CodingKeys: String, CodingKey {
        case id, phrase, enabled, ts
        case soundsLike = "sounds_like"
    }
}

/// Gateway vocab at M5 :5111, mirrored to a permission-restricted local cache
/// so recording never depends on a network round trip.
enum VocabStore {
    private static let base = URL(string: "http://127.0.0.1:5111")!
    private static let maxPayloadBytes = 65_536
    private static let cacheSchema = 1

    private enum StoreError: Error {
        case responseTooLarge
    }

    private struct CacheEnvelope: Codable {
        let schema: Int
        let generatedAt: String
        let entries: [VocabEntry]
    }

    private struct AuthorizedRequest {
        let request: URLRequest
        let session: URLSession
        let secret: String
        let nonce: String
        let method: String
        let path: String
    }

    static func load() async -> [VocabEntry] {
        do {
            guard let authorized = authorizedRequest(path: "/api/vocab") else {
                return loadCached()
            }
            let (data, response) = try await limitedData(
                for: authorized.request,
                session: authorized.session
            )
            guard let http = response as? HTTPURLResponse,
                  verifiedResponse(http, for: authorized),
                  200..<300 ~= http.statusCode,
                  response.expectedContentLength <= Int64(maxPayloadBytes),
                  data.count <= maxPayloadBytes
            else { return loadCached() }
            let decoder = JSONDecoder()
            guard let decoded = try? decoder.decode([VocabEntry].self, from: data) else {
                return loadCached()
            }
            let entries = VocabularyPolicy.sanitizedEntries(decoded)
            saveCache(entries)
            return entries
        } catch {
            return loadCached()
        }
    }

    static func loadCached() -> [VocabEntry] {
        let url = cacheURL
        guard secureCacheDirectory(url.deletingLastPathComponent()),
              isSecureRegularFile(url),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= maxPayloadBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= maxPayloadBytes,
              let envelope = try? JSONDecoder().decode(CacheEnvelope.self, from: data),
              envelope.schema == cacheSchema
        else { return [] }
        return VocabularyPolicy.sanitizedEntries(envelope.entries)
    }

    static func add(phrase: String, soundsLike: String) async -> Bool {
        guard let phrase = VocabularyPolicy.normalizedPhrase(phrase) else { return false }
        let soundsLike = VocabularyPolicy.normalizedVariants(soundsLike).joined(separator: ",")
        let body: [String: Any] = [
            "phrase": phrase,
            "sounds_like": soundsLike,
            "enabled": 1
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject: body),
              let authorized = authorizedRequest(
                path: "/api/vocab",
                method: "POST",
                body: encoded,
                contentType: "application/json"
              )
        else { return false }
        do {
            let (_, response) = try await limitedData(
                for: authorized.request,
                session: authorized.session
            )
            return (response as? HTTPURLResponse).map {
                verifiedResponse($0, for: authorized) && 200..<300 ~= $0.statusCode
            } ?? false
        } catch {
            return false
        }
    }

    static func delete(id: Int) async -> Bool {
        guard id > 0 else { return false }
        guard let authorized = authorizedRequest(
            path: "/api/vocab/\(id)",
            method: "DELETE"
        ) else { return false }
        do {
            let (_, response) = try await limitedData(
                for: authorized.request,
                session: authorized.session
            )
            return (response as? HTTPURLResponse).map {
                verifiedResponse($0, for: authorized) && 200..<300 ~= $0.statusCode
            } ?? false
        } catch {
            return false
        }
    }

    private static func authorizedRequest(
        path: String,
        method: String = "GET",
        body: Data = Data(),
        contentType: String? = nil
    ) -> AuthorizedRequest? {
        guard let secret = GatewayToken.current else { return nil }
        let nonce = LocalRuntimeChallenge.nonce()
        let proof = LocalRuntimeChallenge.requestProof(
            secret: secret,
            method: method,
            path: path,
            nonce: nonce,
            body: body
        )
        var request = URLRequest(url: base.appendingPathComponent(String(path.dropFirst())))
        request.timeoutInterval = 2
        request.httpMethod = method
        request.httpBody = body.isEmpty ? nil : body
        request.setValue(nonce, forHTTPHeaderField: "X-NexVoice-Nonce")
        request.setValue(proof, forHTTPHeaderField: "X-NexVoice-Proof")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return AuthorizedRequest(
            request: request,
            session: boundedSession(),
            secret: secret,
            nonce: nonce,
            method: method,
            path: path
        )
    }

    private static func verifiedResponse(
        _ response: HTTPURLResponse,
        for authorized: AuthorizedRequest
    ) -> Bool {
        LocalRuntimeChallenge.verify(
            proofBase64: response.value(forHTTPHeaderField: "X-NexVoice-Response-Proof"),
            secret: authorized.secret,
            message: LocalRuntimeChallenge.gatewayResponseMessage(
                method: authorized.method,
                path: authorized.path,
                nonce: authorized.nonce,
                statusCode: response.statusCode
            )
        )
    }

    private static var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/nexvoice", isDirectory: true)
            .appendingPathComponent("vocabulary-cache.json")
    }

    private static func limitedData(
        for request: URLRequest,
        session: URLSession
    ) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        if response.expectedContentLength > Int64(maxPayloadBytes) {
            throw StoreError.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(maxPayloadBytes, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maxPayloadBytes else { throw StoreError.responseTooLarge }
            data.append(byte)
        }
        return (data, response)
    }

    private static func boundedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        return URLSession(configuration: configuration)
    }

    private static func saveCache(_ entries: [VocabEntry]) {
        let url = cacheURL
        guard secureCacheDirectory(url.deletingLastPathComponent()) else { return }
        let envelope = CacheEnvelope(
            schema: cacheSchema,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            entries: VocabularyPolicy.sanitizedEntries(entries)
        )
        guard let data = try? JSONEncoder().encode(envelope),
              data.count <= maxPayloadBytes
        else { return }
        do {
            try writeSecureAtomic(data, to: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func writeSecureAtomic(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".vocabulary-\(UUID().uuidString).tmp")
        var descriptor = temporary.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw posixError() }
        var removeTemporary = true
        defer {
            if descriptor >= 0 { Darwin.close(descriptor) }
            if removeTemporary { temporary.path.withCString { _ = Darwin.unlink($0) } }
        }

        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                offset += written
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
        guard Darwin.close(descriptor) == 0 else { throw posixError() }
        descriptor = -1
        let renamed = temporary.path.withCString { source in
            url.path.withCString { destination in Darwin.rename(source, destination) }
        }
        guard renamed == 0 else { throw posixError() }
        removeTemporary = false
        guard url.path.withCString({ Darwin.chmod($0, mode_t(0o600)) }) == 0 else {
            throw posixError()
        }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private static func secureCacheDirectory(_ url: URL) -> Bool {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue,
                  !isSymbolicLink(url),
                  isOwnedByCurrentUser(url)
            else { return false }
        } else {
            do {
                try manager.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                return false
            }
        }
        do {
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    private static func isSecureRegularFile(_ url: URL) -> Bool {
        guard !isSymbolicLink(url), isOwnedByCurrentUser(url),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0
        else { return false }
        return true
    }

    private static func isOwnedByCurrentUser(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let owner = attributes[.ownerAccountID] as? NSNumber
        else { return false }
        return owner.uint32Value == getuid()
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
