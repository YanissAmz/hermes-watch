import Foundation
import HermesCore
import SwiftUI

/// The app's state: where the bridge is, the list of conversations, and the conversation on screen.
@MainActor
final class AppModel: ObservableObject {
    @Published var sessions: [SessionRow] = []
    @Published var loadingSessions = false
    @Published var listError: String?

    @Published var chat = ChatState()
    @Published var chatError: String?
    @Published var loadingChat = false
    @Published var choices = ModelChoices()
    @Published var creating = false

    /// The conversation on screen. Only its follower may write `chat`; sending and stopping go to it too.
    private(set) var followedID: String?
    private var follower: Task<Void, Never>?

    @AppStorage("bridgeURL") var bridgeURL: String = Bundle.main.object(forInfoDictionaryKey: "HermesBridgeURL") as? String ?? ""
    @AppStorage("bridgeToken") var bridgeToken: String = Bundle.main.object(forInfoDictionaryKey: "HermesBridgeToken") as? String ?? ""

    private var client: BridgeClient? {
        guard let url = URL(string: bridgeURL.trimmingCharacters(in: .whitespaces)), url.scheme != nil else { return nil }
        return BridgeClient(config: .init(baseURL: url, token: bridgeToken))
    }

    func refreshSessions() async {
        guard let client else { listError = L("Open Settings and enter the address and token of your bridge."); return }
        loadingSessions = sessions.isEmpty
        defer { loadingSessions = false }
        do {
            sessions = try await client.sessions()
            listError = nil
        } catch is CancellationError {
        } catch {
            listError = L(error.localizedDescription)
        }
    }

    /// One creation at a time: a second tap while the first is still on its way must not open a second conversation.
    func newSession() async -> SessionRow? {
        guard let client, !creating else { return nil }
        creating = true
        defer { creating = false }
        do {
            let id = try await client.createSession()
            let row = SessionRow(id: id, title: L("New conversation"))
            sessions.insert(row, at: 0)
            return row
        } catch {
            listError = error.localizedDescription
            return nil
        }
    }

    /// Shows a conversation: loads it, then follows its events until another one is opened or `close` is called.
    /// The model owns the follower, so the screen, the sender and the follower can never be on different conversations.
    func open(_ session: SessionRow) {
        guard followedID != session.id || follower == nil else { return }
        follower?.cancel()
        followedID = session.id
        chat = ChatState(); chatError = nil; choices = ModelChoices(); loadingChat = true
        follower = Task { [weak self] in await self?.follow(session) }
    }

    func close(_ session: SessionRow) {
        guard followedID == session.id else { return }
        follower?.cancel(); follower = nil; followedID = nil
    }

    private func follow(_ session: SessionRow) async {
        guard let client else { loadingChat = false; return }
        func mine() -> Bool { followedID == session.id && !Task.isCancelled }
        do {
            let stored = try await client.history(session.id)
            guard mine() else { return }
            if !chat.streaming {              // a message sent while the history was loading stays on screen
                chat.messages = stored
                chat.streaming = session.running
            }
            loadingChat = false
            // What the bridge still holds for this conversation: finished turns are already in the stored history.
            let sentMeanwhile = chat.streaming && !session.running
            let backlog = try await client.events(sessionID: session.id, after: chat.lastSeq, wait: 0)
            guard mine() else { return }
            chat.resume(from: backlog)
            if sentMeanwhile, chat.streaming, backlog.contains(where: { $0.type == "message.complete" }) {
                await catchUp(session, client)      // the message sent while loading was already answered
            }
            let options = (try? await client.modelOptions(sessionID: session.id)) ?? ModelChoices()
            guard mine() else { return }
            choices = options
            while mine() {
                let events = try await client.events(sessionID: session.id, after: chat.lastSeq, wait: 20)
                guard mine() else { return }
                let wasStreaming = chat.streaming
                for e in events { chat.apply(e) }
                if wasStreaming, !chat.streaming, let stored = try? await client.history(session.id), !stored.isEmpty, mine() {
                    chat.messages = stored          // the stored turn is the reference once it has ended
                }
                if events.isEmpty, chat.streaming { await catchUp(session, client) }
                chatError = nil
            }
        } catch is CancellationError {
        } catch {
            guard mine() else { return }
            loadingChat = false
            chatError = L(error.localizedDescription)
        }
    }

    /// A whole poll went by without an event while a reply was expected: the events may have been missed (the watch slept,
    /// the bridge restarted). Ask Hermes whether the turn is still running and, if not, show what it stored.
    private func catchUp(_ session: SessionRow, _ client: BridgeClient) async {
        guard let running = try? await client.isRunning(sessionID: session.id), !running,
              let stored = try? await client.history(session.id), followedID == session.id else { return }
        if stored.last?.role == .assistant || stored.count > chat.messages.count { chat.messages = stored }
        chat.streaming = false; chat.thinking = false; chat.draft = ""
    }

    func send(_ text: String, in session: SessionRow) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, !text.isEmpty else { return }
        open(session)                         // the reply is followed where the message goes
        chat.userSent(text)
        do {
            try await client.submit(sessionID: session.id, text: text)
        } catch is CancellationError {
            chat.streaming = false; chat.thinking = false
            chatError = L("Sending interrupted")
        } catch {
            chat.streaming = false; chat.thinking = false
            chatError = String(format: L("Not sent: %@"), L(error.localizedDescription))
        }
    }

    func stop(_ session: SessionRow) async {
        try? await client?.interrupt(sessionID: session.id)
    }

    func pick(model: String, provider: ProviderOption, in session: SessionRow) async {
        guard let client else { return }
        do {
            try await client.setModel(sessionID: session.id, model: model, provider: provider.slug)
            choices = try await client.modelOptions(sessionID: session.id)
        } catch {
            chatError = error.localizedDescription
        }
    }

    func testConnection() async -> String {
        guard let client else { return L("Invalid address") }
        do {
            return try await client.health() ? L("Connected") : L("The bridge cannot reach Hermes")
        } catch {
            return L(error.localizedDescription)
        }
    }
}

/// Looks a string up in the catalog at run time (error texts and other values that are not literals in a view).
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }
