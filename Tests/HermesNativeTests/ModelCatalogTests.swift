import Testing
import Foundation
@testable import HermesNative

@Suite("Model Catalog")
struct ModelCatalogTests {

    /// Decode helper: JSON string → AnyCodable dictionary, the same shape a
    /// JSON-RPC result reaches ModelCatalog.from as.
    private func result(_ json: String) -> [String: AnyCodable] {
        return try! JSONDecoder().decode(
            [String: AnyCodable].self, from: json.data(using: .utf8)!
        )
    }

    @Test("Decodes the model.options payload shape")
    func decodesPayload() {
        let payload = result("""
        {
          "providers": [
            {"slug": "nous", "name": "Nous", "is_current": true,
             "models": ["nousresearch/hermes-4-405b", "nousresearch/hermes-4-70b"],
             "total_models": 2, "authenticated": true},
            {"slug": "openrouter", "name": "OpenRouter", "is_current": false,
             "models": ["minimax/minimax-m2.5"], "total_models": 1, "authenticated": true},
            {"slug": "xai", "name": "xAI", "is_current": false,
             "models": [], "total_models": 0, "authenticated": false,
             "warning": "set XAI_API_KEY"}
          ],
          "model": "nousresearch/hermes-4-405b",
          "provider": "nous"
        }
        """)
        let catalog = ModelCatalog.from(payload)
        #expect(catalog != nil)
        #expect(catalog?.providers.count == 3)
        #expect(catalog?.currentModel == "nousresearch/hermes-4-405b")
        #expect(catalog?.currentProvider == "nous")
        // Unauthenticated/empty providers are excluded from the pickable set.
        #expect(catalog?.selectableProviders.map(\.slug) == ["nous", "openrouter"])
        #expect(catalog?.allModelIDs.contains("minimax/minimax-m2.5") == true)
    }

    @Test("Rows without the picker_hints authenticated flag count as authenticated")
    func missingAuthFlagDefaultsTrue() {
        let payload = result("""
        {"providers": [{"slug": "nous", "name": "Nous",
          "models": ["nousresearch/hermes-4-70b"]}], "model": "", "provider": ""}
        """)
        let catalog = ModelCatalog.from(payload)
        #expect(catalog?.selectableProviders.count == 1)
    }

    @Test("Empty or malformed payloads return nil (static catalog fallback)")
    func malformedReturnsNil() {
        #expect(ModelCatalog.from(result("{\"model\": \"x\"}")) == nil)
        #expect(ModelCatalog.from(result("{\"providers\": []}")) == nil)
        // A row without a slug is dropped; all dropped → nil.
        #expect(ModelCatalog.from(result("{\"providers\": [{\"name\": \"NoSlug\"}]}")) == nil)
    }

    @Test("Switch outcome decodes confirmation gates and warnings")
    func switchOutcome() {
        let gated = ModelSwitchOutcome.from(result("""
        {"key": "model", "value": "openai/o3-pro", "warning": "",
         "confirm_required": true, "confirm_message": "o3-pro is $120/Mtok. Continue?"}
        """))
        #expect(gated.confirmRequired)
        #expect(gated.confirmMessage.contains("$120"))

        let accepted = ModelSwitchOutcome.from(result("""
        {"key": "model", "value": "deepseek/deepseek-v4-pro", "warning": "pricing unknown",
         "confirm_required": false, "confirm_message": ""}
        """))
        #expect(!accepted.confirmRequired)
        #expect(accepted.value == "deepseek/deepseek-v4-pro")
        #expect(accepted.warning == "pricing unknown")

        // Absent result (old gateway shape) degrades to a plain acceptance.
        let bare = ModelSwitchOutcome.from(nil)
        #expect(!bare.confirmRequired)
    }
}
