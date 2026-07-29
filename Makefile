# Convenience targets for local dev.
#
# The big one is `make run`: it ALWAYS rebuilds before launching, then opens
# the freshly-built .app. macOS will happily keep running a stale binary if you
# just double-click the old .app or `open` it by path, which has repeatedly
# masked already-fixed bugs (e.g. the chat-input beachball) behind an old
# build. `make run` guarantees you're running current source.

PROJECT := Portal.xcodeproj
SCHEME_MAC := Portal
CONFIG := Debug
DERIVED := $(HOME)/Library/Developer/Xcode/DerivedData

.PHONY: generate build run kill lint lint-fix lint-baseline lint-baseline-guard test check clean diagnose-hang metrics-ratchet metrics-baseline

# Regenerate the Xcode project from project.yml (needed after adding files).
generate:
	xcodegen generate

# Build the macOS app (Debug). Regenerates the project first so newly-added
# source files are always picked up — the checked-in .xcodeproj can lag behind
# project.yml / the Sources tree, and xcodebuild then fails with "cannot find
# <Type> in scope" even though `swift build` (which globs the dir) succeeds.
build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME_MAC) -configuration $(CONFIG) \
		-destination 'platform=macOS' build

# Rebuild from current source, then relaunch. Kills any running instance first
# so you never end up staring at a stale binary.
#
# We ask xcodebuild itself where the product is (BUILT_PRODUCTS_DIR) instead of
# `find`-ing DerivedData: there is one HermesNative-<hash> dir PER checkout path,
# and `find | head -1` returns them in inode order, NOT by build time — so it
# repeatedly launched a stale sibling checkout's app while today's build sat in a
# different hash dir. -showBuildSettings resolves the exact dir for THIS project.
run: kill build
	@DIR=$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME_MAC) -configuration $(CONFIG) \
		-destination 'platform=macOS' -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $$2; exit}'); \
	APP="$$DIR/$(SCHEME_MAC).app"; \
	echo "launching $$APP"; \
	open "$$APP"

# Terminate any running instance (main app process, not WebKit helpers).
kill:
	@pkill -f "$(SCHEME_MAC).app/Contents/MacOS" 2>/dev/null || true

# Match CI exactly: strict lint, gated on the baseline so only NEW violations
# fail. Existing debt is frozen in .swiftlint-baseline (see make lint-baseline).
# Run this before pushing — local xcodebuild Debug is more lenient than CI.
lint:
	swiftlint lint --strict --baseline .swiftlint-baseline

# Fail if the baseline gained frozen violations versus main — i.e. a new
# violation was baselined instead of fixed, silently defeating a rule. Paying
# debt down (fewer entries) passes. CI runs the same check; run it locally
# after `make lint-baseline` to confirm the diff only ever REMOVES entries.
lint-baseline-guard:
	python3 scripts/check-baseline-growth.py origin/main

# Auto-fix the mechanical violations (whitespace, redundant annotations, etc.).
# Run this instead of hand-editing style nits — safe, idempotent, and it never
# touches the semantic rules. Re-run `make lint` afterward to see what's left.
lint-fix:
	swiftlint lint --fix

# Regenerate the frozen-debt baseline. Run ONLY when you have deliberately paid
# down existing violations (the count should shrink) — never to silence a new
# violation you just introduced. Review the git diff: it should only ever
# remove entries. Adding entries here is how strictness silently rots.
#
# SwiftLint's --write-baseline stores ABSOLUTE file:// URLs. Committed as-is,
# the baseline only matches on the machine that wrote it — on CI (checkout at
# /Users/runner/work/...) not one path matches, so the baseline excludes
# NOTHING and every frozen violation fails (this is what broke #222). The sed
# step strips the repo prefix to repo-relative paths so the baseline is
# portable across checkouts. Keep it: a raw --write-baseline is not committable.
lint-baseline:
	@# --write-baseline exits non-zero when serious violations exist; that's
	@# expected here (we're recording them), so don't let it abort the recipe.
	-swiftlint lint --write-baseline .swiftlint-baseline
	@python3 -c "import os,pathlib; p=pathlib.Path('.swiftlint-baseline'); d=p.read_text(); pre='file://'+os.getcwd()+'/'; d2=d.replace(pre, '').replace(pre.replace('/', r'\\/'), ''); p.write_text(d2); assert 'file://' not in d2 and 'file:\\\\/\\\\/' not in d2, 'baseline still has absolute file:// paths — not portable'; print('paths made repo-relative')"
	@echo "Baseline rewritten (paths made repo-relative). Check 'git diff .swiftlint-baseline' — entries should only DISAPPEAR."

