import Foundation

struct LocalRuntimeManifest: Codable, Equatable, Sendable {
    let schema: Int
    let contractVersion: Int
    let runtimeBuild: String

    enum CodingKeys: String, CodingKey {
        case schema
        case contractVersion = "contract_version"
        case runtimeBuild = "runtime_build"
    }
}

struct LocalRuntimeIdentity: Codable, Equatable, Sendable {
    let status: String
    let authenticated: Bool
    let contractVersion: Int
    let runtimeBuild: String
    let instanceID: String
    let ownerNonce: String
    let parentPID: Int?
    let mlxWhisperVersion: String?
    let capabilities: [String]
    let responseProof: String?

    enum CodingKeys: String, CodingKey {
        case status
        case authenticated
        case contractVersion = "contract_version"
        case runtimeBuild = "runtime_build"
        case instanceID = "instance_id"
        case ownerNonce = "owner_nonce"
        case parentPID = "parent_pid"
        case mlxWhisperVersion = "mlx_whisper_version"
        case capabilities
        case responseProof = "response_proof"
    }
}

enum LocalRuntimeProbeResult: Equatable, Sendable {
    case unavailable(String)
    case recognized(identity: LocalRuntimeIdentity, matchesExpectedBuild: Bool)
    case occupied(String)
}

enum LocalRuntimeContract {
    static let expectedContractVersion = 2
    static let maxResponseBytes = 16 * 1_024
    static let bundledManifest = loadBundledManifest()

    static func decodeManifest(_ data: Data) -> LocalRuntimeManifest? {
        guard let manifest = try? JSONDecoder().decode(LocalRuntimeManifest.self, from: data),
              manifest.schema == 1,
              manifest.contractVersion == expectedContractVersion,
              isBuildID(manifest.runtimeBuild)
        else { return nil }
        return manifest
    }

    static func probe(
        expected manifest: LocalRuntimeManifest? = bundledManifest,
        timeout: TimeInterval = 1.5
    ) async -> LocalRuntimeProbeResult {
        guard let manifest else {
            return .occupied("App bundle 缺少 runtime contract")
        }
        guard let secret = LocalRuntimeToken.current else {
            return .occupied("本機憑證檔案不安全或無法建立，已停用本機 runtime")
        }
        let url = LocalRuntimeConfiguration.endpoint.appendingPathComponent("health")
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let nonce = LocalRuntimeChallenge.nonce()
        request.setValue(nonce, forHTTPHeaderField: "X-NexVoice-Local-Nonce")
        request.setValue(
            LocalRuntimeChallenge.requestProof(
                secret: secret, method: "GET", path: url.path, nonce: nonce, body: Data()
            ),
            forHTTPHeaderField: "X-NexVoice-Local-Proof"
        )

        do {
            let (data, response) = try await limitedData(for: request, timeout: timeout)
            guard let http = response as? HTTPURLResponse else {
                return .occupied("5112 回應不是 HTTP")
            }
            guard 200..<300 ~= http.statusCode else {
                return .occupied(
                    http.statusCode == 401
                        ? "5112 已被不同權杖的服務占用"
                        : "本機 runtime HTTP \(http.statusCode)"
                )
            }
            guard let identity = try? JSONDecoder().decode(LocalRuntimeIdentity.self, from: data),
                  identity.status == "ok",
                  identity.authenticated,
                  identity.contractVersion >= expectedContractVersion,
                  isBuildID(identity.runtimeBuild),
                  UUID(uuidString: identity.instanceID) != nil,
                  !identity.ownerNonce.isEmpty,
                  identity.capabilities.contains("identity-v1"),
                  identity.capabilities.contains("challenge-response-v1"),
                  LocalRuntimeChallenge.verify(
                      proofBase64: identity.responseProof,
                      secret: secret,
                      message: LocalRuntimeChallenge.healthResponseMessage(nonce: nonce, identity: identity)
                  )
            else {
                // Format-valid but unproven (or outright wrong) identity: this is
                // exactly the port-squatter-impersonation case (P0-E). A listener
                // without read access to the token file cannot produce a response
                // that passes the HMAC check above, no matter how plausible its
                // build/instance/owner fields look.
                return .occupied("偵測到舊版或未知的 NexVoice runtime")
            }
            return .recognized(
                identity: identity,
                matchesExpectedBuild: identity.contractVersion == manifest.contractVersion
                    && identity.runtimeBuild == manifest.runtimeBuild
            )
        } catch let error as URLError where [
            .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
            .cannotFindHost, .timedOut
        ].contains(error.code) {
            return .unavailable(error.localizedDescription)
        } catch {
            return .occupied("無法驗證 5112：\(error.localizedDescription)")
        }
    }

