import Foundation

/// Host assistance for mouse-driven HTML artifacts shown in the expanded
/// viewer. Pointer Lock must originate from a trusted page gesture, so Native
/// listens only for a real click and requests the lock from that same event
/// dispatch. The bridge is intentionally absent from ordinary HTML documents
/// and never exposes a native capability to page JavaScript.
///
/// A click does not have to land ON the canvas. Generated 3D worlds routinely
/// cover their canvas with HUD overlays (crosshairs, "click to start" panels,
/// stats readouts), so a canvas-only hit test meant every click hit the overlay
/// and the lock was never requested — the cursor floated over the scene no
/// matter how much the user clicked. Instead, any trusted click that is not on
/// an interactive control captures for the dominant canvas — but only when that
/// canvas actually dominates the viewport. The size gate is what keeps a
/// dashboard safe: a chart.js canvas in a report must not eat the cursor
/// because the user clicked near it.
internal enum HTMLPointerLockBridge {
    internal static let contentWorldName = "HermesPointerLockBridge"

    /// Fraction of the viewport the largest canvas must cover before a click
    /// outside any canvas captures the pointer. Direct canvas clicks are exempt
    /// — clicking a chart canvas captured before this bridge grew the fallback,
    /// and pages that dislike that can release via Esc as always.
    internal static let immersiveCanvasViewportFraction = 0.6

