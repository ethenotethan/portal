#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP=""
OUTPUT="$REPO_ROOT/dist/Portal-Installer.dmg"

usage() {
    cat <<'EOF'
Usage: build-macos-installer.sh --app /path/to/Portal.app [--output file.dmg]

Builds a distributable DMG containing Portal.app and a user-level setup command
that installs the app, managed Hermes fork, local API server, and launchd gateway.
The app must already be code signed; notarization is a separate release step.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --app) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; APP="$2"; shift ;;
        --output) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; OUTPUT="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

[ -n "$APP" ] || { printf 'Missing required --app path.\n' >&2; exit 2; }
[ -d "$APP" ] || { printf 'Portal app bundle not found: %s\n' "$APP" >&2; exit 1; }
command -v codesign >/dev/null 2>&1 || { printf 'codesign is required.\n' >&2; exit 1; }
command -v hdiutil >/dev/null 2>&1 || { printf 'hdiutil is required.\n' >&2; exit 1; }
command -v ditto >/dev/null 2>&1 || { printf 'ditto is required.\n' >&2; exit 1; }

codesign --verify --deep --strict "$APP"

case "$OUTPUT" in
    /*) ;;
    *) OUTPUT="$PWD/$OUTPUT" ;;
esac
mkdir -p "$(dirname "$OUTPUT")"
STAGE="${OUTPUT%.dmg}.stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Portal.app"
ditto "$REPO_ROOT/scripts/install-portal-stack.sh" "$STAGE/Set Up Portal.command"
ditto "$REPO_ROOT/scripts/configure-portal-gateway.py" "$STAGE/configure-portal-gateway.py"
chmod 755 "$STAGE/Set Up Portal.command"

printf '%s\n' \
    'PORTAL FOR macOS' \
    '' \
    '1. Double-click “Set Up Portal.command”.' \
    '2. Approve macOS opening the downloaded setup command if prompted.' \
    '3. Choose a Hermes model provider when setup opens.' \
    '4. Portal opens with the local gateway details prefilled; press Connect.' \
    '' \
    'Everything is installed for the current user. The setup command never uses sudo.' \
    'Hermes binds only to 127.0.0.1 and the generated API key is not printed.' \
    > "$STAGE/README.txt"

rm -f "$OUTPUT"
hdiutil create \
    -volname "Portal Installer" \
    -srcfolder "$STAGE" \
    -format UDZO \
    -ov \
    "$OUTPUT"

if [ "${PORTAL_KEEP_INSTALLER_STAGE:-0}" != "1" ]; then
    rm -rf "$STAGE"
fi
printf 'Created %s\n' "$OUTPUT"
