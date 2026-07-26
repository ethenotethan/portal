import Foundation

/// An opaque backend-intent request emitted by an inert marker in an HTML
/// artifact. It carries no intent name, executable parameters, credentials,
/// or arbitrary URL — only the identifiers already accepted by
/// `artifact.action.invoke`.
internal struct HTMLArtifactIntentRequest: Equatable, Sendable {
    internal static let scheme = "hermes-artifact-action"
    internal static let host = "invoke"

    internal let bindingID: String
    internal let entityRef: String

    internal init(bindingID: String, entityRef: String = "") {
        self.bindingID = bindingID
        self.entityRef = entityRef
    }

    internal init?(url: URL, expectedNonce: String) {
        guard url.scheme?.lowercased() == Self.scheme,
              url.host?.lowercased() == Self.host,
              !expectedNonce.isEmpty,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let allowedNames = Set(["binding_id", "entity_ref", "nonce"])
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard allowedNames.contains(item.name),
                  let value = item.value,
                  values[item.name] == nil else {
                return nil
            }
            values[item.name] = value
        }
        guard let bindingID = values["binding_id"], Self.isValidBindingID(bindingID) else {
            return nil
        }
        // The nonce is generated per WKWebView and injected only into an
        // isolated WKContentWorld. Page JavaScript cannot mint an invocation
        // by navigating to the private scheme on load; a real bridge click is
        // required to carry this capability.
        guard values["nonce"] == expectedNonce else { return nil }
        let entityRef = values["entity_ref"] ?? ""
        guard entityRef.utf8.count <= 512,
              !entityRef.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        self.init(bindingID: bindingID, entityRef: entityRef)
    }

    private static func isValidBindingID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "._:-".unicodeScalars.contains($0)
        }
    }
}

/// Narrow bridge between untrusted HTML presentation and trusted native
/// artifact-intent dispatch.
///
/// The injected script only translates a deliberate click on an element with
/// inert `data-hermes-binding` metadata into a private-scheme navigation. The
/// WKNavigationDelegate cancels that navigation and passes the opaque request
/// to SwiftUI. No message handler, gateway object, credential, fetch API, or
/// arbitrary RPC surface is exposed to page JavaScript.
internal enum HTMLArtifactIntentBridge {
    internal static func userScriptSource(nonce: String) -> String {
        // JSON-encode the nonce so it embeds as a safe JS string literal.
        // Encoding a String can't realistically fail; on the impossible error,
        // fall back to an empty JS string rather than force-unwrapping.
        let nonceLiteral: String
        do {
            let data = try JSONEncoder().encode(nonce)
            nonceLiteral = String(data: data, encoding: .utf8) ?? "\"\""
        } catch {
            nonceLiteral = "\"\""
        }
        return #"""
    (() => {
      'use strict';
      const nonce = \#(nonceLiteral);
      document.addEventListener('click', (event) => {
        // Reject element.click()/dispatchEvent() and other page-script
        // attempts. The isolated capability is usable only after a genuine
        // browser-trusted user gesture.
        if (!event.isTrusted) return;
        const origin = event.target;
        if (!(origin instanceof Element)) return;
        const control = origin.closest('[data-hermes-binding]');
        if (!control) return;

        const bindingID = (control.getAttribute('data-hermes-binding') || '').trim();
        if (!/^[A-Za-z0-9._:-]{1,128}$/.test(bindingID)) return;
        const entityRef = control.getAttribute('data-hermes-entity') || '';
        if (new TextEncoder().encode(entityRef).length > 512) return;

        event.preventDefault();
        event.stopPropagation();
        const query = new URLSearchParams({ binding_id: bindingID });
        if (entityRef) query.set('entity_ref', entityRef);
        query.set('nonce', nonce);
        window.location.href = 'hermes-artifact-action://invoke?' + query.toString();
      }, true);
    })();
    """#
    }

    /// Client-side defense in depth. The gateway independently resolves the
    /// binding from the pinned artifact revision and rejects forged IDs.
    internal static func resolve(
        _ request: HTMLArtifactIntentRequest,
        actions: [ArtifactAction]
    ) -> ArtifactAction? {
        actions.first { action in
            action.kind == .intent && action.bindingID == request.bindingID
        }
    }
}
