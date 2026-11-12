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

    func testSessionRowsReadTheGatewayShape() throws {
        let j = try JSONDecoder().decode(JSON.self, from: Data(#"{"session_id":"abc","id":"abc","title":" Life ","started_at":1793880294.03,"message_count":293,"model":"m","running":true}"#.utf8))
        let r = try XCTUnwrap(SessionRow(j))
        XCTAssertEqual(r.id, "abc"); XCTAssertEqual(r.title, "Life"); XCTAssertEqual(r.messageCount, 293); XCTAssertTrue(r.running)
        XCTAssertEqual(SessionRow(.object(["session_id": "x", "title": ""]))?.title, "Sans titre")
        XCTAssertNil(SessionRow(.object(["title": "no id"])))
    }
}
