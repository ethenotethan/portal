import Foundation

// MARK: - Declarations

/// One parameter a query accepts, as the artifact declares it.
///
/// The artifact's schema describes what the *page* may vary; the handler's own
/// schema (held by the gateway) is authoritative and an artifact can only
/// narrow it. This mirror exists so a bad value is refused here, with a reason
/// the page author can read, before a round trip is spent on it.
internal struct ArtifactQueryParam: Equatable, Sendable {
    internal enum Kind: String, Sendable {
        case string, int, number, bool, `enum`, cursor
    }

    internal let kind: Kind
    internal let required: Bool
    internal let min: Double?
    internal let max: Double?
    internal let values: [String]
    internal let defaultValue: AnyCodable?

    /// Coerce and bound one supplied value, or explain why it can't be.
    internal func validate(_ name: String, _ value: Any) throws -> AnyCodable {
        switch kind {
        case .bool:
            if let flag = value as? Bool { return .bool(flag) }
            if let text = value as? String, ["true", "false", "1", "0"].contains(text.lowercased()) {
                return .bool(["true", "1"].contains(text.lowercased()))
            }
            throw ArtifactQueryError.badParameter(name, "expected a boolean")
        case .int:
            guard !(value is Bool) else { throw ArtifactQueryError.badParameter(name, "expected an integer") }
            let number: Int
            if let whole = value as? Int {
                number = whole
            } else if let text = value as? String, let parsed = Int(text) {
                number = parsed
            } else if let real = value as? Double, real == real.rounded() {
                number = Int(real)
            } else {
                throw ArtifactQueryError.badParameter(name, "expected an integer")
            }
            try bound(name, Double(number))
            return .int(number)
        case .number:
            guard !(value is Bool) else { throw ArtifactQueryError.badParameter(name, "expected a number") }
            let number: Double
            if let real = value as? Double {
                number = real
            } else if let whole = value as? Int {
                number = Double(whole)
            } else if let text = value as? String, let parsed = Double(text) {
                number = parsed
            } else {
                throw ArtifactQueryError.badParameter(name, "expected a number")
            }
            guard number.isFinite else { throw ArtifactQueryError.badParameter(name, "expected a finite number") }
            try bound(name, number)
            return .double(number)
        case .string, .enum, .cursor:
            guard let text = value as? String else {
                throw ArtifactQueryError.badParameter(name, "expected a string")
            }
            if text.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\t" && $0 != "\n" }) {
                throw ArtifactQueryError.badParameter(name, "control characters are not allowed")
            }
            switch kind {
            case .enum:
                guard values.contains(text) else {
                    throw ArtifactQueryError.badParameter(name, "must be one of \(values.joined(separator: ", "))")
                }
            case .cursor:
                guard text.utf8.count <= 512 else { throw ArtifactQueryError.badParameter(name, "cursor too long") }
            default:
                let limit = Int(max ?? 1_024)
                guard text.count <= limit else {
                    throw ArtifactQueryError.badParameter(name, "longer than \(limit) characters")
                }
            }
            return .string(text)
        }
    }

    private func bound(_ name: String, _ number: Double) throws {
        if let min, number < min { throw ArtifactQueryError.badParameter(name, "below minimum \(Self.render(min))") }
        if let max, number > max { throw ArtifactQueryError.badParameter(name, "above maximum \(Self.render(max))") }
    }

    private static func render(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : String(number)
    }

    /// Parse one schema entry. Unknown types drop the entry — a page can't be
    /// validated against a type nobody understands, and the gateway will say so.
    internal static func parse(_ raw: Any?) -> ArtifactQueryParam? {
        guard let dict = raw as? [String: Any] else { return nil }
        let kindName = (dict["type"] as? String)?.lowercased() ?? "string"
        guard let kind = Kind(rawValue: kindName) else { return nil }
        return ArtifactQueryParam(
            kind: kind,
            required: (dict["required"] as? Bool) ?? false,
            min: Self.number(dict["min"]),
            max: Self.number(dict["max"]),
            values: (dict["values"] as? [Any])?.compactMap { $0 as? String } ?? [],
            defaultValue: dict["default"].map { AnyCodable(any: $0) }
        )
    }

    private static func number(_ raw: Any?) -> Double? {
        if let real = raw as? Double { return real }
        if let whole = raw as? Int { return Double(whole) }
        return nil
    }
}

/// How a declared query stays current: on a cadence the gateway polls at, or
/// only when a plugin says the data moved. Absent means one-shot.
internal enum ArtifactQueryLive: Equatable, Sendable {
    case poll(intervalSeconds: Double)
    case subscribe
}

/// A query an artifact's page may run, as declared on the artifact record.
///
/// Read-side twin of the `intent` `ArtifactAction`: the artifact names a
/// registered handler and constrains its parameters; it never carries query
/// text. `bind` fixes values the page cannot change; `params` narrows what it
/// can; `invalidatedBy` names the intents whose success makes this stale.
internal struct ArtifactQuery: Equatable, Identifiable, Sendable {
    internal let id: String
    internal let handler: String
    internal let bind: [String: AnyCodable]
    internal let params: [String: ArtifactQueryParam]
    /// True when the artifact declared a `params` object (even an empty one):
    /// an undeclared schema passes page values straight to the handler's.
    internal let declaresParams: Bool
    internal let live: ArtifactQueryLive?
    internal let invalidatedBy: [String]

    internal var isLive: Bool { live != nil }

    /// The page's parameters, checked and coerced the way the gateway will
    /// check them: a bound key may not be overridden, and only declared keys
    /// may appear. The gateway remains the source of truth — this is what lets
    /// the page see *why* before a round trip.
    internal func validate(_ supplied: [String: Any]) throws -> [String: AnyCodable] {
        var remaining = supplied
        for (key, value) in bind {
            if let given = remaining.removeValue(forKey: key), AnyCodable(any: given) != value {
                throw ArtifactQueryError.badParameter(key, "is bound by the artifact and cannot be overridden")
            }
        }
        var out: [String: AnyCodable] = [:]
        if declaresParams {
            let unknown = Set(remaining.keys).subtracting(params.keys).sorted()
            if let first = unknown.first {
                throw ArtifactQueryError.badParameter(first, "is not a parameter of this query")
            }
            for (name, spec) in params {
                if let value = remaining[name] {
                    out[name] = try spec.validate(name, value)
                } else if let fallback = spec.defaultValue {
                    out[name] = fallback
                } else if spec.required {
                    throw ArtifactQueryError.badParameter(name, "is required")
                }
            }
        } else {
            for (name, value) in remaining { out[name] = AnyCodable(any: value) }
        }
        for (key, value) in bind { out[key] = value }
        return out
    }

    /// Parse the `queries` array of an artifact record. Malformed entries drop
    /// silently here — the gateway refused them at write time, so anything
    /// reaching this parser is either well-formed or from an older store.
    internal static func parse(_ value: Any?) -> [ArtifactQuery] {
        guard let raw = value as? [Any] else { return [] }
        return raw.compactMap { entry -> ArtifactQuery? in
            guard let dict = entry as? [String: Any],
                  let id = (dict["id"] as? String)?.trimmingCharacters(in: .whitespaces), !id.isEmpty,
                  let handler = (dict["query"] as? String)?.trimmingCharacters(in: .whitespaces), !handler.isEmpty
            else { return nil }
            let bind = (dict["bind"] as? [String: Any])?.mapValues { AnyCodable(any: $0) } ?? [:]
            let rawParams = dict["params"] as? [String: Any]
            let params = rawParams?.reduce(into: [String: ArtifactQueryParam]()) { acc, pair in
                if let spec = ArtifactQueryParam.parse(pair.value) { acc[pair.key] = spec }
            } ?? [:]
            return ArtifactQuery(
                id: id,
                handler: handler,
                bind: bind,
                params: params,
                declaresParams: rawParams != nil,
                live: parseLive(dict["live"]),
                invalidatedBy: (dict["invalidated_by"] as? [Any])?.compactMap { $0 as? String } ?? []
            )
        }
    }

    private static func parseLive(_ raw: Any?) -> ArtifactQueryLive? {
        guard let dict = raw as? [String: Any] else { return nil }
        let mode = (dict["mode"] as? String)?.lowercased() ?? "poll"
        switch mode {
        case "off": return nil
        case "subscribe": return .subscribe
        default:
            let interval = (dict["interval_s"] as? Double) ?? (dict["interval_s"] as? Int).map(Double.init) ?? 30
            return .poll(intervalSeconds: interval)
        }
    }
}

internal enum ArtifactQueryError: Error, Equatable, LocalizedError {
    case badParameter(String, String)
    case notJSONObject

    internal var errorDescription: String? {
        switch self {
        case .badParameter(let name, let why): return "parameter \(name) \(why)"
        case .notJSONObject: return "data-hermes-params is not a JSON object"
        }
    }
}

// MARK: - Gateway result

/// What `artifact.query.invoke` / `artifact.query.subscribe` returned.
internal struct ArtifactQueryResult: Equatable {
    internal enum Outcome: Equatable {
        /// `data` is the JSON payload; `etag` identifies it for change diffing.
        case ok(data: AnyCodable, etag: String, nextCursor: String?)
        /// A parameter the gateway refused, a handler error, an oversize
        /// result, or a rate limit — the reason is for the page author.
        case failed(reason: String)
        /// The artifact moved on since the page rendered; refresh and retry.
        case conflict
        /// No such declaration, or its handler isn't loaded.
        case unsupported(reason: String)
    }

    internal let outcome: Outcome
    /// Handle for `artifact.query.unsubscribe`; present on subscribe results.
    internal let subscription: String?

    internal static func from(_ d: [String: AnyCodable]?) -> ArtifactQueryResult {
        guard let d else { return .init(outcome: .unsupported(reason: "empty response"), subscription: nil) }
        let subscription = d["subscription"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        switch d["status"]?.stringValue ?? "" {
        case "ok":
            return .init(
                outcome: .ok(
                    data: d["data"] ?? .null,
                    etag: d["etag"]?.stringValue ?? "",
                    nextCursor: d["next_cursor"]?.stringValue
                ),
                subscription: subscription
            )
        case "failed":
            return .init(outcome: .failed(reason: d["reason"]?.stringValue ?? "Query failed"), subscription: nil)
        case "conflict":
            return .init(outcome: .conflict, subscription: nil)
        default:
            return .init(
                outcome: .unsupported(reason: d["reason"]?.stringValue ?? "Query not supported"),
                subscription: nil
            )
        }
    }
}

// MARK: - Page <-> native bridge

/// A page's request to run one of its artifact's declared queries.
///
/// Carries the `query_id` from the manifest and the page's raw
/// `data-hermes-params` text — nothing else. Never a handler name, never
/// query text. The raw text is kept verbatim (not parsed here) because it is
/// also the key the result is written back under: the element that asked is
/// the element whose attributes match.
internal struct HTMLArtifactQueryRequest: Equatable, Sendable {
    internal static let scheme = "hermes-artifact-query"
    internal static let host = "request"
    internal static let maxParamsBytes = 2_048
    /// Mirrors the gateway's `MAX_CURSOR` (`tui_gateway/artifact_queries.py`):
    /// an over-long cursor is refused here so the page hears why without a round
    /// trip. A cursor is opaque paging state minted by the handler, never
    /// authored by the page as data.
    internal static let maxCursorBytes = 512

    internal let queryID: String
    internal let rawParams: String
    /// The page's `data-hermes-cursor`, forwarded verbatim as the invoke
    /// `cursor` argument. Empty means the first page. Kept distinct from
    /// `rawParams` so paging state never perturbs the base query's subscription
    /// key or etag.
    internal let rawCursor: String

