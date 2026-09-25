#!/bin/bash
set -euo pipefail

FORK_URL="${PORTAL_HERMES_FORK_URL:-https://github.com/ethenotethan/harness.git}"
FORK_BRANCH="${PORTAL_HERMES_FORK_BRANCH:-main}"
# Release-reviewed fork revision. Update this only after verifying /v1/ws and
# the installer contract against the new commit.
FORK_REVISION="${PORTAL_HERMES_FORK_REVISION:-e9afb320b32de7852d7f502a5632a323ab7abbf9}"
INSTALL_ROOT="${PORTAL_INSTALL_ROOT:-$HOME/Library/Application Support/Portal/hermes-agent}"
HERMES_HOME="${PORTAL_HERMES_HOME:-$HOME/Library/Application Support/Portal/hermes-home}"
APP_SUPPORT="${PORTAL_APP_SUPPORT:-$HOME/Library/Application Support/Portal}"
HERMES_BIN="${PORTAL_HERMES_BIN:-$INSTALL_ROOT/venv/bin/hermes}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIGURE_HELPER="$SCRIPT_DIR/configure-portal-gateway.py"
BUNDLED_APP="${PORTAL_BUNDLED_APP:-$SCRIPT_DIR/Portal.app}"
APPLICATIONS_DIR="${PORTAL_APPLICATIONS_DIR:-$HOME/Applications}"
SKIP_INSTALL="${PORTAL_SKIP_HERMES_INSTALL:-0}"
SKIP_HEALTHCHECK="${PORTAL_SKIP_GATEWAY_HEALTHCHECK:-0}"
NON_INTERACTIVE=0
SKIP_PROVIDER_SETUP=0
OPEN_PORTAL=1

usage() {
    cat <<'EOF'
Usage: install-portal-stack.sh [options]

Installs Portal's managed Hermes fork into the current macOS user account,
configures a loopback-only API server, installs the launchd gateway, and writes
a one-time mode-0600 handoff that Portal imports into the Keychain.

Options:
  --non-interactive       Fail rather than prompt for confirmation
  --skip-provider-setup   Do not launch Hermes model/provider setup
  --no-open               Do not open Portal when provisioning finishes
  -h, --help              Show this help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --non-interactive) NON_INTERACTIVE=1 ;;
        --skip-provider-setup) SKIP_PROVIDER_SETUP=1 ;;
        --no-open) OPEN_PORTAL=0 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

log() { printf '[Portal Setup] %s\n' "$*"; }
die() { printf '[Portal Setup] Error: %s\n' "$*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

[ "$(uname -s)" = "Darwin" ] || die "This installer supports macOS only."
[ "${EUID:-$(id -u)}" -ne 0 ] || die "Run this installer as your macOS user, not with sudo."
require_command python3
[ -f "$CONFIGURE_HELPER" ] || die "Gateway configuration helper is missing."

if [ "$NON_INTERACTIVE" -eq 0 ]; then
    printf 'Install Portal’s managed Hermes service for user %s? [Y/n] ' "$(id -un)"
    read -r answer
    case "$answer" in n|N|no|NO|No) exit 0 ;; esac
fi

mkdir -p "$APP_SUPPORT" "$HERMES_HOME"
chmod 700 "$APP_SUPPORT" "$HERMES_HOME"

if [ -d "$BUNDLED_APP" ]; then
    if [ "${PORTAL_SKIP_APP_SIGNATURE_CHECK:-0}" != "1" ]; then
        require_command codesign
        codesign --verify --deep --strict "$BUNDLED_APP" \
            || die "The bundled Portal.app failed code-signature verification."
    fi
    require_command ditto
    mkdir -p "$APPLICATIONS_DIR"
    app_target="$APPLICATIONS_DIR/Portal.app"
    app_staging="$APPLICATIONS_DIR/.Portal.app.installing.$$"
    app_backup="$APPLICATIONS_DIR/.Portal.app.previous.$$"
    rm -rf "$app_staging" "$app_backup"
    ditto "$BUNDLED_APP" "$app_staging"
    if [ -e "$app_target" ]; then
        mv "$app_target" "$app_backup"
    fi
    if mv "$app_staging" "$app_target"; then
        rm -rf "$app_backup"
        log "Installed Portal.app in $APPLICATIONS_DIR."
    else
        [ ! -e "$app_backup" ] || mv "$app_backup" "$app_target"
        die "Could not install Portal.app in $APPLICATIONS_DIR."
    fi
fi

