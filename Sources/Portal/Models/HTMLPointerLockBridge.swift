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
}
