import XCTest
@testable import HermesCore

final class ChatStateTests: XCTestCase {
    private func delta(_ seq: Int, _ text: String, segment: Int = 0, offset: Int) -> BridgeEvent {
        BridgeEvent(seq: seq, type: "message.delta", payload: .object(["text": .string(text), "segment": .number(Double(segment)), "offset": .number(Double(offset))]))
    }

    func testATurnStreamsThenLandsAsOneAssistantMessage() {
        var s = ChatState()
        s.userSent("Bonjour")
        XCTAssertTrue(s.streaming); XCTAssertTrue(s.thinking)
        s.apply(BridgeEvent(seq: 1, type: "message.start"))
        s.apply(BridgeEvent(seq: 2, type: "thinking.delta", payload: .object(["text": "mulling"])))
        s.apply(delta(3, "Sal", offset: 0))
        XCTAssertFalse(s.thinking)
        s.apply(delta(4, "ut", offset: 3))
        XCTAssertEqual(s.draft, "Salut")
        s.apply(BridgeEvent(seq: 5, type: "message.complete", payload: .object(["text": .null, "outcome": "completed"])))
        XCTAssertFalse(s.streaming)
        XCTAssertEqual(s.messages.map(\.text), ["Bonjour", "Salut"])
        XCTAssertEqual(s.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(s.draft, ""); XCTAssertNil(s.status); XCTAssertEqual(s.lastSeq, 5)
    }

    func testReopeningAConversationDoesNotShowAFinishedReplyTwice() {
        // The stored history has the turn; the bridge still holds its events from a moment ago.
        var s = ChatState(messages: [ChatMessage(role: .user, text: "Hi"), ChatMessage(role: .assistant, text: "Hello")])
        s.resume(from: [BridgeEvent(seq: 1, type: "message.start"), delta(2, "Hello", offset: 0),
                        BridgeEvent(seq: 3, type: "message.complete", payload: .object(["text": .null, "outcome": "completed"]))])
        XCTAssertEqual(s.messages.map(\.text), ["Hi", "Hello"])
        XCTAssertFalse(s.streaming); XCTAssertEqual(s.draft, ""); XCTAssertEqual(s.lastSeq, 3)
    }

    func testReopeningDuringATurnShowsOnlyTheRunningTurn() {
        var s = ChatState(messages: [ChatMessage(role: .user, text: "Hi"), ChatMessage(role: .assistant, text: "Hello"), ChatMessage(role: .user, text: "More")])
        s.resume(from: [BridgeEvent(seq: 1, type: "message.start"), delta(2, "Hello", offset: 0),
                        BridgeEvent(seq: 3, type: "message.complete", payload: .object(["text": .null, "outcome": "completed"])),
                        BridgeEvent(seq: 4, type: "message.start"), delta(5, "Sure", offset: 0)])
        XCTAssertEqual(s.messages.count, 3)
        XCTAssertTrue(s.streaming); XCTAssertEqual(s.draft, "Sure"); XCTAssertEqual(s.lastSeq, 5)
    }

    func testADeltaDeliveredTwiceIsNotWrittenTwice() {
        var s = ChatState()
        s.apply(delta(1, "Sal", offset: 0))
        s.apply(delta(2, "ut", offset: 3))
        s.apply(delta(3, "ut", offset: 3))
        XCTAssertEqual(s.draft, "Salut")
    }

    func testSegmentsAfterAToolCallAreJoinedInOrder() {
        var s = ChatState()
        s.apply(delta(1, "Je regarde.", segment: 0, offset: 0))
        s.apply(BridgeEvent(seq: 2, type: "tool.start", payload: .object(["name": "terminal"])))
        XCTAssertEqual(s.status, "terminal")
        s.apply(delta(3, "Voilà.", segment: 1, offset: 0))
        XCTAssertEqual(s.draft, "Je regarde.\n\nVoilà.")
    }

    func testAnInterruptedTurnShowsItsOutcome() {
        var s = ChatState()
        s.apply(delta(1, "Début", offset: 0))
        s.apply(BridgeEvent(seq: 2, type: "message.complete", payload: .object(["outcome": "interrupted"])))
        XCTAssertEqual(s.messages.last?.text, "Début")
        XCTAssertEqual(s.status, "interrupted")
        XCTAssertFalse(s.streaming)
    }

    private func approval(_ seq: Int, _ id: String, generation: Int = 1) -> BridgeEvent {
        BridgeEvent(seq: seq, type: "approval.request", payload: .object([
            "kind": "approval", "prompt_id": .string(id), "execution_generation": .number(Double(generation)), "command": "rm -rf build",
            "description": "recursive delete", "choices": .array(["once", "deny", "session", "always"])]))
    }

    func testAnApprovalShowsUntilItIsSettled() {
        var s = ChatState()
        s.apply(BridgeEvent(seq: 1, type: "message.start"))
        s.apply(approval(2, "p1", generation: 3))
        s.apply(approval(3, "p1", generation: 3))      // delivered twice: still one card
        XCTAssertEqual(s.requests.map(\.id), ["p1"])
        XCTAssertEqual(s.requests[0].kind, .approval); XCTAssertEqual(s.requests[0].generation, 3)
        XCTAssertEqual(s.requests[0].command, "rm -rf build")
        XCTAssertEqual(s.requests[0].choices, ["once", "session", "deny"])   // "always" never offered on the wrist
        s.apply(BridgeEvent(seq: 4, type: "clarify.request", payload: .object([
            "kind": "clarify", "prompt_id": "c1", "execution_generation": 3, "question": "Which branch?",
            "choices": .array(["main", "dev"]), "multi_select": false])))
        s.apply(BridgeEvent(seq: 5, type: "approval.settled", payload: .object(["prompt_id": "p1", "execution_generation": 3])))
        XCTAssertEqual(s.requests.map(\.id), ["c1"]); XCTAssertEqual(s.requests[0].question, "Which branch?")
        XCTAssertEqual(s.requests[0].choices, ["main", "dev"])
        s.answered("c1")
        XCTAssertTrue(s.requests.isEmpty)
        s.apply(approval(6, "p2"))
        s.apply(BridgeEvent(seq: 7, type: "message.complete", payload: .object(["text": "done", "outcome": "completed"])))
        XCTAssertTrue(s.requests.isEmpty)               // a finished turn has no question left
    }

    func testReopeningShowsOnlyTheRunningTurnsApproval() {
        var s = ChatState()
        s.resume(from: [approval(1, "old"), BridgeEvent(seq: 2, type: "message.complete", payload: .object(["outcome": "completed"])),
                        BridgeEvent(seq: 3, type: "message.start"), approval(4, "now")])
        XCTAssertEqual(s.requests.map(\.id), ["now"])
    }

    func testSessionRowsReadTheGatewayShape() throws {
        let j = try JSONDecoder().decode(JSON.self, from: Data(#"{"session_id":"abc","id":"abc","title":" Life ","started_at":1793880294.03,"message_count":293,"model":"m","running":true}"#.utf8))
        let r = try XCTUnwrap(SessionRow(j))
        XCTAssertEqual(r.id, "abc"); XCTAssertEqual(r.title, "Life"); XCTAssertEqual(r.messageCount, 293); XCTAssertTrue(r.running)
        XCTAssertEqual(SessionRow(.object(["session_id": "x", "title": ""]))?.title, "Sans titre")
        XCTAssertNil(SessionRow(.object(["title": "no id"])))
    }
}
