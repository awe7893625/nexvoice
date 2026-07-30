import Foundation

enum LocalRuntimeConfiguration {
    static let endpointKey = "nexvoice.local.endpoint"
    static let defaultEndpoint = "http://127.0.0.1:5112"

    static var installedModelPath: String? {
        installedPath(named: "model-path")
    }

    static var installedPartialModelPath: String? {
        installedPath(named: "partial-model-path")
    }

    private static func installedPath(named name: String) -> String? {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/nexvoice/runtime/\(name)")
        guard let values = try? file.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let value = try? String(contentsOf: file, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              FileManager.default.fileExists(atPath: value)
        else { return nil }
        return value
    }

    static var endpoint: URL {
        guard let url = URL(string: UserDefaults.standard.string(forKey: endpointKey) ?? defaultEndpoint),
              url.scheme == "http", url.host == "127.0.0.1", url.port == 5112 else {
            return URL(string: defaultEndpoint)!
        }
        return url
    }
}