# Secret-scan ratchet. Scans the working tree with gitleaks; .gitleaksignore
# freezes ACCEPTED false-positive fingerprints (currently none — the tree is
# clean), so only NEW, un-accepted findings fail. Run before pushing; CI runs
# the same scan with a pinned gitleaks version. Install: `brew install gitleaks`.
secret-scan:
	gitleaks dir . --config .gitleaks.toml --gitleaks-ignore-path .gitleaksignore \
		--no-banner --redact --exit-code 1

# Fail if .gitleaksignore gained accepted fingerprints versus main — i.e. a new
# finding was waved through instead of removed. Removing entries (a finding was
# fixed) passes. CI runs the same check; run it locally after editing the
# ignore file to confirm the diff only ever REMOVES fingerprints.
secret-scan-guard:
	python3 scripts/check-secret-baseline-growth.py origin/main

test:
	swift build --build-tests
	swift test --disable-sandbox

# Metric ratchet: fail if a tracked code-health metric regressed vs the base
# branch. Two metrics are wired:
#   warnings — compiler warning sites (floor: no category grows; patch: no
#              warning on a line this PR added). A CLEAN build is mandatory —
#              incremental builds skip unchanged modules and under-count, so we
#              wipe .build first.
#   coverage — testable-layer line coverage (floor: aggregate can't erode;
#              patch: >=80% of executable lines this PR added must be covered).
# Mirrors the lint-baseline pattern; frozen values live in metrics-baseline.json.
# See scripts/check-metrics-ratchet.py.
metrics-ratchet:
	rm -rf .build
	swift build 2>&1 | tee /tmp/portal-metrics-build.log
	python3 scripts/collect-warnings.py /tmp/portal-metrics-build.log --root "$(PWD)" --json /tmp/portal-warnings.json
	swift test --enable-code-coverage 2>&1 | tail -3
	$(call export-coverage)
	python3 scripts/collect-coverage.py /tmp/portal-cov-export.json --root "$(PWD)" --json /tmp/portal-coverage.json
	python3 scripts/check-metrics-ratchet.py --warnings /tmp/portal-warnings.json --coverage /tmp/portal-coverage.json --base origin/main

# Resolve the coverage profdata + test binary that `swift test
# --enable-code-coverage` produced and export the full per-line report (no
# -summary-only — the patch check needs segments). Shared by the two targets.
define export-coverage
	PROF=$$(find .build -name '*.profdata' | head -1); \
	BIN=$$(find .build -name '*.xctest' -type d | head -1); \
	EXE="$$BIN/Contents/MacOS/$$(basename "$$BIN" .xctest)"; \
	xcrun llvm-cov export -instr-profile "$$PROF" "$$EXE" > /tmp/portal-cov-export.json
endef

# Regenerate the frozen metric baseline. Run ONLY when you have deliberately
# improved a metric (paid down warnings, added tests) and want to lock in the
# gain, exactly like `make lint-baseline`. Requires a clean build for an honest
# warning count. Rewrites BOTH the warnings and coverage keys.
metrics-baseline:
	rm -rf .build
	swift build 2>&1 | tee /tmp/portal-metrics-build.log
	python3 scripts/collect-warnings.py /tmp/portal-metrics-build.log --root "$(PWD)" --json /tmp/portal-warnings.json
	swift test --enable-code-coverage 2>&1 | tail -3
	$(call export-coverage)
	python3 scripts/collect-coverage.py /tmp/portal-cov-export.json --root "$(PWD)" --json /tmp/portal-coverage.json
	@python3 -c "import json; w=json.load(open('/tmp/portal-warnings.json')); c=json.load(open('/tmp/portal-coverage.json')); b=json.load(open('metrics-baseline.json')); b['warnings']=w; b['coverage']=c; open('metrics-baseline.json','w').write(json.dumps(b,indent=2)+chr(10)); print('metrics-baseline.json updated:', w['total'], 'warning sites,', str(c['testable_pct'])+'% testable coverage')"
	@echo "Baseline rewritten. Check 'git diff metrics-baseline.json' — warnings should only DROP, coverage only RISE."

# One command an agent (or human) runs before pushing — the whole CI gate:
# strict-concurrency build, tests, and baselined lint. If this is green, CI is.
check: lint lint-baseline-guard
	swift build
	swift build --build-tests
	swift test --disable-sandbox
	@echo "✓ check passed — build, tests, and lint all green"

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME_MAC) clean

# Beachball triage in one shot. When the UI spins, this assembles the context
# a programming agent needs to localize it WITHOUT a debugger: (1) the
# MainThreadWatchdog's captured hang stacks from the unified log, (2) a static
# scan for the known hang anti-patterns, (3) recent Views/perf churn. Pass a
# look-back window in minutes: `make diagnose-hang MIN=30`.
diagnose-hang:
	@bash scripts/diagnose-hang.sh $(MIN)
