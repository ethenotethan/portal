import Testing
@testable import Portal

/// The bug these pin down: Portal held a single `ApprovalPayload?` and assigned
/// to it, so a second blocked agent thread overwrote the first. The overwritten
/// request stayed blocked on the gateway until its 60s timeout resolved it as a
/// denial the user never chose and never saw.
@Suite("Approval queue")
internal struct ApprovalQueueTests {
    private func payload(_ command: String, choices: [String] = []) -> ApprovalPayload {
        ApprovalPayload(
            command: command,
            sessionKey: "sess-1",
            toolName: "shell",
            choices: choices
        )
    }

    @Test("a second request queues behind the first instead of replacing it")
    internal func secondRequestQueues() {
        var queue = ApprovalQueue()
        queue.enqueue(payload("git status"))
        queue.enqueue(payload("rm -rf /tmp/build"))

        #expect(queue.count == 2)
        #expect(queue.head?.command == "git status")
        #expect(queue.waitingBehind == 1)
        #expect(queue.upcoming.map(\.command) == ["rm -rf /tmp/build"])
    }

    @Test("answering resolves the oldest, matching the gateway's FIFO pop")
    internal func answeringResolvesOldest() {
        var queue = ApprovalQueue(entries: [payload("first"), payload("second")])

        let resolved = queue.removeHead()

        #expect(resolved?.command == "first")
        // The gateway's resolve_gateway_approval does queue.pop(0), so the
        // client's next visible request must be the one it will resolve next.
        #expect(queue.head?.command == "second")
        #expect(queue.waitingBehind == 0)
    }

    @Test("apply-to-all drains the queue, mirroring respond(all: true)")
    internal func applyToAllDrains() {
        var queue = ApprovalQueue(entries: [payload("a"), payload("b"), payload("c")])

        queue.removeAll()

        #expect(queue.isEmpty)
        #expect(queue.head == nil)
        #expect(queue.upcoming.isEmpty)
    }

    @Test("removing from an empty queue is a no-op, not a crash")
    internal func removeHeadWhenEmpty() {
        var queue = ApprovalQueue()
        #expect(queue.removeHead() == nil)
        #expect(queue.isEmpty)
    }

    @Test("identical commands are kept as separate entries")
    internal func duplicatesAreNotCollapsed() {
        var queue = ApprovalQueue()
        queue.enqueue(payload("curl example.com"))
        queue.enqueue(payload("curl example.com"))

        // Two blocked threads really did ask. Deduplicating by content would
        // answer one and leave the other hanging until its timeout.
        #expect(queue.count == 2)
    }

    @Test("waitingBehind is zero for a single entry so no badge is drawn")
    internal func singleEntryHasNothingBehind() {
        let queue = ApprovalQueue(entries: [payload("ls")])
        #expect(queue.waitingBehind == 0)
        #expect(queue.upcoming.isEmpty)
    }
}

@Suite("Approval wire payload")
internal struct ApprovalPayloadDecodeTests {
    @Test("the gateway's narrowed choices survive decoding")
    internal func decodesChoices() {
        let decoded = ApprovalPayload.from([
            "command": AnyCodable("rm -rf /"),
            "session_key": AnyCodable("sess-9"),
            "tool_name": AnyCodable("shell"),
            "description": AnyCodable("matched dangerous pattern: rm -rf"),
            "choices": .array([AnyCodable("once"), AnyCodable("deny")])
        ])

        #expect(decoded.command == "rm -rf /")
        #expect(decoded.description == "matched dangerous pattern: rm -rf")
        // A smart-denied command offers only once/deny — the banner must not
        // present session/always scopes the gateway would reject.
        #expect(decoded.choices == ["once", "deny"])
    }

    @Test("an older gateway sending no choices decodes to empty, not garbage")
    internal func missingChoicesDecodesEmpty() {
        let decoded = ApprovalPayload.from([
            "command": AnyCodable("git push"),
            "session_key": AnyCodable("sess-9")
        ])

        // Empty is the banner's "offer all four" signal, so this must not be
        // conflated with the gateway deliberately narrowing to nothing.
        #expect(decoded.choices.isEmpty)
        #expect(decoded.description == nil)
    }
}

/// End-to-end through the view model, because the overwrite bug lived in the
/// event handlers rather than in any model type.
@Suite("ChatViewModel approval queueing")
internal struct ChatViewModelApprovalTests {
    private func event(_ command: String) -> GatewayEvent {
        .approvalRequest(payload: ApprovalPayload(command: command, sessionKey: "sess-fg"))
    }

    @Test("two concurrent approval requests both survive in the foreground session")
    @MainActor
    internal func concurrentRequestsBothSurvive() async {
        let vm = ChatViewModel()
        _ = vm.beginSwitchToSession(key: "sess-fg")

        vm.receiveGatewayEventForTesting(event("git status"), sessionID: "sess-fg")
        vm.receiveGatewayEventForTesting(event("rm -rf /tmp/x"), sessionID: "sess-fg")

        #expect(vm.approvalQueue.count == 2)
        // The visible one stays the first-asked; the second is no longer lost.
        #expect(vm.pendingApproval?.command == "git status")
        #expect(vm.approvalQueue.upcoming.map(\.command) == ["rm -rf /tmp/x"])
    }

    @Test("pendingApproval always tracks the head of the queue")
    @MainActor
    internal func pendingApprovalTracksHead() async {
        let vm = ChatViewModel()
        _ = vm.beginSwitchToSession(key: "sess-fg")

        vm.receiveGatewayEventForTesting(event("first"), sessionID: "sess-fg")
        #expect(vm.pendingApproval?.command == "first")

        vm.receiveGatewayEventForTesting(event("second"), sessionID: "sess-fg")
        // Views read `pendingApproval`; if it drifted from the head they would
        // show one command while the answer resolved another.
        #expect(vm.pendingApproval == vm.approvalQueue.head)
    }

    @Test("approvals queued for a background session are not shown in the foreground")
    @MainActor
    internal func backgroundApprovalsStayBackground() async {
        let vm = ChatViewModel()
        _ = vm.beginSwitchToSession(key: "foreground")

        vm.receiveGatewayEventForTesting(event("background command"), sessionID: "other-runtime")

        #expect(vm.approvalQueue.isEmpty)
        #expect(vm.pendingApproval == nil)
    }
}
