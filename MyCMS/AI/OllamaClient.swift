import Foundation

// Failures the AI layer reports to the user.
nonisolated enum AIError: LocalizedError {
    case notReachable(underlying: Error)
    case unexpectedStatus(Int)

    var errorDescription: String? {
        switch self {
        case .notReachable(let underlying):
            underlying.localizedDescription
        case .unexpectedStatus(let code):
            "Ollama answered with HTTP status \(code)."
        }
    }
}

// Talks to Ollama on localhost. Feature 8 grows this into the real client.
nonisolated struct OllamaClient: Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let defaultBaseURL = URL(string: "http://localhost:11434")!

    let baseURL: URL
    private let fetch: Fetch

    init(baseURL: URL = OllamaClient.defaultBaseURL, fetch: @escaping Fetch = OllamaClient.defaultFetch) {
        self.baseURL = baseURL
        self.fetch = fetch
    }

    // Asks for the model list, which is the cheapest proof that Ollama is running.
    func checkReachable() async throws -> String {
        let request = URLRequest(url: baseURL.appending(path: "api/tags"))

        let response: URLResponse
        do {
            (_, response) = try await fetch(request)
        } catch {
            throw AIError.notReachable(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AIError.unexpectedStatus(0)
        }
        guard http.statusCode == 200 else {
            throw AIError.unexpectedStatus(http.statusCode)
        }
        return "Ollama is running at \(baseURL.absoluteString)"
    }

    // A dedicated session, because the two second limit belongs to this check only.
    static let defaultFetch: Fetch = { request in
        try await shortTimeoutSession.data(for: request)
    }

    private static let shortTimeoutSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}
