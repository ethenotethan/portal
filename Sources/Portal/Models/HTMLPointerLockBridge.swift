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

      document.addEventListener('pointerdown', (event) => {
        if (!event.isTrusted || document.pointerLockElement) return;
        const origin = event.target;
        if (!(origin instanceof Element)) return;

        // A click on the canvas itself always captures. A click anywhere else
        // captures only when it isn't operating a control (HUD buttons keep
        // working) and the scene's canvas dominates the viewport.
        let canvas = origin.closest('canvas');
        if (!canvas) {
          if (origin.closest(INTERACTIVE)) return;
          canvas = dominantCanvas();
        }
        if (!canvas || typeof canvas.requestPointerLock !== 'function') return;

        canvas.focus({ preventScroll: true });
        try {
          const request = canvas.requestPointerLock();
          if (request && typeof request.catch === 'function') {
            request.catch(() => {});
          }
        } catch (_) {}
      }, true);
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
