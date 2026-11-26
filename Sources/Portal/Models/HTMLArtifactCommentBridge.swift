import Foundation

/// What the page may tell native about comments: a trusted click chose a spot
/// for a new pin, or a trusted click landed on an existing pin. Like the
/// intent bridge it travels as a private-scheme navigation the delegate
/// cancels, carrying the per-web-view nonce only the isolated world knows.
///
/// The page never supplies a comment's words. It supplies where the reader
/// clicked; the reader types the note in native chrome.
internal enum HTMLArtifactCommentRequest: Equatable, Sendable {
    case place(ArtifactCommentAnchor)
    case open(commentID: String)

    internal static let scheme = "hermes-artifact-comment"

    internal init?(url: URL, expectedNonce: String) {
        guard url.scheme?.lowercased() == Self.scheme,
              !expectedNonce.isEmpty,
              let host = url.host?.lowercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let allowedNames: Set<String>
        switch host {
        case "place": allowedNames = ["selector", "x", "y", "text", "nonce"]
        case "open": allowedNames = ["comment_id", "nonce"]
        default: return nil
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard allowedNames.contains(item.name), let value = item.value, values[item.name] == nil else {
                return nil
            }
            values[item.name] = value
        }
        guard values["nonce"] == expectedNonce else { return nil }

        if host == "open" {
            guard let commentID = values["comment_id"], Self.isValidCommentID(commentID) else { return nil }
            self = .open(commentID: commentID)
            return
        }
        guard let selector = values["selector"], !selector.isEmpty,
              selector.utf8.count <= ArtifactCommentAnchor.maxSelectorBytes, Self.isPlain(selector),
              let x = values["x"].flatMap(Self.fraction), let y = values["y"].flatMap(Self.fraction) else {
            return nil
        }
        let text = values["text"] ?? ""
        guard text.count <= ArtifactCommentAnchor.maxTextCharacters, Self.isPlain(text) else { return nil }
        self = .place(ArtifactCommentAnchor(selector: selector, x: x, y: y, text: text))
    }

    private static func isPlain(_ value: String) -> Bool {
        !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func fraction(_ value: String) -> Double? {
        guard value.utf8.count <= 12, let number = Double(value), (0...1).contains(number) else { return nil }
        return number
    }

    private static func isValidCommentID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "._:-".unicodeScalars.contains($0)
        }
    }
}

/// Comment pins on a live HTML artifact.
///
/// Page to native is `HTMLArtifactCommentRequest`. Native to page is one
/// script call in the isolated world that says which pins to draw and whether
/// the next click places a new one. A pin shows only its number: comment text
/// stays in native chrome and never enters the page's DOM.
internal enum HTMLArtifactCommentBridge {
    internal static let contentWorldName = HTMLArtifactIntentBridge.contentWorldName

    /// One numbered marker on the page.
    internal struct Pin: Equatable, Sendable {
        internal let id: String
        internal let number: Int
        internal let anchor: ArtifactCommentAnchor
        internal let resolved: Bool
    }

    /// Everything the page shows for comments.
    internal struct PageState: Equatable, Sendable {
        /// The next trusted click picks a spot instead of reaching the page.
        internal var isPlacing = false
        internal var selectedID: String?
        internal var pins: [Pin] = []
    }

    /// What a live artifact hands its web view. Absent for transcript and
    /// revision HTML, which install no comment script at all.
    internal struct Host {
        internal let state: PageState
        internal let onRequest: (HTMLArtifactCommentRequest) -> Void
    }

    /// Pins for the page: every open comment that has a spot, numbered by its
    /// place in the full list so a number never changes as others resolve,
    /// plus the selected comment even when it is resolved.
    internal static func pins(for comments: [ArtifactComment], selectedID: String?) -> [Pin] {
        comments.enumerated().compactMap { index, comment in
            guard !comment.anchor.isWholeArtifact, !comment.resolved || comment.id == selectedID else { return nil }
            return Pin(id: comment.id, number: index + 1, anchor: comment.anchor, resolved: comment.resolved)
        }
    }

