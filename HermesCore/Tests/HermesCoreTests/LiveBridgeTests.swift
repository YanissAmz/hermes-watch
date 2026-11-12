import XCTest
@testable import HermesCore

/// Runs against the real bridge and a real model turn. Enabled with HERMES_BRIDGE_LIVE=1; the created session id is
/// written to HERMES_BRIDGE_SID_FILE so the caller can delete it.
final class LiveBridgeTests: XCTestCase {
    func testAFullTurnOverHTTP() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["HERMES_BRIDGE_LIVE"] == "1", "live test off")
        let client = BridgeClient(config: .init(baseURL: URL(string: env["HERMES_BRIDGE_URL"] ?? "http://127.0.0.1:9120")!, token: env["HERMES_BRIDGE_TOKEN"] ?? ""))
        let healthy = try await client.health()
        XCTAssertTrue(healthy)
        do {
            _ = try await BridgeClient(config: .init(baseURL: client.config.baseURL, token: "wrong")).rpc("session.list")
            XCTFail("a wrong token must be refused")
        } catch { XCTAssertEqual(error as? BridgeError, .http(401)) }

        let rows = try await client.sessions(limit: 10)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "no session listed twice")

        let sid = try await client.createSession()
        if let f = env["HERMES_BRIDGE_SID_FILE"] { try? sid.write(toFile: f, atomically: true, encoding: .utf8) }
        let choices = try await client.modelOptions(sessionID: sid)
        XCTAssertFalse(choices.model.isEmpty)
        let current = try XCTUnwrap(choices.providers.first { $0.slug == choices.provider }, "the current provider is in the list")
        XCTAssertTrue(current.models.contains(choices.model), "the current model is one of its provider's models")

        // Pick another model for this conversation, check it took, put the first one back.
        if let other = choices.providers.lazy.flatMap({ p in p.models.map { (model: $0, provider: p.slug) } })
            .first(where: { $0.model != choices.model || $0.provider != choices.provider }) {
            try await client.setModel(sessionID: sid, model: other.model, provider: other.provider)
            let after = try await client.modelOptions(sessionID: sid)
            XCTAssertEqual(after.model, other.model); XCTAssertEqual(after.provider, other.provider)
            try await client.setModel(sessionID: sid, model: choices.model, provider: choices.provider)
            let back = try await client.modelOptions(sessionID: sid)
            XCTAssertEqual(back.model, choices.model)
        }

        var state = ChatState()
        state.userSent("Reply with this single word only: dial")
        try await client.submit(sessionID: sid, text: "Reply with this single word only: dial")
        let deadline = Date().addingTimeInterval(120)
        while state.streaming, Date() < deadline {
            for e in try await client.events(sessionID: sid, after: state.lastSeq, wait: 10) { state.apply(e) }
        }
        XCTAssertFalse(state.streaming, "the turn must end")
        XCTAssertTrue(state.messages.last?.text.lowercased().contains("dial") ?? false, "got: \(state.messages.last?.text ?? "nothing")")

        let history = try await client.history(sid)
        XCTAssertEqual(history.map(\.role).prefix(2), [.user, .assistant])

        // Stop a long turn from the client.
        state.userSent("long")
        try await client.submit(sessionID: sid, text: "Write the numbers from 1 to 400, one per line, nothing else.")
        var stopped = false
        let stopDeadline = Date().addingTimeInterval(60)
        while state.streaming, Date() < stopDeadline {
            for e in try await client.events(sessionID: sid, after: state.lastSeq, wait: 5) { state.apply(e) }
            if !stopped, !state.draft.isEmpty { try await client.interrupt(sessionID: sid); stopped = true }
        }
        XCTAssertTrue(stopped, "the turn wrote something before the stop")
        XCTAssertFalse(state.streaming, "a stopped turn ends")
        XCTAssertEqual(state.status, "cancelled")
    }
}