    internal init(queryID: String, rawParams: String = "", rawCursor: String = "") {
        self.queryID = queryID
        self.rawParams = rawParams
        self.rawCursor = rawCursor
    }

    internal init?(url: URL, expectedNonce: String) {
        guard url.scheme?.lowercased() == Self.scheme,
              url.host?.lowercased() == Self.host,
              !expectedNonce.isEmpty,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let allowedNames = Set(["query_id", "params", "cursor", "nonce"])
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard allowedNames.contains(item.name), let value = item.value, values[item.name] == nil else {
                return nil
            }
            values[item.name] = value
        }
        guard let queryID = values["query_id"], Self.isValidQueryID(queryID) else { return nil }
        // Same per-webview capability as the intent bridge: page JavaScript
        // cannot mint a request by navigating to the scheme itself.
        guard values["nonce"] == expectedNonce else { return nil }
        let rawParams = values["params"] ?? ""
        guard rawParams.utf8.count <= Self.maxParamsBytes,
              !rawParams.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\t" && $0 != "\n" }) else {
            return nil
        }
        let rawCursor = values["cursor"] ?? ""
        guard rawCursor.utf8.count <= Self.maxCursorBytes,
              !rawCursor.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\t" && $0 != "\n" }) else {
            return nil
        }
        self.init(queryID: queryID, rawParams: rawParams, rawCursor: rawCursor)
    }

    /// The page's parameters as a JSON object, or an error the page can read.
    internal func parameters() throws -> [String: Any] {
        let trimmed = rawParams.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        guard let data = trimmed.data(using: .utf8) else { throw ArtifactQueryError.notJSONObject }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            // Malformed JSON and non-object JSON are the same mistake to the
            // page author, and the same one-line reason tells them which attribute.
            throw ArtifactQueryError.notJSONObject
        }
        guard let object = parsed as? [String: Any] else { throw ArtifactQueryError.notJSONObject }
        return object
    }

    private static func isValidQueryID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "._:-".unicodeScalars.contains($0)
        }
    }
}

/// Narrow bridge for the read side: the page declares what it wants with inert
/// attributes; native runs the query and writes **data** back.
///
/// Page -> native is a `MutationObserver` in the same isolated content world
/// as the intent bridge, watching `data-hermes-query` / `data-hermes-params`
/// and forwarding each distinct request over the nonce'd private scheme.
/// Native -> page writes the JSON result as `textContent` of a
/// `<script type="application/json" data-hermes-sink>` inside the element,
/// stamps `data-hermes-query-status`, and dispatches a plain `hermes-data`
/// event. Never `innerHTML`, never evaluation: the page's own JavaScript
/// renders what it reads out of the sink.
internal enum HTMLArtifactQueryBridge {
    /// Shares the intent bridge's world so both scripts see one scope and the
    /// page sees neither.
    internal static let contentWorldName = HTMLArtifactIntentBridge.contentWorldName

    /// The fixed vocabulary stamped onto `data-hermes-query-status`.
    internal enum StatusToken: String, CaseIterable, Sendable {
        case loading
        case ok
        case failed
        case unsupported
    }

    /// One element's reflected result. `Equatable` so the host diffs and only
    /// re-runs JS for slots that changed.
    internal struct ResultMark: Equatable, Sendable {
        internal let queryID: String
        internal let rawParams: String
        /// The `data-hermes-cursor` this result answers. Matched on write so a
        /// page that advanced its cursor doesn't receive a stale page's data.
        internal let rawCursor: String
        internal let status: StatusToken
        /// JSON text for the sink; nil leaves whatever the page had.
        internal let payload: String?
        /// Reason for `failed` / `unsupported`, bounded and control-free.
        internal let error: String?
        /// The handler's `next_cursor`, stamped onto `data-hermes-query-next-cursor`
        /// so the page can request the following page. nil clears the attribute
        /// (no more pages).
        internal let nextCursor: String?

