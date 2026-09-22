#!/usr/bin/env python3
"""Generate the product-site "Quality gates" page (`site/metrics.html`).

The page documents every quantification gate the repo enforces — the metric
ratchets and baseline guards — and shows each gate's CURRENT recorded state.

Two halves, kept deliberately separate:

  DETERMINISTIC EXTRACTION — every number on the page is read straight from a
  committed state file (`metrics-baseline.json`, `perf-baseline.json`,
  `.swiftlint-baseline`, `.gitleaksignore`). No build, no network, no
  estimate: run this script and the figures are exactly what CI compares
  against. `--check` fails if the checked-in HTML no longer matches, so the
  page cannot silently drift from the baselines (the same posture as
  `build_architecture.py --check`).

  AUTHORED SYNTHESIS — the prose describing what each gate measures, its FLOOR
  and PATCH semantics, and why it exists lives in `GATES` below. Baselines
  record numbers, not intent; that explanation is written here and rendered
  verbatim.

The page reuses the product site's stylesheet (`styles.css`) plus a small
scoped block for the bars and tables this page alone needs.

Usage:
    build_metrics_page.py            # (re)write site/metrics.html
    build_metrics_page.py --check    # exit 1 if the checked-in file is stale
"""
from __future__ import annotations

import argparse
import html
import json
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
METRICS_BASELINE = ROOT / "metrics-baseline.json"
PERF_BASELINE = ROOT / "perf-baseline.json"
SWIFTLINT_BASELINE = ROOT / ".swiftlint-baseline"
GITLEAKS_IGNORE = ROOT / ".gitleaksignore"
OUTPUT = ROOT / "site" / "metrics.html"

# Thresholds mirror the constants the ratchet scripts enforce; if you change one
# there, change it here so the page stays honest. Kept as literals (not imported)
# because the scripts are CLI tools, not a package.
COVERAGE_FLOOR_TOLERANCE = 0.5     # check-metrics-ratchet.py
COVERAGE_PATCH_THRESHOLD = 0.80    # check-metrics-ratchet.py
COVERAGE_PATCH_MIN_LINES = 10      # check-metrics-ratchet.py


# ─────────────────────────── deterministic extraction ───────────────────────

def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def extract_state() -> dict:
    """Read every gate's current recorded state from its committed file."""
    metrics = read_json(METRICS_BASELINE)
    perf = read_json(PERF_BASELINE)

    lint = read_json(SWIFTLINT_BASELINE)
    lint_by_rule = Counter(
        entry["violation"]["ruleIdentifier"] for entry in lint
    )

    fingerprints = [
        line for line in GITLEAKS_IGNORE.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]

    cov = metrics["coverage"]
    return {
        "coverage": {
            "testable_pct": cov["testable_pct"],
            "testable_covered": cov["testable_covered"],
            "testable_count": cov["testable_count"],
            "layers": cov["layers"],
            "uncovered_files": len(cov.get("uncovered", {})),
        },
        "warnings": {
            "total": metrics["warnings"]["total"],
            "counts": metrics["warnings"]["counts"],
        },
        "skipped": {
            "total": metrics["skipped"]["total"],
            "counts": metrics["skipped"]["counts"],
        },
        "deadcode": {
            "total": metrics["deadcode"]["total"],
            "counts": metrics["deadcode"]["counts"],
            "sites": len(metrics["deadcode"].get("sites", [])),
        },
        "perf": {"counts": perf["counts"]},
        "lint": {"total": len(lint), "by_rule": dict(lint_by_rule)},
        "secrets": {"fingerprints": len(fingerprints)},
    }


# ─────────────────────────────── authored synthesis ─────────────────────────
# Prose only. Numbers are never hard-coded here — they come from extract_state.

