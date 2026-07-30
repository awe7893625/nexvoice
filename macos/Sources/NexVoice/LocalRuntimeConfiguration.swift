import Foundation

enum LocalRuntimeConfiguration {
    static let modelKey = "nexvoice.local.model"
    static let endpointKey = "nexvoice.local.endpoint"
    static let defaultModel = "mlx-community/whisper-large-v3-turbo"
    static let defaultEndpoint = "http://127.0.0.1:5112"

    static var model: String {
        let value = UserDefaults.standard.string(forKey: modelKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value! : defaultModel
    }

    static var endpoint: URL {
        guard let url = URL(string: UserDefaults.standard.string(forKey: endpointKey) ?? defaultEndpoint),
              url.scheme == "http", url.host == "127.0.0.1", url.port == 5112 else {
            return URL(string: defaultEndpoint)!
        }
        return url
    }
}
