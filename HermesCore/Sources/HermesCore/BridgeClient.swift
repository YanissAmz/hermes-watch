import Foundation

public struct BridgeConfig: Equatable, Sendable {
    public var baseURL: URL
    public var token: String
    public init(baseURL: URL, token: String) { self.baseURL = baseURL; self.token = token }
}

public enum BridgeError: Error, Equatable, LocalizedError {
    case http(Int)
    case rpc(String)
    case transport(String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .http(401): return "Token refused"
        case .http(502): return "Hermes is not answering"
        case .http(let c): return "Error \(c)"
        case .rpc(let m): return m
        case .transport(let m): return m
        case .badResponse: return "Unreadable response"
        }
    }
}

/// Talks to the watch bridge with plain HTTP requests, the only networking a real watch allows outside audio streaming.
public final class BridgeClient: @unchecked Sendable {
    public let config: BridgeConfig
    private let session: URLSession

    public init(config: BridgeConfig, session: URLSession? = nil) {
        self.config = config
        if let session {
            self.session = session
        } else {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 75
            self.session = URLSession(configuration: c)
        }
    }

    private func send(_ path: String, query: [URLQueryItem] = [], body: JSON? = nil, timeout: TimeInterval = 60) async throws -> JSON {
        var comps = URLComponents(url: config.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { comps?.queryItems = query }
        guard let url = comps?.url else { throw BridgeError.badResponse }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch let e as CancellationError { throw e } catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw BridgeError.transport(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw BridgeError.badResponse }
        guard http.statusCode == 200 else { throw BridgeError.http(http.statusCode) }
        guard let json = try? JSONDecoder().decode(JSON.self, from: data) else { throw BridgeError.badResponse }
        return json
    }

    public func rpc(_ method: String, _ params: [String: JSON] = [:]) async throws -> JSON {
        let reply = try await send("rpc", body: .object(["method": .string(method), "params": .object(params)]))
        if !reply["error"].isNull {
            throw BridgeError.rpc(reply["error"]["message"].string ?? "Erreur Hermes")
        }
        return reply["result"]
    }

    public func health() async throws -> Bool {
        try await send("health", timeout: 20)["ok"].bool ?? false
    }

    /// Long poll: returns as soon as the session has events after `after`, or empty after `wait` seconds.
    public func events(sessionID: String, after: Int, wait: Int = 20) async throws -> [BridgeEvent] {
        let r = try await send("events", query: [.init(name: "session_id", value: sessionID), .init(name: "after", value: String(after)),
                                                 .init(name: "wait", value: String(wait))], timeout: TimeInterval(wait + 20))
        return r["events"].array.compactMap { e in
            guard let seq = e["seq"].int, let type = e["type"].string else { return nil }
            return BridgeEvent(seq: seq, type: type, payload: e["payload"])
        }
    }

    /// Open conversations first, then the stored ones, without repeats.
    public func sessions(limit: Int = 30) async throws -> [SessionRow] {
        async let live = rpc("session.list", [:])
        async let stored = rpc("session.list", ["scope": "stored", "limit": .number(Double(limit))])
        var seen = Set<String>(), rows: [SessionRow] = []
        for j in try await live["sessions"].array + stored["sessions"].array {
            if let r = SessionRow(j), seen.insert(r.id).inserted { rows.append(r) }
        }
        return rows
    }

    public func createSession() async throws -> String {
        guard let id = try await rpc("session.create", [:])["session_id"].string else { throw BridgeError.badResponse }
        return id
    }

    public func history(_ sessionID: String) async throws -> [ChatMessage] {
        try await rpc("session.history", ["session_id": .string(sessionID)])["messages"].array.compactMap { m in
            guard let text = m["text"].string, !text.isEmpty else { return nil }
            let role = ChatMessage.Role(rawValue: m["role"].string ?? "") ?? .other
            guard role != .other else { return nil }
            return ChatMessage(id: m["row_id"].int.map(String.init) ?? UUID().uuidString, role: role, text: text)
        }
    }

    public func submit(sessionID: String, text: String) async throws {
        _ = try await rpc("prompt.submit", ["session_id": .string(sessionID), "text": .string(text),
                                            "submission_id": .string(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())])
    }

    /// The session's current revision and turn generation: the gateway refuses a stop or a model pick that names stale ones.
    private func fence(_ sessionID: String) async throws -> (revision: JSON, generation: JSON) {
        let snap = try await rpc("session.resume", ["session_id": .string(sessionID)])
        return (snap["revision"], snap["execution_generation"])
    }

    public func interrupt(sessionID: String) async throws {
        let f = try await fence(sessionID)
        _ = try await rpc("session.interrupt", ["session_id": .string(sessionID), "execution_generation": f.generation])
    }

    public func modelOptions(sessionID: String) async throws -> ModelChoices {
        let r = try await rpc("model.options", ["session_id": .string(sessionID)])
        let providers: [ProviderOption] = r["providers"].array.compactMap { p in
            guard let slug = p["slug"].string else { return nil }
            return ProviderOption(slug: slug, name: p["name"].string ?? slug, isCurrent: p["is_current"].bool ?? false,
                                  models: p["models"].array.compactMap(\.string))
        }
        return ModelChoices(model: r["model"].string ?? "", provider: r["provider"].string ?? providers.first(where: \.isCurrent)?.slug ?? "",
                            providers: providers)
    }

    /// Changes the model of this conversation only (`session.mutate`); the default model is not touched.
    public func setModel(sessionID: String, model: String, provider: String) async throws {
        let f = try await fence(sessionID)
        let r = try await rpc("session.mutate", [
            "session_id": .string(sessionID), "request_id": .string(UUID().uuidString), "operation": "model",
            "payload": .object(["model": .string(model), "provider": .string(provider)]),
            "expected_revision": f.revision, "expected_generation": f.generation,
        ])
        if r["status"].string == "confirmation_required" {
            throw BridgeError.rpc("This model asks for a confirmation: pick it from the desktop or phone app")
        }
    }
}
