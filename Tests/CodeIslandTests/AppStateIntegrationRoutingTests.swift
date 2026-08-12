import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Where the #308 answer-routing fix and the #309 enqueue-gate fix meet.
///
/// Each branch's own suite exercises one side: #308 checks that an action
/// resolves the card's session, #309 checks that a request still raises a card.
/// Neither covers the state where both matter at once — a card left pointing at
/// a session whose request was drained while OTHER sessions still have queued
/// requests.
@MainActor
final class AppStateIntegrationRoutingTests: XCTestCase {

    /// Staleness is per-session, so the enqueue gate must be too. A whole-queue
    /// test reads "a card is on screen" as true whenever any session has a
    /// queued request, which suppresses the stale-card collapse inside
    /// showNextPending() and wedges the panel behind a card that renders
    /// nothing — swallowing every later request.
    func testDrainedCardWithOtherSessionsQueuedDoesNotWedgeThePanel() async throws {
        let appState = AppState()

        // A question from another session occupies the question queue, so the
        // question that arrives in step 3 will not reassign the surface.
        let cTask = Task<Data, Never> {
            await withCheckedContinuation { appState.handleQuestion(try! self.question("s-c"), continuation: $0) }
        }
        await Task.yield()

        let aTask = Task<Data, Never> {
            await withCheckedContinuation { appState.handlePermissionRequest(try! self.perm("s-a", "Bash"), continuation: $0) }
        }
        await Task.yield()
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "s-a"))

        let bTask = Task<Data, Never> {
            await withCheckedContinuation { appState.handlePermissionRequest(try! self.perm("s-b", "Read"), continuation: $0) }
        }
        await Task.yield()

        // A question for s-a drains s-a's permission. s-b's is untouched, so the
        // queue is still non-empty while s-a's card has nothing behind it.
        let aQuestionTask = Task<Data, Never> {
            await withCheckedContinuation { appState.handleQuestion(try! self.question("s-a"), continuation: $0) }
        }
        await Task.yield()
        _ = await aTask.value
        XCTAssertNil(appState.pendingPermission(forSession: "s-a"), "s-a's request is gone")
        XCTAssertFalse(appState.permissionQueue.isEmpty, "and another session is still queued behind it")
        XCTAssertNotEqual(
            appState.surface,
            .approvalCard(sessionId: "s-a"),
            "the drain must not leave the island expanded on a card that renders nothing"
        )

        let dTask = Task<Data, Never> {
            await withCheckedContinuation { appState.handlePermissionRequest(try! self.perm("s-d", "Edit"), continuation: $0) }
        }
        await Task.yield()

        XCTAssertNotEqual(
            appState.surface,
            .approvalCard(sessionId: "s-a"),
            "the dead card must not survive a later request arriving"
        )
        XCTAssertEqual(
            appState.surface,
            .approvalCard(sessionId: "s-b"),
            "the panel must move to the queued request that is actually waiting"
        )

        // Resolve the remaining waiters: an unresumed CheckedContinuation is a
        // runtime misuse warning, and the noise hides real ones.
        appState.handlePeerDisconnect(sessionId: "s-b")
        appState.handlePeerDisconnect(sessionId: "s-d")
        appState.handlePeerDisconnect(sessionId: "s-c")
        appState.handlePeerDisconnect(sessionId: "s-a")
        _ = await bTask.value
        _ = await dTask.value
        _ = await cTask.value
        _ = await aQuestionTask.value
    }

    /// The routing half, exercised on the card the gate just raised: acting on
    /// it must resolve that session, not whatever leads the queue.
    func testCardRaisedAfterADrainResolvesItsOwnSession() async throws {
        let appState = AppState()

        let bTask = Task<Data, Never> {
            await withCheckedContinuation { appState.handlePermissionRequest(try! self.perm("s-b", "Read"), continuation: $0) }
        }
        await Task.yield()
        appState.dismissPermissionPrompt(expectedSessionId: "s-b")
        XCTAssertEqual(appState.surface, .collapsed)

        // A different session's request arrives while s-b sits dismissed.
        let dTask = Task<Data, Never> {
            await withCheckedContinuation { appState.handlePermissionRequest(try! self.perm("s-d", "Edit"), continuation: $0) }
        }
        await Task.yield()
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "s-d"), "#309: the later session still gets a card")

        // Raising the card promoted s-d to the head, so the card and the head
        // agree here. To exercise routing the two must differ — which is the
        // session list's inline approval: the user expands the panel and acts on
        // the dismissed session while a different one leads the queue.
        XCTAssertEqual(appState.permissionQueue.map { $0.event.sessionId }, ["s-d", "s-b"])
        appState.surface = .sessionList
        appState.approvePermission(expectedSessionId: "s-b")

        XCTAssertEqual(
            appState.permissionQueue.map { $0.event.sessionId },
            ["s-d"],
            "the acted-on session must be resolved, not the queue head"
        )
        let bResponse = await bTask.value
        XCTAssertEqual(try extractBehavior(from: bResponse), "allow")

        appState.approvePermission(expectedSessionId: "s-d")
        let dResponse = await dTask.value
        XCTAssertEqual(try extractBehavior(from: dResponse), "allow")
    }

    /// A replay of the same `tool_use_id` is the same decision arriving twice,
    /// not a new one. Clearing the session's dismissal on a replay resurrects
    /// the request the user hid, which then takes the card the arriving session
    /// should have got — and, because it now counts as a burst already in
    /// progress, silences that session's sound too.
    func testReplayOfADismissedRequestDoesNotStealTheNextSessionsCard() async throws {
        let appState = AppState()
        let original = try permWithToolUse("s-replay", "Bash", "tool-1")

        let originalTask = Task<Data, Never> {
            await withCheckedContinuation { appState.handlePermissionRequest(original, continuation: $0) }
        }
        await Task.yield()
        appState.dismissPermissionPrompt(expectedSessionId: "s-replay")
        XCTAssertEqual(appState.surface, .collapsed)

        // The bridge replays the same tool_use_id for the dismissed session.
        let replayTask = Task<Data, Never> {
            await withCheckedContinuation {
                appState.handlePermissionRequest(try! self.permWithToolUse("s-replay", "Bash", "tool-1"), continuation: $0)
            }
        }
        await Task.yield()
        _ = await originalTask.value  // the replay denies the previous waiter
        XCTAssertEqual(appState.permissionQueue.count, 1, "a replay swaps in place, it does not enqueue")
        XCTAssertEqual(appState.surface, .collapsed, "a replay must not resurrect the card the user dismissed")

        let otherTask = Task<Data, Never> {
            await withCheckedContinuation { appState.handlePermissionRequest(try! self.perm("s-other", "Read"), continuation: $0) }
        }
        await Task.yield()

        XCTAssertEqual(
            appState.surface,
            .approvalCard(sessionId: "s-other"),
            "the arriving session must get the card, not the replayed-and-resurrected one"
        )

        appState.approvePermission(expectedSessionId: "s-other")
        let otherResponse = await otherTask.value
        XCTAssertEqual(try extractBehavior(from: otherResponse), "allow")

        appState.handlePeerDisconnect(sessionId: "s-replay")
        _ = await replayTask.value
    }

    /// The other side of the moved un-dismiss: `mergeDuplicatePermissionRequest`
    /// returns false when the tool inputs differ (#169 — parallel tool calls can
    /// share an id), so that request DOES enqueue and must still clear the
    /// dismissal. Moving the un-dismiss must not strand a session as dismissed.
    func testSameToolUseIdWithDifferentInputStillClearsTheDismissal() async throws {
        let appState = AppState()

        let firstTask = Task<Data, Never> {
            await withCheckedContinuation {
                appState.handlePermissionRequest(try! self.permWithToolUse("s-parallel", "Read", "tool-9"), continuation: $0)
            }
        }
        await Task.yield()
        appState.dismissPermissionPrompt(expectedSessionId: "s-parallel")
        XCTAssertEqual(appState.surface, .collapsed)

        // Same tool_use_id, different input: a distinct request, not a replay.
        let secondTask = Task<Data, Never> {
            await withCheckedContinuation {
                appState.handlePermissionRequest(
                    try! self.permWithToolUse("s-parallel", "Read", "tool-9", command: "echo different"),
                    continuation: $0
                )
            }
        }
        await Task.yield()

        XCTAssertEqual(appState.permissionQueue.count, 2, "differing inputs must enqueue, not merge")
        XCTAssertEqual(
            appState.surface,
            .approvalCard(sessionId: "s-parallel"),
            "a genuinely new request must clear the dismissal and bring the card back"
        )

        appState.handlePeerDisconnect(sessionId: "s-parallel")
        _ = await firstTask.value
        _ = await secondTask.value
    }

    // MARK: - Helpers

    private func permWithToolUse(
        _ sessionId: String,
        _ toolName: String,
        _ toolUseId: String,
        command: String = "echo test"
    ) throws -> HookEvent {
        try XCTUnwrap(HookEvent(from: try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PermissionRequest",
            "session_id": sessionId,
            "tool_name": toolName,
            "tool_use_id": toolUseId,
            "tool_input": ["command": command],
        ])))
    }

    private func perm(_ sessionId: String, _ toolName: String) throws -> HookEvent {
        try XCTUnwrap(HookEvent(from: try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PermissionRequest",
            "session_id": sessionId,
            "tool_name": toolName,
            "tool_input": ["command": "echo test"],
        ])))
    }

    private func question(_ sessionId: String) throws -> HookEvent {
        try XCTUnwrap(HookEvent(from: try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Notification",
            "session_id": sessionId,
            "question": "Pick?",
            "options": ["A", "B"],
        ])))
    }

    private func extractBehavior(from data: Data) throws -> String {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let output = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(output["decision"] as? [String: Any])
        return try XCTUnwrap(decision["behavior"] as? String)
    }
}