GATES = [
    {
        "id": "warnings",
        "title": "Compiler warnings",
        "source": "metrics-baseline.json",
        "measures": "Swift compiler warning sites, per category. Build is the "
                    "source of truth; the baseline freezes pre-existing debt.",
        "floor": "No category exceeds base.",
        "patch": "No warning on a line the PR added.",
    },
    {
        "id": "coverage",
        "title": "Test coverage",
        "source": "metrics-baseline.json",
        "measures": "Line coverage from `swift test`, testable layers only "
                    "(Models, Services, Utilities, ViewModels). Views excluded — "
                    "unreachable by the unit suite.",
        "floor": f"Aggregate drops ≤ {COVERAGE_FLOOR_TOLERANCE} pt vs base.",
        "patch": f"≥ {int(COVERAGE_PATCH_THRESHOLD * 100)}% of added executable "
                 f"lines covered; skipped under {COVERAGE_PATCH_MIN_LINES} lines.",
    },
    {
        "id": "skipped",
        "title": "Skipped tests",
        "source": "metrics-baseline.json",
        "measures": "Disabled or known-issue tests — coverage that never runs.",
        "floor": "Count ≤ base.",
        "patch": "No new skip on an added line.",
    },
    {
        "id": "deadcode",
        "title": "Dead code",
        "source": "metrics-baseline.json",
        "measures": "Unused declarations from Periphery: unreferenced symbols, "
                    "assign-only properties, redundant protocols, conformances, "
                    "and accessibility.",
        "floor": "No category exceeds base.",
        "patch": "No finding on a line the PR added.",
    },
    {
        "id": "perf",
        "title": "Performance op-counts",
        "source": "perf-baseline.json",
        "measures": "Algorithmic op-counts (not time) for hot pure layout paths, "
                    "over fixed fixtures under -DPERF_COUNTERS. Deterministic "
                    "across machines.",
        "floor": "Every counter ≤ base; ceiling read from base via `git show`.",
        "patch": None,  # floor-only: op counts aren't attributable to added lines
    },
    {
        "id": "lint",
        "title": "Lint baseline",
        "source": ".swiftlint-baseline",
        "measures": "Pre-existing SwiftLint debt, frozen per rule via "
                    "`swiftlint --baseline`; only new violations fail.",
        "floor": "A tracked rule's count may not grow; paydown or a new rule's "
                 "initial freeze only.",
        "patch": None,  # the guard is a per-rule growth check, not a diff gate
    },
    {
        "id": "secrets",
        "title": "Secret ignore-list",
        "source": ".gitleaksignore",
        "measures": "Accepted gitleaks fingerprints — matches reviewed and judged "
                    "not real secrets.",
        "floor": "Count may not grow silently; each addition justified in the PR.",
        "patch": None,  # count-growth guard, not a diff gate
    },
]

# Compact metric strip: (label, value-fn, suffix). value-fn takes the extracted
# state and returns the number to display.
HERO = [
    ("Testable coverage", lambda s: f"{s['coverage']['testable_pct']:.1f}", "%"),
    ("Compiler warnings", lambda s: f"{s['warnings']['total']:,}", ""),
    ("Skipped tests", lambda s: f"{s['skipped']['total']:,}", ""),
    ("Dead-code findings", lambda s: f"{s['deadcode']['total']:,}", ""),
    ("Frozen lint debt", lambda s: f"{s['lint']['total']:,}", ""),
]


# ────────────────────────────────── rendering ───────────────────────────────

def esc(text: str) -> str:
    return html.escape(str(text), quote=True)


def bar(pct: float) -> str:
    width = max(0.0, min(100.0, float(pct)))
    return (f'<div class="mbar"><span class="mbar-fill" '
            f'style="width:{width:.1f}%"></span></div>')


def gate_current(gate: dict, state: dict) -> str:
    """One-line current-state summary for a gate, from extracted numbers."""
    st = state[gate["id"]]
    if gate["id"] == "coverage":
        return (f"{st['testable_pct']:.2f}% "
                f"({st['testable_covered']:,} / {st['testable_count']:,})")
    if gate["id"] == "perf":
        return f"{len(st['counts'])} counters"
    if gate["id"] == "lint":
        return f"{st['total']:,} in {len(st['by_rule'])} rules"
    if gate["id"] == "secrets":
        n = st["fingerprints"]
        return "0" if n == 0 else f"{n:,}"
    if gate["id"] == "deadcode":
        return f"{st['total']:,} in {st['sites']:,} sites"
    return f"{st['total']:,}"  # warnings, skipped


def render_gates_table(state: dict) -> str:
    rows = []
    for gate in GATES:
        patch = esc(gate["patch"]) if gate["patch"] else '<span class="na">floor-only</span>'
        rows.append(
            f'          <tr id="gate-{gate["id"]}">\n'
            f'            <th scope="row"><span class="gname">{esc(gate["title"])}</span>'
            f'<span class="gsrc">{esc(gate["source"])}</span>'
            f'<span class="gdesc">{esc(gate["measures"])}</span></th>\n'
            f'            <td class="num gcur">{esc(gate_current(gate, state))}</td>\n'
            f'            <td class="grule">{esc(gate["floor"])}</td>\n'
            f'            <td class="grule">{patch}</td>\n'
            f'          </tr>'
        )
    return (
        '      <table class="mtable gates">\n'
        '        <thead><tr>'
        '<th scope="col">Gate</th>'
        '<th scope="col" class="num">Current</th>'
        '<th scope="col">Floor (whole tree vs base)</th>'
        '<th scope="col">Patch (added lines)</th>'
        '</tr></thead>\n'
        '        <tbody>\n' + "\n".join(rows) + "\n        </tbody>\n"
        '      </table>'
    )


