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

    func newSession() async -> SessionRow? {
        guard let client else { return nil }
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

    /// Loads a conversation, then follows its events until the screen goes away (the task is cancelled).
    func follow(_ session: SessionRow) async {
        guard let client else { return }
        chat = ChatState(); chatError = nil; choices = ModelChoices(); loadingChat = true
        do {
            chat.messages = try await client.history(session.id)
            chat.streaming = session.running
            loadingChat = false
            choices = (try? await client.modelOptions(sessionID: session.id)) ?? ModelChoices()
            while !Task.isCancelled {
                let events = try await client.events(sessionID: session.id, after: chat.lastSeq, wait: 20)
                let wasStreaming = chat.streaming
                for e in events { chat.apply(e) }
                if wasStreaming, !chat.streaming, let stored = try? await client.history(session.id), !stored.isEmpty {
                    chat.messages = stored          // the stored turn is the reference once it has ended
                }
                chatError = nil
            }
        } catch is CancellationError {
        } catch {
            loadingChat = false
            chatError = L(error.localizedDescription)
        }
    }

    func send(_ text: String, in session: SessionRow) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, !text.isEmpty else { return }
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
