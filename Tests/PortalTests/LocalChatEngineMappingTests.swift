#if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(HuggingFace) && canImport(Tokenizers) && os(macOS)
import MLXLMCommon
import Testing
@testable import Portal

/// Pins the two places a model's identity is written down.
///
/// `LocalChatModel.repositoryID` exists so the ML-free layers — the cache scanner,
/// Settings — can name a repo without importing MLX, which means the string is
/// duplicated from the registry configuration the engine actually downloads. If
/// they drift, everything still compiles and still works; the only symptom is a
/// model that is sitting on disk being described as a multi-gigabyte download
/// forever. Cheap to catch here, invisible otherwise.
@Suite("Local chat engine model mapping")
internal struct LocalChatEngineMappingTests {

    @Test("each case's repo ID is the repo the engine loads")
    internal func repositoryIDsMatchTheRegistry() {
        for model in LocalChatModel.allCases {
            #expect(MLXLocalChatEngine.configuration(for: model).name == model.repositoryID)
        }
    }
}
#endif