def render_coverage_table(state: dict) -> str:
    layers = state["coverage"]["layers"]
    rows = []
    for name in sorted(layers):
        layer = layers[name]
        rows.append(
            f'        <tr><th scope="row">{esc(name)}</th>'
            f'<td class="num">{layer["pct"]:.2f}%</td>'
            f'<td class="num">{layer["covered"]:,} / {layer["count"]:,}</td>'
            f'<td class="barcell">{bar(layer["pct"])}</td></tr>'
        )
    return (
        '      <table class="mtable">\n'
        '        <thead><tr><th scope="col">Layer</th><th scope="col">Coverage</th>'
        '<th scope="col">Lines</th><th scope="col"></th></tr></thead>\n'
        '        <tbody>\n' + "\n".join(rows) + "\n        </tbody>\n"
        '      </table>'
    )


def render_kv_table(title_cols, pairs, total=None) -> str:
    """A simple two-column count table (rule/kind/counter → count)."""
    rows = [
        f'        <tr><th scope="row">{esc(k)}</th>'
        f'<td class="num">{v:,}</td></tr>'
        for k, v in sorted(pairs, key=lambda kv: (-kv[1], kv[0]))
    ]
    foot = ""
    if total is not None:
        foot = (f'        <tfoot><tr><th scope="row">Total</th>'
                f'<td class="num">{total:,}</td></tr></tfoot>\n')
    return (
        '      <table class="mtable">\n'
        f'        <thead><tr><th scope="col">{esc(title_cols[0])}</th>'
        f'<th scope="col">{esc(title_cols[1])}</th></tr></thead>\n'
        '        <tbody>\n' + "\n".join(rows) + "\n        </tbody>\n"
        + foot +
        '      </table>'
    )


PAGE_STYLE = """  <style>
    /* Scoped to this page — a dense analytics view, not a marketing page.
       The shared stylesheet has no table/bar/metric primitives. */
    .msummary{margin:1.5rem 0 .5rem;}
    .msummary p{max-width:64ch;opacity:.85;margin:.35rem 0 0;font-size:.92rem;}
    .mstrip{display:flex;flex-wrap:wrap;gap:.4rem 2rem;list-style:none;padding:0;margin:1.1rem 0 0;
            border:1px solid rgba(128,128,128,.2);border-radius:.6rem;padding:.85rem 1.1rem;}
    .mstrip li{display:flex;flex-direction:column;}
    .mstrip .mval{font-size:1.35rem;font-weight:680;font-variant-numeric:tabular-nums;line-height:1.1;}
    .mstrip .mlbl{font-size:.72rem;letter-spacing:.05em;text-transform:uppercase;opacity:.6;}
    .msection{margin:2rem 0 0;}
    .msection h3{margin:0;font-size:1.05rem;}
    .msection .mprovenance{margin:.3rem 0 .1rem;}
    .mprovenance{font-size:.82rem;opacity:.7;max-width:72ch;}
    .mtable{width:100%;border-collapse:collapse;margin:.6rem 0 0;font-variant-numeric:tabular-nums;font-size:.9rem;}
    .mtable th,.mtable td{text-align:left;padding:.5rem .6rem;border-bottom:1px solid rgba(128,128,128,.16);vertical-align:top;}
    .mtable thead th{font-size:.7rem;letter-spacing:.05em;text-transform:uppercase;opacity:.6;font-weight:650;}
    .mtable td.num,.mtable th.num{text-align:right;}
    .mtable td.num{font-weight:650;}
    .mtable tfoot th,.mtable tfoot td{border-bottom:none;border-top:2px solid rgba(128,128,128,.32);font-weight:700;}
    .mtable td.barcell{width:32%;}
    /* Gates table: name + provenance + one-line description stacked in col 1. */
    .gates .gname{display:block;font-weight:650;}
    .gates .gsrc{display:block;font-size:.72rem;opacity:.5;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;margin-top:.1rem;}
    .gates .gdesc{display:block;font-size:.82rem;opacity:.78;margin-top:.25rem;max-width:52ch;}
    .gates .gcur{white-space:nowrap;}
    .gates .grule{font-size:.85rem;opacity:.9;}
    .gates .na{opacity:.45;font-style:italic;}
    .mbar{position:relative;height:.45rem;border-radius:999px;background:rgba(128,128,128,.18);overflow:hidden;}
    .mbar-fill{position:absolute;inset:0 auto 0 0;border-radius:999px;background:linear-gradient(90deg,var(--grad-a,#6ea8fe),var(--grad-b,#a06bff));}
  </style>"""


