import Foundation

/// What the chat screen shows. Events of a turn are folded in one by one; the stored history replaces it when the turn ends.
public struct ChatState: Equatable, Sendable {
    public var messages: [ChatMessage] = []
    public var streaming = false
    public var thinking = false
    /// The assistant's reply while it is being written.
    public var draft = ""
    public var status: String?
    /// Highest bridge sequence number folded in; the next poll asks for events after it.
    public var lastSeq = 0
    private var segments: [Int: String] = [:]

    public init(messages: [ChatMessage] = []) { self.messages = messages }

    public mutating func userSent(_ text: String) {
        messages.append(ChatMessage(role: .user, text: text))
        streaming = true; thinking = true; draft = ""; segments = [:]; status = nil
    }

    /// Events the bridge still holds when a conversation is opened. The stored history already has every finished
    /// turn, so replaying them would show a reply twice: only what follows the last `message.complete` is applied,
    /// the rest just moves the cursor.
    public mutating func resume(from backlog: [BridgeEvent]) {
        let done = backlog.lastIndex { $0.type == "message.complete" }
        for (i, e) in backlog.enumerated() {
            if let done, i <= done { lastSeq = max(lastSeq, e.seq) } else { apply(e) }
        }
    }

    public mutating func apply(_ e: BridgeEvent) {
        lastSeq = max(lastSeq, e.seq)
        switch e.type {
        case "message.start":
            streaming = true; thinking = true; draft = ""; segments = [:]; status = nil
        case "thinking.delta":
            if draft.isEmpty { thinking = true }
        case "message.delta":
            guard let chunk = e.payload["text"].string, !chunk.isEmpty else { return }
            thinking = false; streaming = true
            let seg = e.payload["segment"].int ?? 0
            var cur = segments[seg] ?? ""
            // A delta carries its offset in the segment: a repeated delivery must not write the text twice.
            if let off = e.payload["offset"].int, off < cur.count { cur = String(cur.prefix(off)) }
            cur += chunk
            segments[seg] = cur
            draft = segments.keys.sorted().compactMap { segments[$0] }.joined(separator: "\n\n")
        case "status.update":
            status = e.payload["text"].string
        case "message.complete":
            let final = e.payload["text"].string ?? draft
            if !final.isEmpty { messages.append(ChatMessage(role: .assistant, text: final)) }
            streaming = false; thinking = false; draft = ""; segments = [:]
            if let outcome = e.payload["outcome"].string, outcome != "completed" { status = outcome }
        default:
            if e.type.hasPrefix("tool.") {
                thinking = false
                status = e.payload["name"].string ?? e.payload["tool"].string ?? status
            }
        }
    }
}