    /// The script call that brings the page to `state`.
    internal static func applyScript(_ state: PageState) -> String {
        let pins: [[String: Any]] = state.pins.map { pin in
            [
                "id": pin.id, "n": pin.number, "selector": pin.anchor.selector,
                "x": pin.anchor.x, "y": pin.anchor.y, "text": pin.anchor.text, "resolved": pin.resolved,
            ]
        }
        let payload: [String: Any] = [
            "placing": state.isPlacing, "selected": state.selectedID ?? "", "pins": pins,
        ]
        return "globalThis.__hermesComments && globalThis.__hermesComments.apply(\(jsonLiteral(payload)));"
    }

    internal static func userScriptSource(nonce: String) -> String {
        script.replacingOccurrences(of: "__NONCE__", with: jsonLiteral(nonce))
    }

    /// A JS literal for `value`. JSONSerialization escapes everything that
    /// could end a string or a script; U+2028/2029 are escaped by hand because
    /// JSON allows them raw and older JavaScript does not.
    private static func jsonLiteral(_ value: Any) -> String {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        } catch {
            return "null"
        }
        return (String(data: data, encoding: .utf8) ?? "null")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    private static let script = #"""
    (() => {
      'use strict';
      const nonce = __NONCE__;
      const state = { placing: false, selected: '', pins: [] };
      const nodes = new Map();
      let layer = null;

      // Spaces must travel as %20: native reads the query with URLComponents,
      // which leaves a '+' as a plus sign.
      const send = (host, fields) => {
        const query = Object.entries({ ...fields, nonce })
          .map(([name, value]) => name + '=' + encodeURIComponent(String(value)))
          .join('&');
        window.location.href = 'hermes-artifact-comment://' + host + '?' + query;
      };

      const snippet = (element) =>
        (element.innerText || element.textContent || '')
          .replace(/[\u0000-\u001f\u007f-\u009f]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 280);

      const escapeIdent = (value) =>
        (window.CSS && CSS.escape) ? CSS.escape(value) : value.replace(/[^a-zA-Z0-9_-]/g, '\\$&');

      // A selector for the clicked element: a unique id where the page has
      // one, otherwise the chain of nth-of-type steps from body.
      const pathTo = (element) => {
        const parts = [];
        let node = element;
        while (node && node.nodeType === 1 && node !== document.documentElement && parts.length < 32) {
          if (node === document.body) { parts.unshift('body'); break; }
          if (node.id) {
            const byId = '#' + escapeIdent(node.id);
            if (document.querySelectorAll(byId).length === 1) { parts.unshift(byId); break; }
          }
          let index = 1;
          for (let sibling = node.previousElementSibling; sibling; sibling = sibling.previousElementSibling) {
            if (sibling.localName === node.localName) index += 1;
          }
          parts.unshift(escapeIdent(node.localName) + ':nth-of-type(' + index + ')');
          node = node.parentElement;
        }
        // Too long to carry: keep the innermost steps, which still narrow it.
        while (parts.length > 1 && new TextEncoder().encode(parts.join(' > ')).length > 480) parts.shift();
        return parts.join(' > ');
      };

      const inLayer = (node) => !!(layer && node instanceof Node && layer.contains(node));

      // The element whose text is exactly `text`, as deep as that stays true.
      const byText = (text) => {
        if (!text || !document.body) return null;
        let found = null;
        const all = document.body.getElementsByTagName('*');
        for (let i = 0; i < all.length && i < 20000; i += 1) {
          if (!inLayer(all[i]) && snippet(all[i]) === text) { found = all[i]; break; }
        }
        while (found) {
          const child = Array.from(found.children).find((candidate) => snippet(candidate) === text);
          if (!child) break;
          found = child;
        }
        return found;
      };

      // Where a pin's element is now. The selector wins while the element
      // still shows what it showed; otherwise the text finds where it moved;
      // otherwise the selector's element stands in. Null means detached.
      const locate = (pin) => {
        let element = null;
        try { element = pin.selector ? document.querySelector(pin.selector) : null; } catch (_) { element = null; }
        if (element && inLayer(element)) element = null;
        if (element && (!pin.text || snippet(element) === pin.text)) return element;
        return byText(pin.text) || element;
      };

      const ensureLayer = () => {
        if (layer && layer.isConnected) return layer;
        layer = document.createElement('div');
        layer.setAttribute('data-hermes-comment-layer', '');
        layer.style.cssText =
          'position:absolute;top:0;left:0;width:0;height:0;z-index:2147483646;pointer-events:none;';
        const style = document.createElement('style');
        style.textContent =
          'html[data-hermes-commenting], html[data-hermes-commenting] * { cursor: crosshair !important; }';
        layer.appendChild(style);
        document.documentElement.appendChild(layer);
        nodes.clear();
        return layer;
      };

      const paint = (node, pin) => {
        const selected = pin.id === state.selected;
        node.textContent = String(pin.n);
        node.style.cssText = [
          'position:absolute', 'box-sizing:border-box', 'min-width:22px', 'height:22px', 'padding:0 6px',
          'margin:-11px 0 0 -11px', 'border-radius:11px', 'pointer-events:auto', 'cursor:pointer',
          'font:600 11px/22px -apple-system,system-ui,sans-serif', 'text-align:center', 'user-select:none',
          'color:#1b1300', 'background:' + (pin.resolved ? '#9aa0a6' : '#f5a623'),
          'opacity:' + (pin.resolved ? '0.7' : '1'),
          'box-shadow:0 1px 4px rgba(0,0,0,.45)' + (selected ? ',0 0 0 3px rgba(255,255,255,.9)' : ''),
        ].join(';');
      };

      const position = () => {
        const host = ensureLayer();
        const live = new Set();
        for (const pin of state.pins) {
          live.add(pin.id);
          let node = nodes.get(pin.id);
          if (!node) {
            node = document.createElement('div');
            node.setAttribute('data-hermes-comment-pin', pin.id);
            nodes.set(pin.id, node);
            host.appendChild(node);
          }
          paint(node, pin);
          const element = locate(pin);
          if (!element) { node.style.display = 'none'; continue; }
          const rect = element.getBoundingClientRect();
          node.style.left = (rect.left + window.scrollX + rect.width * pin.x) + 'px';
          node.style.top = (rect.top + window.scrollY + rect.height * pin.y) + 'px';
        }
        for (const [id, node] of nodes) {
          if (!live.has(id)) { node.remove(); nodes.delete(id); }
        }
      };

      let queued = false;
      const schedule = () => {
        if (queued || state.pins.length === 0) return;
        queued = true;
        requestAnimationFrame(() => { queued = false; position(); });
      };
      window.addEventListener('resize', schedule);
      document.addEventListener('scroll', schedule, true);
      new MutationObserver((records) => {
        if (records.some((record) => !inLayer(record.target))) schedule();
      }).observe(document.documentElement, { childList: true, subtree: true, characterData: true });

      document.addEventListener('click', (event) => {
        // Synthetic clicks cannot place a pin or open one.
        if (!event.isTrusted || !(event.target instanceof Element)) return;
        const pin = event.target.closest('[data-hermes-comment-pin]');
        if (pin && inLayer(pin)) {
          event.preventDefault();
          event.stopImmediatePropagation();
          send('open', { comment_id: pin.getAttribute('data-hermes-comment-pin') || '' });
          return;
        }
        if (!state.placing) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        const rect = event.target.getBoundingClientRect();
        const fraction = (offset, size) => (size > 0 ? Math.min(1, Math.max(0, offset / size)) : 0.5).toFixed(4);
        send('place', {
          selector: pathTo(event.target),
          x: fraction(event.clientX - rect.left, rect.width),
          y: fraction(event.clientY - rect.top, rect.height),
          text: snippet(event.target),
        });
      }, true);

      globalThis.__hermesComments = {
        apply(next) {
          state.placing = !!next.placing;
          state.selected = String(next.selected || '');
          state.pins = Array.isArray(next.pins) ? next.pins : [];
          if (state.placing) document.documentElement.setAttribute('data-hermes-commenting', '');
          else document.documentElement.removeAttribute('data-hermes-commenting');
          position();
        },
      };
    })();
    """#
}
