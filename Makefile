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

.PHONY: generate build run kill lint test clean

# Regenerate the Xcode project from project.yml (needed after adding files).
generate:
	xcodegen generate

# Build the macOS app (Debug).
build:
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

# Match CI exactly: strict lint + strict-concurrency SwiftPM build.
# Run this before pushing — local xcodebuild Debug is more lenient than CI.
lint:
	swiftlint lint --strict

test:
	swift build --build-tests

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME_MAC) clean
