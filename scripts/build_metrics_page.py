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
        "source": "metrics-baseline.json · scripts/check-metrics-ratchet.py",
        "measures": "Every site the Swift compiler emits a warning, tallied per "
                    "category. The build is the source of truth; the baseline "
                    "freezes what pre-existed.",
        "floor": "Per-category warning counts in the current build may not exceed "
                 "the base branch's counts. Per-category, not just the total, so "
                 "fixing one kind while adding another can't net out flat.",
        "patch": "No warning may land on a line this PR added (right-side lines of "
                 "the diff). Old debt pays down gradually under the floor; new "
                 "code carries zero new warnings.",
    },
    {
        "id": "coverage",
        "title": "Test coverage",
        "source": "metrics-baseline.json · scripts/check-metrics-ratchet.py",
        "measures": "Line coverage from `swift test`, scoped to the testable "
                    "layers — Models, Services, Utilities, ViewModels. Views are "
                    "excluded entirely: they are unreachable by the unit suite, so "
                    "counting them would only dilute the number.",
        "floor": f"Aggregate testable-layer coverage may not fall more than "
                 f"{COVERAGE_FLOOR_TOLERANCE} of a point below the base branch.",
        "patch": f"Of the executable lines a PR adds in testable-layer files, at "
                 f"least {int(COVERAGE_PATCH_THRESHOLD * 100)}% must be covered — "
                 f"not 100%, since defensive branches are legitimately hard to "
                 f"reach. The check is skipped below {COVERAGE_PATCH_MIN_LINES} "
                 f"added executable lines, where the ratio is too noisy to judge.",
    },
    {
        "id": "skipped",
        "title": "Skipped tests",
        "source": "metrics-baseline.json · scripts/check-metrics-ratchet.py",
        "measures": "Tests that are disabled or parked behind a known-issue marker "
                    "— coverage that looks present but never runs.",
        "floor": "The count of skipped tests may not exceed the base branch's. A "
                 "quarantined test is a debt to pay back down, not to accumulate.",
        "patch": "No test skip may be introduced on a line this PR added: new "
                 "tests ship runnable.",
    },
    {
        "id": "deadcode",
        "title": "Dead code",
        "source": "metrics-baseline.json · scripts/check-metrics-ratchet.py",
        "measures": "Unused declarations reported by Periphery — unreferenced "
                    "symbols, assign-only properties, redundant protocols and "
                    "conformances, redundant public accessibility.",
        "floor": "Per-category dead-code counts may not exceed the base branch's, "
                 "so the tree trends toward less unused code, never more.",
        "patch": "No dead-code finding may sit on a line this PR added: you don't "
                 "get to write new code that is already unreachable.",
    },
    {
        "id": "perf",
        "title": "Performance op-counts",
        "source": "perf-baseline.json · scripts/check-perf-ratchet.py",
        "measures": "Algorithmic WORK COUNTS — not wall-clock time — for the hot "
                    "pure layout paths. A harness drives fixed-size fixtures under "
                    "-DPERF_COUNTERS and tallies operations, so every count is "
                    "identical on any machine and an O(n)→O(n²) regression "
                    "changes it by orders of magnitude.",
        "floor": "Every counter in the current snapshot must be ≤ the base "
                 "branch's. The ceiling is read from base via `git show`, so "
                 "bumping the baseline in the same PR can't wave a regression "
                 "through. Fewer ops always passes and locks in as the new floor.",
        "patch": None,  # floor-only: op counts aren't attributable to added lines
    },
    {
        "id": "lint",
        "title": "Lint baseline",
        "source": ".swiftlint-baseline · scripts/check-baseline-growth.py",
        "measures": "Pre-existing SwiftLint debt, frozen per rule. CI runs "
                    "`swiftlint --baseline`, so anything already recorded is "
                    "excluded and only NEW violations fail a build.",
        "floor": "An already-tracked rule's frozen count may not grow. Regenerating "
                 "the baseline to freeze a fresh violation instead of fixing it is "
                 "exactly the escape hatch this closes; only paydown (a shrinking "
                 "count) or a brand-new rule's initial freeze is allowed.",
        "patch": None,  # the guard is a per-rule growth check, not a diff gate
    },
    {
        "id": "secrets",
        "title": "Secret ignore-list",
        "source": ".gitleaksignore · scripts/check-secret-baseline-growth.py",
        "measures": "Accepted gitleaks findings — fingerprints of matches reviewed "
                    "and judged not real secrets (test dummies, example tokens, "
                    "public hashes the allowlist missed).",
        "floor": "The fingerprint count may not grow silently. A genuine "
                 "false-positive can be accepted, but the growth fails CI until "
                 "the PR justifies each added fingerprint — so a real leaked "
                 "credential can't be pasted in to turn the scan green.",
        "patch": None,  # count-growth guard, not a diff gate
    },
]

# Headline stats for the hero strip: (label, value-fn, suffix). value-fn takes
# the extracted state and returns the number to display.
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