def render_page(state: dict) -> str:
    strip_items = "\n".join(
        f'        <li><span class="mval">{esc(fn(state))}{esc(suffix)}</span>'
        f'<span class="mlbl">{esc(label)}</span></li>'
        for label, fn, suffix in HERO
    )
    gates_table = render_gates_table(state)

    cov = state["coverage"]
    dc = state["deadcode"]
    perf = state["perf"]["counts"]

    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="description" content="Portal ratchet analytics — current recorded state of every code-health gate, extracted from the committed baselines CI enforces.">
  <title>Portal — Ratchet analytics</title>
  <link rel="stylesheet" href="styles.css">
{PAGE_STYLE}
</head>
<body>
  <a class="skip-link" href="#main">Skip to content</a>

  <header class="topbar">
    <div class="brand">
      <span class="brand-mark" aria-hidden="true">P</span>
      <div>
        <div class="eyebrow">ETHENOTETHAN / PORTAL</div>
        <h1>Ratchet analytics</h1>
      </div>
    </div>
    <nav class="topnav" aria-label="Sections">
      <a href="index.html#overview">Overview</a>
      <a href="index.html#features">Features</a>
      <a href="architecture/">Architecture ↗</a>
      <a href="https://github.com/ethenotethan/portal" target="_blank" rel="noreferrer">Repository ↗</a>
    </nav>
  </header>

  <main id="main">

    <section class="msummary" id="overview">
      <p>Current recorded state of every code-health gate, extracted directly
      from the committed baselines CI enforces. Each gate runs a
      <strong>floor</strong> (whole tree, never worse than base) and, where
      applicable, a <strong>patch</strong> check (lines a PR added, held
      stricter). Numbers are read from the state files — not measured here — so
      the page can't drift from what CI compares against.</p>
      <ul class="mstrip" aria-label="Current gate states">
{strip_items}
      </ul>
    </section>

    <section class="msection" id="gates">
      <h3>Gates</h3>
      <p class="mprovenance">Sources: <code>metrics-baseline.json</code>,
      <code>perf-baseline.json</code>, <code>.swiftlint-baseline</code>,
      <code>.gitleaksignore</code>. Floor-only gates have no per-diff check
      (op-counts and count-growth guards aren't attributable to added lines).</p>
{gates_table}
    </section>

    <section class="msection" id="coverage-detail">
      <h3>Coverage by testable layer</h3>
      <p class="mprovenance">Aggregate {cov['testable_pct']:.2f}%
      ({cov['testable_covered']:,} / {cov['testable_count']:,} executable lines);
      {cov['uncovered_files']:,} files carry uncovered lines. Views excluded —
      unreachable by the unit suite.</p>
{render_coverage_table(state)}
    </section>

    <section class="msection" id="deadcode-detail">
      <h3>Dead code by kind</h3>
      <p class="mprovenance">{dc['total']:,} findings across {dc['sites']:,} sites (Periphery).</p>
{render_kv_table(("Kind", "Findings"), list(dc['counts'].items()), total=dc['total'])}
    </section>

    <section class="msection" id="lint-detail">
      <h3>Frozen lint debt by rule</h3>
      <p class="mprovenance">{state['lint']['total']:,} pre-existing violations excluded via <code>swiftlint --baseline</code>; each count is a ceiling.</p>
{render_kv_table(("Rule", "Frozen"), list(state['lint']['by_rule'].items()), total=state['lint']['total'])}
    </section>

    <section class="msection" id="perf-detail">
      <h3>Performance op-count ceilings</h3>
      <p class="mprovenance">Deterministic op tallies over fixed fixtures; a count may fall, never rise.</p>
{render_kv_table(("Counter", "Operations"), list(perf.items()))}
    </section>

  </main>

  <footer>
    <p class="mprovenance">Generated by <code>scripts/build_metrics_page.py</code> from the committed baselines; <code>--check</code> fails if this page drifts from them. Enforced by the Ratchet and Pages workflows.</p>
    <p>
      <a href="index.html">Home</a> ·
      <a href="architecture/">Architecture Observatory</a> ·
      <a href="https://github.com/ethenotethan/portal" target="_blank" rel="noreferrer">GitHub</a>
    </p>
  </footer>

  <script src="enhance.js" defer></script>
</body>
</html>
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="fail if the checked-in site/metrics.html is stale")
    args = parser.parse_args()

    rendered = render_page(extract_state())

    if args.check:
        current = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else ""
        if current != rendered:
            print("error: site/metrics.html is stale — run "
                  "`python3 scripts/build_metrics_page.py` and commit the result.",
                  file=sys.stderr)
            return 1
        print("ok: site/metrics.html matches the committed baselines")
        return 0

    OUTPUT.write_text(rendered, encoding="utf-8")
    print(f"wrote {OUTPUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
