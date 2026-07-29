import Foundation

/// Host assistance for mouse-driven HTML artifacts shown in the expanded
/// viewer. Pointer Lock must originate from a trusted page gesture, so Native
/// listens only for a real click on a canvas and requests the lock from that
/// same event dispatch. The bridge is intentionally absent from ordinary HTML
/// documents and never exposes a native capability to page JavaScript.
internal enum HTMLPointerLockBridge {
    internal static let contentWorldName = "HermesPointerLockBridge"

    internal static let userScriptSource = #"""
    (() => {
      'use strict';
      document.addEventListener('pointerdown', (event) => {
        if (!event.isTrusted || document.pointerLockElement) return;
        const origin = event.target;
        if (!(origin instanceof Element)) return;
        const canvas = origin.closest('canvas');
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
