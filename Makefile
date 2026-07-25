# Convenience targets for local dev.
#
# The big one is `make run`: it ALWAYS rebuilds before launching, then opens
# the freshly-built .app. macOS will happily keep running a stale binary if you
# just double-click the old .app or `open` it by path, which has repeatedly
# masked already-fixed bugs (e.g. the chat-input beachball) behind an old
# build. `make run` guarantees you're running current source.

PROJECT := HermesNative.xcodeproj
SCHEME_MAC := HermesNative-macOS
CONFIG := Debug
DERIVED := $(HOME)/Library/Developer/Xcode/DerivedData

.PHONY: generate build run kill lint lint-fix lint-baseline test check clean

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
run: kill build
	@APP=$$(find $(DERIVED)/HermesNative-*/Build/Products/$(CONFIG) \
		-name "$(SCHEME_MAC).app" -maxdepth 1 2>/dev/null | head -1); \
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

test:
	swift build --build-tests
	swift test --disable-sandbox

# One command an agent (or human) runs before pushing — the whole CI gate:
# strict-concurrency build, tests, and baselined lint. If this is green, CI is.
check: lint
	swift build
	swift build --build-tests
	swift test --disable-sandbox
	@echo "✓ check passed — build, tests, and lint all green"

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME_MAC) clean