        internal init(
            queryID: String, rawParams: String, rawCursor: String = "", status: StatusToken,
            payload: String? = nil, error: String? = nil, nextCursor: String? = nil
        ) {
            self.queryID = queryID
            self.rawParams = rawParams
            self.rawCursor = rawCursor
            self.status = status
            self.payload = payload
            self.error = error.map(HTMLArtifactQueryBridge.boundedReason)
            self.nextCursor = nextCursor.map(HTMLArtifactQueryBridge.boundedCursor)
        }
    }

    internal static let maxReasonLength = 256

    /// Error text is gateway- or validator-authored prose. It lands only as an
    /// attribute value (inert), but it is still bounded and stripped of
    /// control characters so nothing unexpected can ride along.
    internal static func boundedReason(_ reason: String) -> String {
        let clean = reason.unicodeScalars.filter { $0.value >= 32 }.map(Character.init)
        return String(String(clean).prefix(maxReasonLength))
    }

    /// A `next_cursor` is gateway-minted opaque text that lands only as an inert
    /// attribute value, but it is still stripped of control characters and
    /// bounded to the same limit the request side enforces, so nothing
    /// unexpected can ride along and a well-behaved handler round-trips intact.
    internal static func boundedCursor(_ cursor: String) -> String {
        let clean = cursor.unicodeScalars.filter { $0.value >= 32 }.map(Character.init)
        return String(String(clean).prefix(HTMLArtifactQueryRequest.maxCursorBytes))
    }