if [ "$SKIP_INSTALL" != "1" ]; then
    require_command git
    if [ -n "${PORTAL_TEST_SOURCE:-}" ]; then
        [ "${PORTAL_INSTALLER_TESTING:-0}" = "1" ] || die "Test source override is disabled."
        [ -f "$PORTAL_TEST_SOURCE/scripts/install.sh" ] || die "Test checkout is invalid."
        rm -rf "$INSTALL_ROOT"
        mkdir -p "$INSTALL_ROOT"
        cp -R "$PORTAL_TEST_SOURCE/." "$INSTALL_ROOT/"
    elif [ -d "$INSTALL_ROOT/.git" ]; then
        origin="$(git -C "$INSTALL_ROOT" remote get-url origin 2>/dev/null || true)"
        case "$origin" in
            https://github.com/ethenotethan/harness|https://github.com/ethenotethan/harness.git|git@github.com:ethenotethan/harness.git) ;;
            *) die "Refusing to update unexpected checkout at $INSTALL_ROOT (origin: ${origin:-missing})." ;;
        esac
        [ -z "$(git -C "$INSTALL_ROOT" status --porcelain)" ] \
            || die "Refusing to update a managed Hermes checkout with local changes."
    elif [ -e "$INSTALL_ROOT" ]; then
        die "Install path exists but is not the Portal-managed Hermes checkout: $INSTALL_ROOT"
    else
        log "Cloning the managed Hermes fork…"
        mkdir -p "$(dirname "$INSTALL_ROOT")"
        git clone --depth 1 --branch "$FORK_BRANCH" "$FORK_URL" "$INSTALL_ROOT"
    fi

    if [ -z "${PORTAL_TEST_SOURCE:-}" ]; then
        # Execute the reviewed installer script itself, not whatever happens to
        # be at mutable branch HEAD when an older Portal DMG is opened.
        git -C "$INSTALL_ROOT" fetch --depth 1 origin "$FORK_REVISION"
        git -C "$INSTALL_ROOT" checkout --detach "$FORK_REVISION"
        [ "$(git -C "$INSTALL_ROOT" rev-parse HEAD)" = "$FORK_REVISION" ] \
            || die "Hermes checkout did not match the reviewed release revision."
    fi

    log "Installing Hermes runtime dependencies…"
    HERMES_HOME="$HERMES_HOME" bash "$INSTALL_ROOT/scripts/install.sh" \
        --non-interactive --dir "$INSTALL_ROOT" --hermes-home "$HERMES_HOME" \
        --branch "$FORK_BRANCH" --commit "$FORK_REVISION" --force-commit \
        --skip-setup --skip-browser
    if [ -z "${PORTAL_TEST_SOURCE:-}" ]; then
        installed_revision="$(git -C "$INSTALL_ROOT" rev-parse HEAD)"
        [ "$installed_revision" = "$FORK_REVISION" ] \
            || die "Hermes checkout did not resolve to the reviewed release revision."
    fi
fi

[ -x "$HERMES_BIN" ] || die "Hermes executable was not installed at $HERMES_BIN"

ENV_FILE="$HERMES_HOME/.env"
python3 "$CONFIGURE_HELPER" configure --env-file "$ENV_FILE" >/dev/null

if [ "$SKIP_PROVIDER_SETUP" -eq 0 ]; then
    log "Opening Hermes provider setup…"
    HERMES_HOME="$HERMES_HOME" "$HERMES_BIN" setup --portal
fi

log "Installing and starting the user gateway service…"
HERMES_HOME="$HERMES_HOME" "$HERMES_BIN" gateway install --force
HERMES_HOME="$HERMES_HOME" "$HERMES_BIN" gateway status --deep

if [ "$SKIP_HEALTHCHECK" != "1" ]; then
    require_command curl
    healthy=0
    for _ in $(seq 1 30); do
        if curl --silent --show-error --fail --max-time 1 \
            http://127.0.0.1:8642/health >/dev/null 2>&1; then
            healthy=1
            break
        fi
        sleep 1
    done
    [ "$healthy" -eq 1 ] || die "Gateway service started, but the local API health check did not pass."
fi

HANDOFF="$APP_SUPPORT/bootstrap.json"
python3 "$CONFIGURE_HELPER" handoff \
    --env-file "$ENV_FILE" --handoff-file "$HANDOFF" >/dev/null

log "Hermes is running locally. Portal will import the connection after you press Connect."
if [ "$OPEN_PORTAL" -eq 1 ]; then
    if [ -d "/Applications/Portal.app" ]; then
        open -a Portal
    elif [ -d "$HOME/Applications/Portal.app" ]; then
        open "$HOME/Applications/Portal.app"
    else
        log "Portal.app is not installed yet; open it after copying it to Applications."
    fi
fi