def render_gate_card(gate: dict, state: dict) -> str:
    st = state[gate["id"]]
    # One-line current-state summary per gate, from extracted numbers.
    if gate["id"] == "coverage":
        current = (f"{st['testable_pct']:.2f}% "
                   f"({st['testable_covered']:,} / {st['testable_count']:,} lines)")
    elif gate["id"] == "perf":
        current = f"{len(st['counts'])} instrumented counters"
    elif gate["id"] == "lint":
        current = f"{st['total']:,} violations across {len(st['by_rule'])} rules"
    elif gate["id"] == "secrets":
        n = st["fingerprints"]
        current = "clean — 0 accepted findings" if n == 0 else f"{n:,} accepted findings"
    elif gate["id"] == "deadcode":
        current = f"{st['total']:,} findings across {st['sites']:,} sites"
    else:  # warnings, skipped
        current = "clean — 0" if st["total"] == 0 else f"{st['total']:,}"

    rows = [
        f'      <p class="mgate-current"><span class="mgate-k">Current</span>'
        f'<span class="mgate-v">{esc(current)}</span></p>',
        f'      <p class="mgate-desc">{esc(gate["measures"])}</p>',
        f'      <dl class="mgate-rules">',
        f'        <dt>Floor</dt><dd>{esc(gate["floor"])}</dd>',
    ]
    if gate["patch"]:
        rows.append(f'        <dt>Patch</dt><dd>{esc(gate["patch"])}</dd>')
    else:
        rows.append('        <dt>Patch</dt><dd class="mgate-na">Floor-only — '
                    'this gate has no per-diff half.</dd>')
    rows.append("      </dl>")
    rows.append(f'      <p class="mgate-src">{esc(gate["source"])}</p>')

    return (
        f'    <article class="card mgate" id="gate-{gate["id"]}">\n'
        f'      <h4>{esc(gate["title"])}</h4>\n'
        + "\n".join(rows) + "\n"
        f'    </article>'
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
    /* Scoped to this page — the shared stylesheet has no table/bar primitives. */
    .mgrid{display:grid;gap:1rem;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));}
    .mgate h4{margin:0 0 .5rem;}
    .mgate-current{display:flex;flex-wrap:wrap;gap:.5rem;align-items:baseline;margin:.25rem 0 .75rem;}
    .mgate-k{font-size:.72rem;letter-spacing:.08em;text-transform:uppercase;opacity:.6;}
    .mgate-v{font-weight:650;font-variant-numeric:tabular-nums;}
    .mgate-desc{margin:.25rem 0 .75rem;}
    .mgate-rules{margin:0;display:grid;grid-template-columns:auto 1fr;gap:.35rem .75rem;}
    .mgate-rules dt{font-weight:650;opacity:.85;}
    .mgate-rules dd{margin:0;opacity:.9;}
    .mgate-na{opacity:.6;font-style:italic;}
    .mgate-src{margin:.9rem 0 0;font-size:.75rem;opacity:.55;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;}
    .mtable{width:100%;border-collapse:collapse;margin:.5rem 0 0;font-variant-numeric:tabular-nums;}
    .mtable th,.mtable td{text-align:left;padding:.45rem .6rem;border-bottom:1px solid rgba(128,128,128,.18);}
    .mtable thead th{font-size:.72rem;letter-spacing:.06em;text-transform:uppercase;opacity:.6;}
    .mtable td.num{text-align:right;font-weight:600;}
    .mtable tfoot th,.mtable tfoot td{border-bottom:none;border-top:2px solid rgba(128,128,128,.35);font-weight:700;}
    .mtable td.barcell{width:34%;}
    .mbar{position:relative;height:.5rem;border-radius:999px;background:rgba(128,128,128,.18);overflow:hidden;}
    .mbar-fill{position:absolute;inset:0 auto 0 0;border-radius:999px;background:linear-gradient(90deg,var(--grad-a,#6ea8fe),var(--grad-b,#a06bff));}
    .mprovenance{font-size:.8rem;opacity:.7;}
  </style>"""


def render_page(state: dict) -> str:
    hero_items = "\n".join(
        f'        <li><strong>{esc(fn(state))}{esc(suffix)}</strong>'
        f'<span>{esc(label)}</span></li>'
        for label, fn, suffix in HERO
    )
    gate_cards = "\n".join(render_gate_card(g, state) for g in GATES)

    dc = state["deadcode"]
    perf = state["perf"]["counts"]

    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="description" content="Portal's quantification gates — the metric ratchets and baseline guards that keep code health from regressing, with each gate's current recorded state.">
  <title>Portal — Quality gates &amp; ratchets</title>
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
        <h1>Quality gates</h1>
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

    <section class="hero" id="overview">
      <div class="hero-glow" aria-hidden="true"></div>
      <div class="hero-copy" data-reveal>
        <p class="badge"><span class="badge-dot" aria-hidden="true"></span> Enforced in CI · every number below is measured, not aspirational</p>
        <h2>Code health that can<br>only <span class="grad">go one way.</span></h2>
        <p class="lede">
          Portal gates every pull request on a set of <strong>ratchets</strong>:
          quantified code-health metrics that may improve freely but can never
          regress. Each gate runs two checks — a <strong>floor</strong> that
          forbids the whole tree from getting worse than the base branch, and,
          where it makes sense, a <strong>patch</strong> check that holds the
          lines a PR actually touched to a higher standard. The state files are
          committed, so the bar is always visible and always exact.
        </p>
      </div>
      <ul class="hero-stats" aria-label="Current gate states" data-reveal>
{hero_items}
      </ul>
    </section>

    <section class="band" id="model">
      <div class="band-head">
        <p class="eyebrow">HOW THE GATES WORK</p>
        <h3>Floor and patch</h3>
      </div>
      <div class="card-grid">
        <article class="card">
          <h4>Floor — never regress</h4>
          <p>The current build is compared, per category, against the baseline
          committed on the base branch. Nothing may exceed what was there before.
          Per-category rather than per-total on purpose: paying down one kind of
          debt while quietly adding another nets flat but is exactly the
          regression worth catching.</p>
        </article>
        <article class="card">
          <h4>Patch — leave it cleaner</h4>
          <p>The lines a PR adds (the right side of <code>git diff</code>) are held
          to a stricter bar: zero new warnings, no new skips or dead code, and a
          minimum coverage ratio on new executable lines. Old debt pays down
          gradually under the floor; new code ships clean.</p>
        </article>
        <article class="card">
          <h4>Improvements lock in</h4>
          <p>A better number always passes. Regenerating the baseline
          (<code>make metrics-baseline</code>, <code>make perf-baseline</code>)
          records the gain so it becomes the new floor for later PRs. The base
          ceiling is read from the base branch, so bumping a baseline in the same
          PR can't wave a regression through.</p>
        </article>
      </div>
    </section>

    <section class="band" id="gates">
      <div class="band-head">
        <p class="eyebrow">THE GATES</p>
        <h3>What is quantified today</h3>
      </div>
      <div class="mgrid">
{gate_cards}
      </div>
    </section>

    <section class="band" id="coverage-detail">
      <div class="band-head">
        <p class="eyebrow">MEASURED STATE</p>
        <h3>Coverage by testable layer</h3>
      </div>
      <p class="mprovenance">Views are excluded — the unit suite can't reach them.
      Aggregate: <strong>{state['coverage']['testable_pct']:.2f}%</strong>
      ({state['coverage']['testable_covered']:,} of
      {state['coverage']['testable_count']:,} executable lines);
      {state['coverage']['uncovered_files']:,} files still carry uncovered lines.</p>
{render_coverage_table(state)}
    </section>

    <section class="band" id="deadcode-detail">
      <div class="band-head">
        <p class="eyebrow">MEASURED STATE</p>
        <h3>Dead code by kind</h3>
      </div>
      <p class="mprovenance">{dc['total']:,} findings across {dc['sites']:,} sites,
      reported by Periphery and frozen as the ceiling to ratchet down.</p>
{render_kv_table(("Kind", "Findings"), list(dc['counts'].items()), total=dc['total'])}
    </section>

    <section class="band" id="lint-detail">
      <div class="band-head">
        <p class="eyebrow">MEASURED STATE</p>
        <h3>Frozen lint debt by rule</h3>
      </div>
      <p class="mprovenance">{state['lint']['total']:,} pre-existing violations
      excluded via <code>swiftlint --baseline</code>; only new violations fail.
      Each rule's count is a ceiling that may shrink, never grow.</p>
{render_kv_table(("Rule", "Frozen"), list(state['lint']['by_rule'].items()), total=state['lint']['total'])}
    </section>

    <section class="band" id="perf-detail">
      <div class="band-head">
        <p class="eyebrow">MEASURED STATE</p>
        <h3>Performance op-count ceilings</h3>
      </div>
      <p class="mprovenance">Deterministic operation tallies over fixed-size
      fixtures. A count may fall (and re-baseline lower); it may never rise.</p>
{render_kv_table(("Counter", "Operations"), list(perf.items()))}
    </section>

    <section class="band" id="provenance">
      <div class="band-head">
        <p class="eyebrow">HOW THIS PAGE IS BUILT</p>
        <h3>Measured, then described</h3>
      </div>
      <div class="card-grid">
        <article class="card">
          <h4>Deterministic extraction</h4>
          <p>Every figure above is read directly from a committed state file —
          <code>metrics-baseline.json</code>, <code>perf-baseline.json</code>,
          <code>.swiftlint-baseline</code>, <code>.gitleaksignore</code> — by
          <code>scripts/build_metrics_page.py</code>. No build and no estimate:
          the numbers are exactly what CI ratchets against. <code>--check</code>
          fails if this page drifts from the baselines.</p>
        </article>
        <article class="card">
          <h4>Authored synthesis</h4>
          <p>The prose — what each gate measures, its floor and patch semantics,
          and why it exists — is written into the generator, because baselines
          record numbers, not intent. That is the half a state file can't
          produce on its own.</p>
        </article>
      </div>
    </section>

  </main>

  <footer>
    <p><strong>Portal</strong> — MIT licensed. Quality gates enforced by the Ratchet and Pages workflows.</p>
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