    internal static func userScriptSource(nonce: String) -> String {
        let nonceLiteral = jsStringLiteral(nonce)
        return #"""
    (() => {
      'use strict';
      const nonce = \#(nonceLiteral);
      const prefix = '\#(HTMLArtifactQueryRequest.scheme)://\#(HTMLArtifactQueryRequest.host)?';
      const maxParams = \#(HTMLArtifactQueryRequest.maxParamsBytes);
      const maxCursor = \#(HTMLArtifactQueryRequest.maxCursorBytes);
      const last = new WeakMap();
      const queue = [];
      let scheduled = false;

      // One private-scheme navigation per turn of the event loop: several in
      // the same tick would coalesce into whichever came last, and a
      // dashboard with five slots would render one.
      function flush() {
        scheduled = false;
        const next = queue.shift();
        if (next === undefined) return;
        window.location.href = next;
        if (queue.length) { scheduled = true; setTimeout(flush, 30); }
      }
      function enqueue(url) {
        queue.push(url);
        if (!scheduled) { scheduled = true; setTimeout(flush, 0); }
      }

      function request(node) {
        if (!(node instanceof Element)) return;
        const id = (node.getAttribute('data-hermes-query') || '').trim();
        if (!/^[A-Za-z0-9._:-]{1,128}$/.test(id)) return;
        const params = node.getAttribute('data-hermes-params') || '';
        if (new TextEncoder().encode(params).length > maxParams) return;
        // Opaque paging state minted by the handler's previous next_cursor;
        // empty is the first page. Distinct from params so advancing the page
        // re-fires without touching the base query's identity.
        const cursor = node.getAttribute('data-hermes-cursor') || '';
        if (new TextEncoder().encode(cursor).length > maxCursor) return;
        const key = id + ' ' + params + ' ' + cursor;
        if (last.get(node) === key) return;
        last.set(node, key);
        const query = new URLSearchParams({ query_id: id, nonce: nonce });
        if (params) query.set('params', params);
        if (cursor) query.set('cursor', cursor);
        enqueue(prefix + query.toString());
      }

      function scan(root) {
        if (!(root instanceof Element)) return;
        if (root.hasAttribute('data-hermes-query')) request(root);
        for (const node of root.querySelectorAll('[data-hermes-query]')) request(node);
      }

      new MutationObserver((records) => {
        for (const record of records) {
          if (record.type === 'attributes') request(record.target);
          for (const added of record.addedNodes) scan(added);
        }
      }).observe(document.documentElement, {
        subtree: true, childList: true, attributes: true,
        attributeFilter: ['data-hermes-query', 'data-hermes-params', 'data-hermes-cursor'],
      });
      scan(document.documentElement);
    })();
    """#
    }

    /// JavaScript that writes one slot's result into the page, run in the same
    /// isolated world as `userScriptSource`. Matches elements on query id AND
    /// the exact `data-hermes-params` text, so two slots on the same query with
    /// different parameters don't cross-talk. Every value is JSON-encoded into
    /// the script, and the payload reaches the DOM only as `textContent` of an
    /// `application/json` script — which the browser never executes.
    internal static func resultScript(_ mark: ResultMark) -> String {
        let id = jsStringLiteral(mark.queryID)
        let params = jsStringLiteral(mark.rawParams)
        let cursor = jsStringLiteral(mark.rawCursor)
        let status = jsStringLiteral(mark.status.rawValue)
        let payload = mark.payload.map(jsStringLiteral) ?? "null"
        let error = mark.error.map(jsStringLiteral) ?? "null"
        let nextCursor = mark.nextCursor.map(jsStringLiteral) ?? "null"
        return #"""
    (() => {
      'use strict';
      const id = \#(id);
      const params = \#(params);
      const cursor = \#(cursor);
      const status = \#(status);
      const payload = \#(payload);
      const error = \#(error);
      const nextCursor = \#(nextCursor);
      for (const node of document.querySelectorAll('[data-hermes-query]')) {
        if ((node.getAttribute('data-hermes-query') || '').trim() !== id) continue;
        if ((node.getAttribute('data-hermes-params') || '') !== params) continue;
        // A result answers the exact cursor it was fetched for; a node that has
        // since advanced its cursor must not be overwritten by the older page.
        if ((node.getAttribute('data-hermes-cursor') || '') !== cursor) continue;
        node.setAttribute('data-hermes-query-status', status);
        if (error === null) {
          node.removeAttribute('data-hermes-query-error');
        } else {
          node.setAttribute('data-hermes-query-error', error);
        }
        if (nextCursor === null) {
          node.removeAttribute('data-hermes-query-next-cursor');
        } else {
          node.setAttribute('data-hermes-query-next-cursor', nextCursor);
        }
        if (payload !== null) {
          let sink = node.querySelector(':scope > script[type="application/json"][data-hermes-sink]');
          if (!sink) {
            sink = document.createElement('script');
            sink.type = 'application/json';
            sink.setAttribute('data-hermes-sink', '');
            node.prepend(sink);
          }
          sink.textContent = payload;
          node.dispatchEvent(new Event('hermes-data', { bubbles: true }));
        }
      }
    })();
    """#
    }

    /// The JSON text a page will read out of its sink, in a stable key order
    /// so identical data compares equal across renders.
    internal static func payloadText(_ data: AnyCodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return String(data: try encoder.encode(data), encoding: .utf8) ?? "null"
        } catch {
            // AnyCodable encodes every case it can hold; reaching here means a
            // payload the gateway never should have produced. `null` is a
            // valid sink value the page can branch on, unlike nothing.
            return "null"
        }
    }

    private static func jsStringLiteral(_ value: String) -> String {
        do {
            let data = try JSONEncoder().encode(value)
            return String(data: data, encoding: .utf8) ?? "\"\""
        } catch {
            return "\"\""
        }
    }
}

// MARK: - AnyCodable bridging

extension AnyCodable {
    /// The Foundation value this tree represents, for parsers written against
    /// `Any` (`ArtifactAction.parse`, `ArtifactQuery.parse`).
    internal var foundationValue: Any? {
        switch self {
        case .string(let text): return text
        case .int(let whole): return whole
        case .double(let real): return real
        case .bool(let flag): return flag
        case .null: return nil
        case .array(let items): return items.map { $0.foundationValue ?? NSNull() }
        case .dictionary(let dict): return dict.compactMapValues { $0.foundationValue }
        }
    }
}
