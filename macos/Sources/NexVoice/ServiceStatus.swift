import Foundation

enum HealthState: Equatable {
    case checking
    case healthy
    case unavailable(String)
}

struct ServiceStatus: Equatable, Identifiable {
    let id: String
    let name: String
    let detail: String
    let state: HealthState
    let latencyMilliseconds: Int?

    var isHealthy: Bool { state == .healthy }

    static func checking(_ name: String, detail: String) -> ServiceStatus {
        ServiceStatus(
            id: name,
            name: name,
            detail: detail,
            state: .checking,
            latencyMilliseconds: nil
        )
    }
}

enum ServiceProbe {
    static func check(name: String, detail: String, url: URL, headers: [String: String] = [:]) async -> ServiceStatus {
        let start = ContinuousClock.now
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }

        do {
            let (_, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                return ServiceStatus(
                    id: name,
                    name: name,
                    detail: detail,
                    state: .unavailable("HTTP 回應異常"),
                    latencyMilliseconds: nil
                )
            }
            let duration = start.duration(to: .now)
            let milliseconds = Int(duration.components.seconds * 1_000)
                + Int(duration.components.attoseconds / 1_000_000_000_000_000)
            return ServiceStatus(
                id: name,
                name: name,
                detail: detail,
                state: .healthy,
                latencyMilliseconds: milliseconds
            )
        } catch {
            return ServiceStatus(
                id: name,
                name: name,
                detail: detail,
                state: .unavailable(error.localizedDescription),
                latencyMilliseconds: nil
            )
        }
    }
}

enum CredentialPresence {
    static func nonEmptyFile(at path: String) -> Bool {
        let expanded = NSString(string: path).expandingTildeInPath
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: expanded),
              let size = attributes[.size] as? NSNumber
        else { return false }
        return size.intValue > 0
    }
}
