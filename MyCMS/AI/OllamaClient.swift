import Foundation

// Failures the AI layer reports to the user.
nonisolated enum AIError: LocalizedError {
    case notReachable(underlying: Error)
    case unexpectedStatus(Int)
    case timedOut(seconds: Int)
    case unreadableResponse
    case modelMissing(String)
    case anchorMoved

    var errorDescription: String? {
        switch self {
        case .notReachable(let underlying):
            underlying.localizedDescription
        case .unexpectedStatus(let code):
            "Ollama answered with HTTP status \(code)."
        case .timedOut(let seconds):
            "Ollama did not answer within \(seconds) seconds."
        case .unreadableResponse:
            "Ollama answered with something that was not the expected JSON."
        case .modelMissing(let model):
            "Model \(model) is not installed."
        case .anchorMoved:
            "That text changed since the suggestion was made, so it was not applied."
        }
    }
}

/// The whole conversation with Ollama on this machine, over plain HTTP at `127.0.0.1:11434`.
///
/// Nothing leaves the laptop. `version` and `models` are the availability checks the health screen
/// and the suggestion panel read; `chat` sends one prompt and returns the reply text, asking for
/// JSON when a schema is given. Every call has a timeout and throws `AIError`, which carries the
/// message shown in the panel (not running, model missing, timed out, bad reply).
nonisolated struct OllamaClient: Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    // 127.0.0.1, not localhost: that name resolves to ::1 first, which Ollama refuses, and every
    // request logged the refusal before falling back.
    static let defaultBaseURL = URL(string: "http://127.0.0.1:11434")!

    let baseURL: URL
    private let fetch: Fetch
    private let chatFetch: Fetch

    init(
        baseURL: URL = OllamaClient.defaultBaseURL, fetch: @escaping Fetch = OllamaClient.defaultFetch,
        chatFetch: @escaping Fetch = { try await OllamaClient.chatSession.data(for: $0) }
    ) {
        self.baseURL = baseURL
        self.fetch = fetch
        self.chatFetch = chatFetch
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

    // The running version, for the setup screen's Ollama 0.3.12 running line.
    func version() async throws -> String {
        let payload = try await get(Version.self, path: "api/version")
        return payload.version
    }

    // Which models are pulled, so setup can say whether the one the app expects is there.
    func installedModels() async throws -> [String] {
        try await get(ModelList.self, path: "api/tags").models.map(\.name)
    }

    private func get<T: Decodable>(_ type: T.Type, path: String) async throws -> T {
        let request = URLRequest(url: baseURL.appending(path: path))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await fetch(request)
        } catch {
            throw AIError.notReachable(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else { throw AIError.unexpectedStatus(0) }
        guard http.statusCode == 200 else { throw AIError.unexpectedStatus(http.statusCode) }

        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AIError.unexpectedStatus(http.statusCode)
        }
    }

    private struct Version: Decodable, Sendable {
        let version: String
    }

    private struct ModelList: Decodable, Sendable {
        struct Model: Decodable, Sendable {
            let name: String
        }
        let models: [Model]
    }

    // MARK: Chat, spec 0005 B

    struct Message: Encodable, Sendable {
        let role: String
        let content: String
    }

    struct Options: Encodable, Sendable {
        var temperature: Double
        // AC-19. Ollama's default window is smaller and would cut a long post off silently.
        var num_ctx = 8192
    }

    // AC-19 and AC-68. One non streaming request with a JSON schema, carrying its own timeout so a
    // server that never answers releases the caller rather than holding it forever.
    func chat(
        model: String, messages: [Message], format: JSONValue, temperature: Double,
        timeout: TimeInterval
    ) async throws -> String {
        struct Body: Encodable {
            let model: String
            let messages: [Message]
            let format: JSONValue
            let options: Options
            let keep_alive: String
            let stream: Bool
        }
        struct Reply: Decodable {
            struct Content: Decodable { let content: String }
            let message: Content
        }

        var request = URLRequest(url: baseURL.appending(path: "api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try JSONEncoder().encode(
            Body(
                model: model, messages: messages, format: format,
                options: Options(temperature: temperature), keep_alive: "10m", stream: false))
        let sealed = request

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
                group.addTask { [chatFetch] in try await chatFetch(sealed) }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw AIError.timedOut(seconds: Int(timeout))
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch let error as AIError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw AIError.timedOut(seconds: Int(timeout))
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw AIError.notReachable(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else { throw AIError.unexpectedStatus(0) }
        guard http.statusCode == 200 else {
            if http.statusCode == 404 { throw AIError.modelMissing(model) }
            throw AIError.unexpectedStatus(http.statusCode)
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw AIError.unreadableResponse }
        return reply.message.content
    }

    // Its own session, because a chat may take a minute while the probes keep their two seconds.
    static let chatSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    // The model the app expects when nothing has been chosen yet, from Notes section 2.
    static let defaultModel = "llama3.2:3b"

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

// Any JSON value, which is how a schema written as JSON text travels in `format` untouched.
nonisolated indirect enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(parsing text: String) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
