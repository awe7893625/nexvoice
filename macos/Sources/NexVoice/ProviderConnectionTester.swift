import Foundation

enum ProviderConnectionTester {
    private static func succeeds(_ request: URLRequest) async -> Bool {
        var request = request
        request.timeoutInterval = 6
        do {
            let (_, response) = try await LocalHTTP.data(for: request, maxBytes: 1_048_576)
            guard let http = response as? HTTPURLResponse else { return false }
            return 200..<300 ~= http.statusCode
        } catch {
            return false
        }
    }

    static func localRuntime() async -> Bool {
        if case .recognized(_, let matchesExpectedBuild) = await LocalRuntimeContract.probe() {
            return matchesExpectedBuild
        }
        return false
    }

    static func groq() async -> Bool {
        guard let key = SecretStore.secret(named: ".groq_key"),
              let url = URL(string: "https://api.groq.com/openai/v1/models")
        else { return false }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await succeeds(request)
    }

    static func gemini() async -> Bool {
        guard let key = SecretStore.secret(named: ".gemini_key"),
              var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")
        else { return false }
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        guard let url = components.url else { return false }
        return await succeeds(URLRequest(url: url))
    }
}
