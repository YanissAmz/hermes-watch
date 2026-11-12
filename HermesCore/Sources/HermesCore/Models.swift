import Foundation

public struct SessionRow: Identifiable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var startedAt: Date?
    public var messageCount: Int
    public var model: String
    public var running: Bool

    public init(id: String, title: String, startedAt: Date? = nil, messageCount: Int = 0, model: String = "", running: Bool = false) {
        self.id = id; self.title = title; self.startedAt = startedAt; self.messageCount = messageCount; self.model = model; self.running = running
    }

    init?(_ j: JSON) {
        guard let id = j["session_id"].string ?? j["id"].string else { return nil }
        let title = (j["title"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(id: id, title: title.isEmpty ? "Sans titre" : title, startedAt: j["started_at"].double.map(Date.init(timeIntervalSince1970:)),
                  messageCount: j["message_count"].int ?? 0, model: j["model"].string ?? "", running: j["running"].bool ?? false)
    }
}

public struct ChatMessage: Identifiable, Equatable, Sendable {
    public enum Role: String, Sendable { case user, assistant, other }
    public let id: String
    public var role: Role
    public var text: String

    public init(id: String = UUID().uuidString, role: Role, text: String) {
        self.id = id; self.role = role; self.text = text
    }
}

public struct ProviderOption: Identifiable, Equatable, Sendable {
    public var id: String { slug }
    public let slug: String
    public let name: String
    public let isCurrent: Bool
    public let models: [String]
}

/// The models a conversation can use, and the one it uses now.
public struct ModelChoices: Equatable, Sendable {
    public var model: String
    public var provider: String
    public var providers: [ProviderOption]

    public init(model: String = "", provider: String = "", providers: [ProviderOption] = []) {
        self.model = model; self.provider = provider; self.providers = providers
    }

    public func isCurrent(_ name: String, in option: ProviderOption) -> Bool { name == model && option.slug == provider }
}

/// One event of a running turn, as the bridge hands it over: its own sequence number, the gateway's type and payload.
public struct BridgeEvent: Equatable, Sendable {
    public let seq: Int
    public let type: String
    public let payload: JSON

    public init(seq: Int, type: String, payload: JSON = .null) {
        self.seq = seq; self.type = type; self.payload = payload
    }
}