    /// On-screen trace of every capture attempt and its outcome, shown only when
    /// the host asks for it.
    ///
    /// Pointer Lock fails silently by design: `requestPointerLock()` rejects
    /// without a console error, WebKit's refusal reasons are private, and
    /// Portal's own `log.debug` lines are discarded by macOS unless debug logging
    /// is enabled as root. Diagnosing "the cursor still floats" from outside the
    /// process therefore comes down to guesswork. This paints the state the page
    /// itself sees — which element was targeted, whether the promise resolved,
    /// what `document.pointerLockElement` became — directly over the scene.
    internal static let captureDiagnosticSource = #"""
    (() => {
      'use strict';
      const box = document.createElement('div');
      box.style.cssText = [
        'position:fixed', 'left:10px', 'top:10px', 'z-index:2147483647',
        'font:11px ui-monospace,Menlo,monospace', 'color:#7CFFB2',
        'background:rgba(0,0,0,0.82)', 'padding:8px 10px', 'border-radius:6px',
        'pointer-events:none', 'white-space:pre', 'max-width:60vw',
        'border:1px solid rgba(124,255,178,0.35)'
      ].join(';');
      const lines = ['PORTAL LOCK TRACE — waiting for a click…'];
      const paint = () => { box.textContent = lines.slice(-9).join('\n'); };
      const say = (msg) => { lines.push(msg); paint(); };
      paint();
      const attach = () => {
        if (document.body) { document.body.appendChild(box); return true; }
        return false;
      };
      if (!attach()) document.addEventListener('DOMContentLoaded', attach);

      say('canvases=' + document.querySelectorAll('canvas').length +
          ' vp=' + window.innerWidth + 'x' + window.innerHeight);
      say('hasRPL=' + (typeof Element.prototype.requestPointerLock === 'function'));

      document.addEventListener('pointerdown', (e) => {
        const t = e.target;
        say('down trusted=' + e.isTrusted +
            ' on=' + (t && t.tagName ? t.tagName.toLowerCase() : '?') +
            (t && t.id ? '#' + t.id : ''));
      }, true);

      document.addEventListener('pointerlockchange', () => {
        const el = document.pointerLockElement;
        say('LOCKCHANGE -> ' + (el ? (el.tagName.toLowerCase() + (el.id ? '#' + el.id : '')) : 'null'));
      });
      document.addEventListener('pointerlockerror', () => say('LOCK ERROR (refused)'));

      let moves = 0;
      window.addEventListener('mousemove', (e) => {
        if (!document.pointerLockElement) return;
        if (moves++ % 12) return;
        say('locked move mx=' + e.movementX + ' my=' + e.movementY);
      }, true);

      // Report what the page's own request resolves to, without changing it.
      const original = Element.prototype.requestPointerLock;
      if (typeof original === 'function') {
        Element.prototype.requestPointerLock = function (...args) {
          say('page called requestPointerLock on ' +
              this.tagName.toLowerCase() + (this.id ? '#' + this.id : ''));
          try {
            const out = original.apply(this, args);
            if (out && typeof out.then === 'function') {
              out.then(() => say('  -> resolved')).catch((err) =>
                say('  -> REJECTED ' + (err && err.name ? err.name : err)));
            }
            return out;
          } catch (err) {
            say('  -> THREW ' + (err && err.name ? err.name : err));
            throw err;
          }
        };
      }
    })();
    """#

    internal static let userScriptSource = #"""
    (() => {
      'use strict';
      const INTERACTIVE =
        'a, button, input, select, textarea, label, summary, [contenteditable], [role="button"]';

      const dominantCanvas = () => {
        let best = null;
        let bestArea = 0;
        for (const canvas of document.querySelectorAll('canvas')) {
          const rect = canvas.getBoundingClientRect();
          const area = rect.width * rect.height;
          if (area > bestArea) { best = canvas; bestArea = area; }
        }
        const viewport = window.innerWidth * window.innerHeight;
        if (!best || !viewport || bestArea / viewport < \#(immersiveCanvasViewportFraction)) {
          return null;
        }
        return best;
      };

      const targetFor = (origin) => {
        if (!(origin instanceof Element)) return null;
        // A click on the canvas itself always captures. A click anywhere else
        // captures only when it isn't operating a control (HUD buttons keep
        // working) and the scene's canvas dominates the viewport.
        let canvas = origin.closest('canvas');
        if (!canvas) {
          if (origin.closest(INTERACTIVE)) return null;
          canvas = dominantCanvas();
        }
        if (!canvas || typeof canvas.requestPointerLock !== 'function') return null;
        return canvas;
      };

      const capture = (event) => {
        if (!event.isTrusted || document.pointerLockElement) return;
        const canvas = targetFor(event.target);
        if (!canvas) return;
        canvas.focus({ preventScroll: true });
        try {
          const request = canvas.requestPointerLock();
          if (request && typeof request.catch === 'function') {
            request.catch(() => {});
          }
        } catch (_) {}
      };

      // Try on every stage of the gesture, not just the first.
      //
      // WebKit grants Pointer Lock only against a transient user activation, and
      // it does not treat the stages of one gesture alike — a request made
      // during `pointerdown` can be refused where the same request from `click`
      // succeeds. A page that calls `requestPointerLock()` from its own click
      // handler therefore captured while this bridge, listening only for
      // `pointerdown`, silently did not: same document, same canvas, same
      // gesture, opposite outcome. So offer the request at each stage and let
      // whichever WebKit honours win. Re-entry is free — every path returns
      // immediately once `pointerLockElement` is set.
      for (const type of ['pointerdown', 'mouseup', 'click']) {
        document.addEventListener(type, capture, true);
      }
    })();
    """#

    /// Makes a drag-to-look world navigable with a captured cursor.
    ///
    /// Worlds authored before Portal taught the Pointer Lock contract rotate the
    /// camera on `clientX`/`clientY` deltas and only while a button is held.
    /// Pointer Lock freezes those coordinates and reports motion solely as
    /// `movementX`/`movementY`, so capturing such a page kills its camera
    /// outright — and declining to capture leaves the user dragging the mouse to
    /// turn, which is the complaint that started this.
    ///
    /// So translate instead of choosing: while the lock is held, hold a synthetic
    /// primary button down and advance synthetic coordinates by the captured
    /// deltas. The page receives precisely the drag it was written for and turns
    /// on bare mouse movement, with no change to the stored artifact.
    ///
    /// Injected only for pages the host classified as drag-driven
    /// (`InteractiveArtifactWeb.needsDragLookShim`), so a lock-aware world is
    /// never double-driven.
    internal static let dragLookShimSource = #"""
    (() => {
      'use strict';
      let cx = 0;
      let cy = 0;
      let dragging = false;

      const send = (type, target, buttons) => {
        target.dispatchEvent(new MouseEvent(type, {
          bubbles: true, cancelable: true, view: window,
          clientX: cx, clientY: cy, screenX: cx, screenY: cy,
          button: 0, buttons
        }));
      };

      const release = (target) => {
        if (!dragging) return;
        dragging = false;
        send('mouseup', target, 0);
      };

      document.addEventListener('pointerlockchange', () => {
        const locked = document.pointerLockElement;
        if (locked) {
          // Start from the element's centre so the first synthetic delta is
          // relative to a sane origin rather than the page's stale last point.
          const rect = locked.getBoundingClientRect();
          cx = rect.left + rect.width / 2;
          cy = rect.top + rect.height / 2;
        } else {
          release(document);
        }
      });

      window.addEventListener('mousemove', (event) => {
        const locked = document.pointerLockElement;
        if (!locked || !event.isTrusted) return;
        // The trusted event's coordinates are frozen, so letting the page see it
        // would compute a delta that exactly cancels the synthetic one. Replace
        // it: this capture-phase listener is outermost, so stopping immediate
        // propagation here keeps the page from ever seeing the frozen pair.
        event.stopImmediatePropagation();
        if (!dragging) {
          dragging = true;
          send('mousedown', locked, 1);
        }
        cx += event.movementX;
        cy += event.movementY;
        send('mousemove', locked, 1);
      }, true);

      // A real press while captured would re-seat the page's drag origin to the
      // frozen coordinates and snap the camera. The synthetic pair above is the
      // only button traffic the page should see while the lock is held.
      for (const type of ['mousedown', 'mouseup', 'click']) {
        window.addEventListener(type, (event) => {
          if (event.isTrusted && document.pointerLockElement) {
            event.stopImmediatePropagation();
          }
        }, true);
      }
    })();
    """#
}
