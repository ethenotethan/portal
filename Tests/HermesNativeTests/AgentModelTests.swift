import Testing
import Foundation
@testable import HermesNative

// .serialized: the stored-default tests mutate the same UserDefaults key;
// parallel execution races them against each other (same failure mode the
// ResponseStyle suite hit).
@Suite("Agent Model", .serialized)
struct AgentModelTests {

    @Test("Catalog entries have distinct IDs and non-empty labels")
    func catalogIsWellFormed() {
        let ids = AgentModel.catalog.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(AgentModel.catalog.allSatisfy { !$0.label.isEmpty && !$0.id.isEmpty })
    }

    @Test("Matching ignores the openrouter prefix, case, and whitespace")
    func normalizedMatching() {
        let model = AgentModel(id: "deepseek/deepseek-v4-pro", label: "DeepSeek v4 Pro")
        #expect(model.matches(sessionModel: "deepseek/deepseek-v4-pro"))
        #expect(model.matches(sessionModel: "openrouter/deepseek/deepseek-v4-pro"))
        #expect(model.matches(sessionModel: " DeepSeek/DeepSeek-V4-Pro "))
        #expect(!model.matches(sessionModel: "deepseek/deepseek-v4"))
        #expect(!model.matches(sessionModel: ""))
    }

    @Test("Display name uses the catalog label for known models")
    func displayNameKnown() {
        #expect(AgentModel.displayName(for: "deepseek/deepseek-v4-pro") == "DeepSeek v4 Pro")
        #expect(AgentModel.displayName(for: "openrouter/deepseek/deepseek-v4-pro") == "DeepSeek v4 Pro")
    }

    @Test("Display name compacts unknown models to their last path segment")
    func displayNameUnknown() {
        #expect(AgentModel.displayName(for: "somevendor/mystery-model-9b") == "mystery-model-9b")
        #expect(AgentModel.displayName(for: "openrouter/somevendor/mystery-model-9b") == "mystery-model-9b")
        #expect(AgentModel.displayName(for: "bare-model") == "bare-model")
    }

    @Test("Stored default round-trips through UserDefaults")
    func storedDefaultRoundTrip() {
        let original = UserDefaults.standard.string(forKey: AgentModel.userDefaultsKey)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: AgentModel.userDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AgentModel.userDefaultsKey)
            }
        }

        AgentModel.storedDefaultID = "deepseek/deepseek-v4-pro"
        #expect(AgentModel.storedDefaultID == "deepseek/deepseek-v4-pro")
        AgentModel.storedDefaultID = nil
        #expect(AgentModel.storedDefaultID == nil)
    }

    @Test("Empty stored value reads back as nil (gateway default)")
    func emptyStoredValueIsNil() {
        let original = UserDefaults.standard.string(forKey: AgentModel.userDefaultsKey)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: AgentModel.userDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AgentModel.userDefaultsKey)
            }
        }

        UserDefaults.standard.set("", forKey: AgentModel.userDefaultsKey)
        #expect(AgentModel.storedDefaultID == nil)
    }
}

// MARK: - ChatViewModel model routing

@Suite("ChatViewModel session model routing")
@MainActor
struct ChatViewModelModelRoutingTests {

    private func sessionInfoEvent(model: String) -> GatewayEvent {
        .sessionInfo(SessionInfo(
            model: model,
            reasoningEffort: "",
            fast: false,
            tools: [:],
            skills: [:],
            cwd: "",
            version: "",
            usage: nil,
            mcpServers: nil
        ))
    }

    @Test("session.info for a background session does not clobber the visible session's model")
    func backgroundSessionInfoDoesNotClobber() {
        let vm = ChatViewModel()
        vm.receiveGatewayEventForTesting(sessionInfoEvent(model: "model-a"), sessionID: "session-a")
        // No active session, so the global badge is untouched by a
        // session-scoped event for a session we're not looking at.
        #expect(vm.currentModel.isEmpty)
    }
}
