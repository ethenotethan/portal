/* Portal product site — progressive enhancement.
 *
 * Two effects, both purely decorative: elements fade/rise into view as they
 * scroll in, and the hero stats count up the first time they appear. The page
 * is fully legible without this file — the reveal styles live behind the `js`
 * class this script sets, and the stat numbers are already the correct final
 * text in the markup, so no-JS and prefers-reduced-motion users see everything
 * immediately. Nothing here fetches, and nothing here injects content.
 */
(function () {
  "use strict";

  var root = document.documentElement;
  var reduceMotion =
    window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Honour reduced motion by simply never opting into the animated path: the
  // markup stays in its natural, visible state.
  if (reduceMotion) return;

  // Gate the reveal styles: only once `js` is present does anything start hidden.
  root.classList.add("js");

  // Tag the elements worth revealing. Doing it here (rather than in the markup)
  // keeps the HTML clean and means a no-JS render never carries a hidden state.
  var selectors = [".hero-copy", ".hero-stats", ".band-head", ".card", ".feature", ".layer", ".lifecycle", ".proof-grid > .shot", ".wide-shot > .shot"];
  var revealables = [];
  selectors.forEach(function (sel) {
    Array.prototype.forEach.call(document.querySelectorAll(sel), function (el) {
      if (!el.hasAttribute("data-reveal")) el.setAttribute("data-reveal", "");
      revealables.push(el);
    });
  });

  // Stagger siblings inside a shared parent so a card grid ripples in rather
  // than snapping as one block.
  var lastParent = null;
  var stepIndex = 0;
  revealables.forEach(function (el) {
    if (el.parentNode !== lastParent) {
      lastParent = el.parentNode;
      stepIndex = 0;
    }
    el.style.setProperty("--reveal-delay", Math.min(stepIndex, 6) * 60 + "ms");
    stepIndex++;
  });

  function markVisible(el) {
    el.setAttribute("data-reveal", "in");
  }

  // No IntersectionObserver (or empty list) → reveal everything up front so the
  // gate never leaves content stuck hidden.
  if (!("IntersectionObserver" in window)) {
    revealables.forEach(markVisible);
    runCounters(document.querySelectorAll(".hero-stats [data-count]"));
    return;
  }

  var observer = new IntersectionObserver(
    function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        markVisible(entry.target);
        observer.unobserve(entry.target);
        if (entry.target.classList.contains("hero-stats")) {
          runCounters(entry.target.querySelectorAll("[data-count]"));
        }
      });
    },
    { rootMargin: "0px 0px -8% 0px", threshold: 0.12 }
  );
  revealables.forEach(function (el) {
    observer.observe(el);
  });

  // Count-up: ease a number from 0 to its target, formatted with thousands
  // separators to match the static markup exactly at rest.
  function runCounters(nodes) {
    Array.prototype.forEach.call(nodes, function (node) {
      if (node.dataset.counted) return;
      node.dataset.counted = "1";
      var target = parseInt(node.getAttribute("data-count"), 10);
      if (!isFinite(target)) return;
      var duration = 900;
      var start = null;
      function frame(now) {
        if (start === null) start = now;
        var t = Math.min((now - start) / duration, 1);
        var eased = 1 - Math.pow(1 - t, 3); // easeOutCubic
        node.textContent = Math.round(target * eased).toLocaleString("en-US");
        if (t < 1) requestAnimationFrame(frame);
        else node.textContent = target.toLocaleString("en-US");
      }
      requestAnimationFrame(frame);
    });
  }
})();
