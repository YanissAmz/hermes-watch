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

/// A question the dashboard put to this conversation while a turn runs (events `approval.request`, `clarify.request`).
/// The turn waits until someone answers it here or on another device, or until it times out.
public struct OpenRequest: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case approval, clarify }
    /// The dashboard's `prompt_id`.
    public let id: String
    public let kind: Kind
    /// The turn the question belongs to; the answer must name it.
    public let generation: Int
    public let command: String
    public let description: String
    public let question: String
    public let choices: [String]
    public let multiSelect: Bool

    /// Approval choices a watch may give: "always" (a permanent allow-list entry) is left to a bigger screen.
    public static let watchChoices = ["once", "session", "deny"]

    public init(id: String, kind: Kind, generation: Int, command: String = "", description: String = "", question: String = "",
                choices: [String] = [], multiSelect: Bool = false) {
        self.id = id; self.kind = kind; self.generation = generation; self.command = command; self.description = description
        self.question = question; self.choices = choices; self.multiSelect = multiSelect
    }

    init?(_ j: JSON) {
        guard let id = j["prompt_id"].string, let kind = Kind(rawValue: j["kind"].string ?? ""),
              let generation = j["execution_generation"].int else { return nil }
        var choices = j["choices"].array.compactMap(\.string)
        if kind == .approval {
            choices = Self.watchChoices.filter(choices.contains)
            if choices.isEmpty { choices = ["deny"] }
        }
        self.init(id: id, kind: kind, generation: generation, command: j["command"].string ?? "", description: j["description"].string ?? "",
                  question: j["question"].string ?? "", choices: choices, multiSelect: j["multi_select"].bool ?? false)
    }
}