    static func requestShutdown(_ identity: LocalRuntimeIdentity) async -> Bool {
        guard identity.capabilities.contains("shutdown-v1"),
              isBuildID(identity.runtimeBuild),
              UUID(uuidString: identity.instanceID) != nil,
              !identity.ownerNonce.isEmpty,
              let secret = LocalRuntimeToken.current
        else { return false }

        let url = LocalRuntimeConfiguration.endpoint.appendingPathComponent("control/shutdown")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try? JSONEncoder().encode(
            ShutdownRequest(
                instanceID: identity.instanceID,
                runtimeBuild: identity.runtimeBuild,
                ownerNonce: identity.ownerNonce
            )
        )
        guard let body else { return false }
        request.httpBody = body
        let nonce = LocalRuntimeChallenge.nonce()
        request.setValue(nonce, forHTTPHeaderField: "X-NexVoice-Local-Nonce")
        request.setValue(
            LocalRuntimeChallenge.requestProof(
                secret: secret, method: "POST", path: url.path, nonce: nonce, body: body
            ),
            forHTTPHeaderField: "X-NexVoice-Local-Proof"
        )

        do {
            let (data, response) = try await limitedData(for: request, timeout: 2)
            guard (response as? HTTPURLResponse)?.statusCode == 202,
                  let ack = try? JSONDecoder().decode(ShutdownAck.self, from: data),
                  ack.instanceID == identity.instanceID,
                  LocalRuntimeChallenge.verify(
                      proofBase64: ack.responseProof,
                      secret: secret,
                      message: LocalRuntimeChallenge.shutdownResponseMessage(
                          nonce: nonce, instanceID: identity.instanceID
                      )
                  )
            else { return false }
            return true
        } catch {
            return false
        }
    }

    private struct ShutdownRequest: Encodable {
        let instanceID: String
        let runtimeBuild: String
        let ownerNonce: String

        enum CodingKeys: String, CodingKey {
            case instanceID = "instance_id"
            case runtimeBuild = "runtime_build"
            case ownerNonce = "owner_nonce"
        }
    }

    private struct ShutdownAck: Decodable {
        let status: String
        let instanceID: String
        let responseProof: String?

        enum CodingKeys: String, CodingKey {
            case status
            case instanceID = "instance_id"
            case responseProof = "response_proof"
        }
    }

    private static func loadBundledManifest() -> LocalRuntimeManifest? {
        guard let url = Bundle.main.url(
            forResource: "runtime-contract",
            withExtension: "json",
            subdirectory: "NexVoiceRuntime"
        ), let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
        else { return nil }
        return decodeManifest(data)
    }

    private static func isBuildID(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else { return false }
        let digest = value.dropFirst("sha256:".count)
        return digest.count == 64 && digest.allSatisfy { $0.isHexDigit }
    }

    private static func limitedData(
        for request: URLRequest,
        timeout: TimeInterval
    ) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 0.5
        let (bytes, response) = try await URLSession(configuration: configuration).bytes(for: request)
        var data = Data()
        data.reserveCapacity(1_024)
        for try await byte in bytes {
            guard data.count < maxResponseBytes else { throw VoiceAPIError.responseTooLarge }
            data.append(byte)
        }
        return (data, response)
    }
}
