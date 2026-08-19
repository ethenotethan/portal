import Foundation

// Client surface for the gateway's read-only file browser (`files.list` /
// `files.read`). User-initiated fetches, so every call goes through
// `callWithRetry` — a stale socket after wake-from-idle transparently
// reconnects and retries once instead of hanging the browser on "Loading…".

extension GatewayClient {
    /// The available browsable root names (e.g. `["hermes", "repo"]`).
    /// Sent with no `root` param, which the gateway answers with the root set.
    internal func fileRoots() async throws -> [String] {
        let response = try await callWithRetry("files.list")
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let roots = response.result?.dictionaryValue?["roots"]?.arrayValue else {
            throw GatewayError.invalidResponse("files.list missing roots")
        }
        return roots.compactMap { $0.stringValue }
    }

    /// List one directory level under a root. `path` empty lists the root's
    /// top level; pass a directory's relative path to descend one level.
    internal func listFiles(root: String, path: String = "") async throws -> FileListing {
        var params: [String: AnyCodable] = ["root": AnyCodable(root)]
        if !path.isEmpty { params["path"] = AnyCodable(path) }
        let response = try await callWithRetry("files.list", params: params)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let dict = response.result?.dictionaryValue else {
            throw GatewayError.invalidResponse("files.list missing result")
        }
        return FileListing.from(dict, requestedRoot: root)
    }

    /// Read one UTF-8 text file under a root. Binary and oversize files are
    /// refused by the gateway (surfaced as `GatewayError.rpcError`).
    internal func readFile(root: String, path: String) async throws -> FileContent {
        let response = try await callWithRetry("files.read", params: [
            "root": AnyCodable(root),
            "path": AnyCodable(path),
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let dict = response.result?.dictionaryValue else {
            throw GatewayError.invalidResponse("files.read missing result")
        }
        return FileContent.from(dict, requestedRoot: root, requestedPath: path)
    }
}
