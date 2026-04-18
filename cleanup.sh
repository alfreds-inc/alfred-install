#!/usr/bin/env bash
set -euo pipefail
# cleanup.sh — Full cleanup of Alfred from this machine.
#
# Canonical public entrypoint:
#   curl -fsSL https://raw.githubusercontent.com/alfreds-inc/alfred-install/main/cleanup.sh | bash
#
# This script is STANDALONE — it does not depend on any other file in the repo,
# so it keeps working even as it deletes the Alfred repo checkout itself.
#
# Defaults remain narrow: only Alfred-owned state is removed. Shared tooling
# (Node, pnpm, nvm, gh, Alfred Intelligence CLI) is preserved unless you pass
# an explicit --purge-* flag.

case "$(uname -s)" in
  Darwin) OS_KIND="macos" ;;
  Linux)  OS_KIND="linux" ;;
  *)      OS_KIND="other" ;;
esac

LOCAL_DEFAULT_REPO_DIR="$HOME/.local/opt/alfred"
LOCAL_DEFAULT_WATCH_DIR="$HOME/Documents/Alfred"
LOCAL_DEFAULT_CLI_LAUNCHER="$HOME/.local/bin/alfred"
LOCAL_DEFAULT_DATA_DIR="$HOME/.local/share/alfred"

if [ "$OS_KIND" = "macos" ]; then
  LOCAL_DEFAULT_DATA_DIR="$HOME/Library/Application Support/Alfred"
fi

CLOUD_DEFAULT_REPO_DIR="/opt/alfred"
CLOUD_DEFAULT_DATA_DIR="/var/lib/alfred"
CLOUD_DEFAULT_CLI_LAUNCHER="/usr/local/bin/alfred"

INPUT_INSTALL_MODE="${ALFRED_INSTALL_MODE:-}"
INPUT_REPO_DIR="${ALFRED_REPO_DIR:-}"
INPUT_DATA_DIR="${ALFRED_DATA_DIR:-}"
INPUT_WATCH_DIR="${ALFRED_WATCH_DIR:-}"
INPUT_CLI_LAUNCHER_PATH="${ALFRED_CLI_LAUNCHER:-}"
INPUT_INSTALL_STATE_FILE="${ALFRED_INSTALL_STATE_FILE:-}"
INPUT_CLOUD_ENV_FILE="${ALFRED_CLOUD_ENV_FILE:-}"
INPUT_CLOUD_DECOMMISSION_URL="${ALFRED_CLOUD_DECOMMISSION_URL:-}"

INSTALL_MODE=""
REPO_DIR=""
DATA_DIR=""
WATCH_DIR=""
CLI_LAUNCHER_PATH=""
INSTALL_STATE_FILE=""
CLOUD_ENV_FILE=""
OPENCLAW_PARENT_DIR="${OPENCLAW_WORKSPACE_PARENT_DIR:-${OPENCLAW_WORKSPACE_DIR:-$HOME/.openclaw/workspace}}"
OPENCLAW_WORKSPACE_DIR="$OPENCLAW_PARENT_DIR/alfred"
SERVICE_MANAGER=""
SERVICE_UNITS_VALUE=""
LAUNCHD_LABELS_VALUE=""

CLOUD_API_BASE_URL=""
CLOUD_DECOMMISSION_URL=""
CLOUD_TENANT_SLUG=""
CLOUD_RUNTIME_ID=""
CLOUD_RUNTIME_SECRET=""

LAUNCHD_PLIST_PATH="$HOME/Library/LaunchAgents/com.sinapsys.alfred.dashboard.plist"
SYSTEMD_USER_UNIT_DIR="$HOME/.config/systemd/user"
SYSTEMD_SYSTEM_UNIT_DIR="/etc/systemd/system"

DEFAULT_DASHBOARD_PORT="${ALFRED_DASHBOARD_PORT:-${ALFRED_PORT:-3100}}"
DEFAULT_API_PORT="${ALFRED_API_PORT:-3101}"
TELEGRAM_TOKEN_FILE="$HOME/.openclaw/secrets/telegram-bot-token"

if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  SUDO=""
fi

DRY_RUN=0
YES=0
KEEP_REPO=0
KEEP_DATA_DIR=0
KEEP_WATCH_DIR=0
KEEP_OPENCLAW_WORKSPACE=0
KEEP_CLOUD_REGISTRATION=0
PURGE_OPENCLAW_CLI=0
PURGE_TELEGRAM_TOKEN=0
PURGE_NODE_TOOLS=0

usage() {
  cat <<EOF
Usage: bash cleanup.sh [options]

Remove Alfred from this machine, thoroughly enough for a clean reinstall.

The script understands both local and cloud installs. Cloud cleanup adds a
best-effort runtime decommission step before local files are removed unless you
pass --keep-cloud-registration.

By default the script removes only Alfred-owned state:
  • Alfred launchd plist (macOS) or systemd units (Linux)
  • running Alfred services
  • CLI launcher
  • Alfred repo checkout
  • repo .env.local (secrets)
  • runtime data dir
  • watch dir
  • Alfred Intelligence workspace

Shared tooling (Node, pnpm, nvm, gh, Alfred Intelligence CLI) is preserved
unless you pass an explicit --purge-* flag.

Options:
  --dry-run                      Show what would be removed, do nothing.
  -y, --yes                      Skip confirmation prompts.
  --keep-repo                    Don't remove the Alfred repo checkout.
  --keep-data-dir                Don't remove the Alfred runtime data dir.
  --keep-watch-dir               Don't remove the watch directory.
  --keep-intelligence-workspace  Don't remove the Alfred Intelligence workspace.
  --keep-cloud-registration      Cloud mode only: skip best-effort runtime decommission.
  --purge-intelligence-cli       Also remove the Alfred Intelligence CLI npm package.
  --purge-telegram-token         Also remove $TELEGRAM_TOKEN_FILE.
  --purge-node-tools             Also attempt to uninstall Node, pnpm, gh.
  --purge-all                    Shortcut: --purge-intelligence-cli
                                           --purge-telegram-token
                                           --purge-node-tools
  -h, --help                     Show this help.

Environment:
  ALFRED_INSTALL_STATE_FILE      Explicit install state file path
  ALFRED_REPO_DIR                Repo location override
  ALFRED_DATA_DIR                Runtime data dir override
  ALFRED_WATCH_DIR               Watch dir override
  ALFRED_CLI_LAUNCHER            CLI launcher override
  ALFRED_CLOUD_ENV_FILE          Explicit cloud bootstrap env path
  ALFRED_CLOUD_DECOMMISSION_URL  Explicit cloud decommission endpoint
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)                 DRY_RUN=1 ;;
    -y|--yes)                  YES=1 ;;
    --keep-repo)               KEEP_REPO=1 ;;
    --keep-data-dir)           KEEP_DATA_DIR=1 ;;
    --keep-watch-dir)          KEEP_WATCH_DIR=1 ;;
    --keep-intelligence-workspace|--keep-openclaw-workspace) KEEP_OPENCLAW_WORKSPACE=1 ;;
    --keep-cloud-registration) KEEP_CLOUD_REGISTRATION=1 ;;
    --purge-intelligence-cli|--purge-openclaw-cli)         PURGE_OPENCLAW_CLI=1 ;;
    --purge-telegram-token)    PURGE_TELEGRAM_TOKEN=1 ;;
    --purge-node-tools)        PURGE_NODE_TOOLS=1 ;;
    --purge-all)
      PURGE_OPENCLAW_CLI=1
      PURGE_TELEGRAM_TOKEN=1
      PURGE_NODE_TOOLS=1
      ;;
    -h|--help)                 usage; exit 0 ;;
    *)
      printf '[alfred-cleanup] ERROR: Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

say()  { printf '[alfred-cleanup] %s\n' "$*"; }
ok()   { printf '[alfred-cleanup] \xe2\x9c\x93 %s\n' "$*"; }
warn() { printf '[alfred-cleanup] WARN: %s\n' "$*"; }
plan() { printf '[alfred-cleanup] plan: %s\n' "$*"; }

run_with_sudo() {
  if [ -n "$SUDO" ]; then
    "$SUDO" "$@"
  else
    "$@"
  fi
}

load_env_file() {
  local file="$1"
  [ -f "$file" ] || return 1
  # shellcheck disable=SC1090
  . "$file"
}

discover_install_state_file() {
  if [ -n "$INPUT_INSTALL_STATE_FILE" ]; then
    printf '%s\n' "$INPUT_INSTALL_STATE_FILE"
    return
  fi

  if [ -n "$INPUT_DATA_DIR" ]; then
    printf '%s\n' "$INPUT_DATA_DIR/install/install-state.env"
    return
  fi

  if [ -f "$LOCAL_DEFAULT_DATA_DIR/install/install-state.env" ]; then
    printf '%s\n' "$LOCAL_DEFAULT_DATA_DIR/install/install-state.env"
    return
  fi

  if [ -f "$CLOUD_DEFAULT_DATA_DIR/install/install-state.env" ]; then
    printf '%s\n' "$CLOUD_DEFAULT_DATA_DIR/install/install-state.env"
    return
  fi

  printf '%s\n' "$LOCAL_DEFAULT_DATA_DIR/install/install-state.env"
}

default_install_mode() {
  if [ -n "$INPUT_INSTALL_MODE" ]; then
    printf '%s\n' "$INPUT_INSTALL_MODE"
    return
  fi

  if [ -f "$CLOUD_DEFAULT_DATA_DIR/install/install-state.env" ] && [ ! -f "$LOCAL_DEFAULT_DATA_DIR/install/install-state.env" ]; then
    printf '%s\n' "cloud"
    return
  fi

  printf '%s\n' "local"
}

resolve_defaults() {
  INSTALL_STATE_FILE="$(discover_install_state_file)"
  if [ -f "$INSTALL_STATE_FILE" ]; then
    load_env_file "$INSTALL_STATE_FILE" || true
  fi

  INSTALL_MODE="${INPUT_INSTALL_MODE:-${ALFRED_INSTALL_MODE:-$(default_install_mode)}}"
  case "$INSTALL_MODE" in
    local|cloud) ;;
    *) warn "Unknown install mode '$INSTALL_MODE' in overrides/state; falling back to local."; INSTALL_MODE="local" ;;
  esac

  if [ "$INSTALL_MODE" = "cloud" ]; then
    REPO_DIR="${INPUT_REPO_DIR:-${ALFRED_REPO_DIR:-$CLOUD_DEFAULT_REPO_DIR}}"
    DATA_DIR="${INPUT_DATA_DIR:-${ALFRED_DATA_DIR:-$CLOUD_DEFAULT_DATA_DIR}}"
    CLI_LAUNCHER_PATH="${INPUT_CLI_LAUNCHER_PATH:-${ALFRED_CLI_LAUNCHER:-$CLOUD_DEFAULT_CLI_LAUNCHER}}"
    SERVICE_MANAGER="${ALFRED_SERVICE_MANAGER:-systemd-system}"
    SERVICE_UNITS_VALUE="${ALFRED_SERVICE_UNITS:-alfred-api.service alfred-dashboard.service alfred-worker.service alfred-worker.timer alfred-proxy.service alfred-tunnel.service}"
  else
    REPO_DIR="${INPUT_REPO_DIR:-${ALFRED_REPO_DIR:-$LOCAL_DEFAULT_REPO_DIR}}"
    DATA_DIR="${INPUT_DATA_DIR:-${ALFRED_DATA_DIR:-$LOCAL_DEFAULT_DATA_DIR}}"
    CLI_LAUNCHER_PATH="${INPUT_CLI_LAUNCHER_PATH:-${ALFRED_CLI_LAUNCHER:-$LOCAL_DEFAULT_CLI_LAUNCHER}}"
    SERVICE_MANAGER="${ALFRED_SERVICE_MANAGER:-}"
    if [ -z "$SERVICE_MANAGER" ]; then
      if [ "$OS_KIND" = "macos" ]; then
        SERVICE_MANAGER="launchd"
      elif [ "$OS_KIND" = "linux" ]; then
        SERVICE_MANAGER="systemd-user"
      else
        SERVICE_MANAGER="manual"
      fi
    fi
    SERVICE_UNITS_VALUE="${ALFRED_SERVICE_UNITS:-alfred-api.service alfred-dashboard.service alfred-worker.service alfred-worker.timer}"
  fi

  WATCH_DIR="${INPUT_WATCH_DIR:-${ALFRED_WATCH_DIR:-$LOCAL_DEFAULT_WATCH_DIR}}"
  LAUNCHD_LABELS_VALUE="${ALFRED_LAUNCHD_LABELS:-com.sinapsys.alfred.dashboard}"
  CLOUD_ENV_FILE="${INPUT_CLOUD_ENV_FILE:-${ALFRED_CLOUD_ENV_FILE:-$DATA_DIR/config/cloud-bootstrap.env}}"

  if [ -f "$CLOUD_ENV_FILE" ]; then
    load_env_file "$CLOUD_ENV_FILE" || true
  fi

  OPENCLAW_PARENT_DIR="${OPENCLAW_WORKSPACE_PARENT_DIR:-$OPENCLAW_PARENT_DIR}"
  OPENCLAW_WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-$OPENCLAW_PARENT_DIR/alfred}"
  CLOUD_API_BASE_URL="${ALFRED_CLOUD_API_BASE_URL:-$CLOUD_API_BASE_URL}"
  CLOUD_DECOMMISSION_URL="${INPUT_CLOUD_DECOMMISSION_URL:-${ALFRED_CLOUD_DECOMMISSION_URL:-$CLOUD_DECOMMISSION_URL}}"
  CLOUD_TENANT_SLUG="${ALFRED_TENANT_SLUG:-$CLOUD_TENANT_SLUG}"
  CLOUD_RUNTIME_ID="${ALFRED_RUNTIME_ID:-$CLOUD_RUNTIME_ID}"
  CLOUD_RUNTIME_SECRET="${ALFRED_RUNTIME_SECRET:-$CLOUD_RUNTIME_SECRET}"
}

confirm() {
  local msg="$1"
  if [ "$YES" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi
  if ! [ -t 0 ] || ! [ -r /dev/tty ]; then
    warn "Non-interactive shell without -y; aborting to stay safe."
    exit 1
  fi
  printf '%s [y/N] ' "$msg" > /dev/tty
  local reply=""
  read -r reply < /dev/tty || reply=""
  [[ "$reply" =~ ^[Yy]$ ]]
}

run_cmd() {
  local label="$1"
  shift
  if [ "$DRY_RUN" -eq 1 ]; then
    plan "$label"
    return 0
  fi
  "$@"
}

path_needs_sudo() {
  local target="$1"
  if [ -e "$target" ] || [ -L "$target" ]; then
    [ -w "$target" ] && return 1
    return 0
  fi

  [ -w "$(dirname "$target")" ] && return 1
  return 0
}

rm_path() {
  local target="$1"
  local label="${2:-$target}"
  if [ -z "$target" ] || [ "$target" = "/" ] || [ "$target" = "$HOME" ]; then
    warn "Refusing to remove dangerous path: '$target' ($label)"
    return 0
  fi
  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    plan "rm -rf $target ($label)"
    return 0
  fi
  if path_needs_sudo "$target"; then
    run_with_sudo rm -rf -- "$target"
  else
    rm -rf -- "$target"
  fi
  ok "Removed $label ($target)"
}

decommission_url() {
  if [ -n "$CLOUD_DECOMMISSION_URL" ]; then
    printf '%s\n' "$CLOUD_DECOMMISSION_URL"
    return
  fi

  if [ -n "$CLOUD_API_BASE_URL" ] && [ -n "$CLOUD_RUNTIME_ID" ]; then
    printf '%s\n' "${CLOUD_API_BASE_URL%/}/v1/runtimes/$CLOUD_RUNTIME_ID/decommission"
  fi
}

summarize() {
  echo
  echo "Alfred cleanup plan"
  echo "==================="
  echo "  Mode:                  $INSTALL_MODE"
  echo "  Install state:         $INSTALL_STATE_FILE$( [ -f "$INSTALL_STATE_FILE" ] && echo ' [present]' || echo ' [missing]')"
  echo "  Repo:                  $REPO_DIR$( [ -d "$REPO_DIR/.git" ] && echo ' [present]' || echo ' [missing]')"
  echo "  Data dir:              $DATA_DIR$( [ -d "$DATA_DIR" ] && echo ' [present]' || echo ' [missing]')"
  echo "  Watch dir:             $WATCH_DIR$( [ -d "$WATCH_DIR" ] && echo ' [present]' || echo ' [missing]')"
  echo "  CLI launcher:          $CLI_LAUNCHER_PATH$( [ -e "$CLI_LAUNCHER_PATH" ] && echo ' [present]' || echo ' [missing]')"
  echo "  Service manager:       $SERVICE_MANAGER"
  echo "  Service units:         ${SERVICE_UNITS_VALUE:-<none>}"
  echo "  Intelligence ws:       $OPENCLAW_WORKSPACE_DIR$( [ -d "$OPENCLAW_WORKSPACE_DIR" ] && echo ' [present]' || echo ' [missing]')"
  if [ "$INSTALL_MODE" = "cloud" ]; then
    echo "  Cloud env:             $CLOUD_ENV_FILE$( [ -f "$CLOUD_ENV_FILE" ] && echo ' [present]' || echo ' [missing]')"
    echo "  Tenant slug:           ${CLOUD_TENANT_SLUG:-<unknown>}"
    echo "  Runtime id:            ${CLOUD_RUNTIME_ID:-<unknown>}"
    echo "  Decommission URL:      $(decommission_url)"
  fi
  echo
  echo "Flags: dry_run=$DRY_RUN yes=$YES"
  echo "       keep_repo=$KEEP_REPO keep_data=$KEEP_DATA_DIR keep_watch=$KEEP_WATCH_DIR keep_intelligence_workspace=$KEEP_OPENCLAW_WORKSPACE keep_cloud_registration=$KEEP_CLOUD_REGISTRATION"
  echo "       purge_intelligence_cli=$PURGE_OPENCLAW_CLI purge_telegram_token=$PURGE_TELEGRAM_TOKEN purge_node_tools=$PURGE_NODE_TOOLS"
  echo
}

stage_cloud_decommission() {
  local url payload
  [ "$INSTALL_MODE" = "cloud" ] || return 0
  [ "$KEEP_CLOUD_REGISTRATION" -eq 0 ] || { say "Keeping cloud runtime registration (--keep-cloud-registration)"; return 0; }

  url="$(decommission_url)"
  if [ -z "$url" ]; then
    warn "Cloud runtime registration cleanup skipped: no decommission endpoint configured."
    return 0
  fi
  if [ -z "$CLOUD_RUNTIME_ID" ] || [ -z "$CLOUD_RUNTIME_SECRET" ]; then
    warn "Cloud runtime registration cleanup skipped: runtime_id/runtime_secret not available."
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    warn "curl not found; skipping cloud runtime decommission."
    return 0
  fi

  payload=$(printf '{"runtime_id":"%s","tenant_slug":"%s","requested_at":"%s"}' \
    "$CLOUD_RUNTIME_ID" "$CLOUD_TENANT_SLUG" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")

  if [ "$DRY_RUN" -eq 1 ]; then
    plan "POST $url (best-effort cloud runtime decommission for $CLOUD_RUNTIME_ID)"
    return 0
  fi

  say "Attempting cloud runtime decommission for $CLOUD_RUNTIME_ID"
  if curl -fsSL \
    -H 'Content-Type: application/json' \
    -H "X-Alfred-Runtime-Id: $CLOUD_RUNTIME_ID" \
    -H "X-Alfred-Runtime-Secret: $CLOUD_RUNTIME_SECRET" \
    -X POST \
    --data "$payload" \
    "$url" >/dev/null 2>&1; then
    ok "Cloud runtime registration decommissioned"
  else
    warn "Cloud runtime decommission failed (ignored). Host cleanup will continue."
  fi
}

stage_stop_via_cli() {
  local bin=""
  if [ -x "$CLI_LAUNCHER_PATH" ]; then
    bin="$CLI_LAUNCHER_PATH"
  elif [ -x "$REPO_DIR/bin/alfred" ]; then
    bin="$REPO_DIR/bin/alfred"
  fi
  if [ -z "$bin" ]; then
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    plan "$bin stop --force  (graceful shutdown via Alfred CLI)"
    return 0
  fi
  say "Stopping Alfred via $bin stop --force"
  "$bin" stop --force >/dev/null 2>&1 || true
}

stage_stop_launchd() {
  local label domain plist_path
  [ "$SERVICE_MANAGER" = "launchd" ] || return 0
  domain="gui/$(id -u)"

  for label in $LAUNCHD_LABELS_VALUE; do
    plist_path="$HOME/Library/LaunchAgents/$label.plist"
    [ -f "$plist_path" ] || continue
    if [ "$DRY_RUN" -eq 1 ]; then
      plan "launchctl bootout $domain $plist_path"
      plan "rm $plist_path"
      continue
    fi
    say "Unloading launchd agent $label"
    launchctl bootout "$domain" "$plist_path" >/dev/null 2>&1 || true
    rm -f "$plist_path"
    ok "Removed launchd plist ($plist_path)"
  done
}

stage_stop_systemd() {
  local unit any unit_dir
  case "$SERVICE_MANAGER" in
    systemd-user) unit_dir="$SYSTEMD_USER_UNIT_DIR" ;;
    systemd-system) unit_dir="$SYSTEMD_SYSTEM_UNIT_DIR" ;;
    *) return 0 ;;
  esac

  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi

  any=0
  for unit in $SERVICE_UNITS_VALUE; do
    if [ -f "$unit_dir/$unit" ]; then
      any=1
      break
    fi
  done
  if [ "$any" -eq 0 ] && [ "$SERVICE_MANAGER" = "systemd-user" ]; then
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$SERVICE_MANAGER" = "systemd-system" ]; then
      plan "systemctl disable --now $SERVICE_UNITS_VALUE"
    else
      plan "systemctl --user disable --now $SERVICE_UNITS_VALUE"
    fi
    for unit in $SERVICE_UNITS_VALUE; do
      [ -f "$unit_dir/$unit" ] && plan "rm $unit_dir/$unit"
    done
    if [ "$SERVICE_MANAGER" = "systemd-system" ]; then
      plan "systemctl daemon-reload"
    else
      plan "systemctl --user daemon-reload"
    fi
    return 0
  fi

  say "Stopping + disabling Alfred systemd units"
  if [ "$SERVICE_MANAGER" = "systemd-system" ]; then
    run_with_sudo systemctl disable --now $SERVICE_UNITS_VALUE >/dev/null 2>&1 || true
  else
    systemctl --user disable --now $SERVICE_UNITS_VALUE >/dev/null 2>&1 || true
  fi

  for unit in $SERVICE_UNITS_VALUE; do
    if [ -f "$unit_dir/$unit" ]; then
      if [ "$SERVICE_MANAGER" = "systemd-system" ]; then
        run_with_sudo rm -f "$unit_dir/$unit"
      else
        rm -f "$unit_dir/$unit"
      fi
      ok "Removed $unit_dir/$unit"
    fi
  done

  if [ "$SERVICE_MANAGER" = "systemd-system" ]; then
    run_with_sudo systemctl daemon-reload >/dev/null 2>&1 || true
  else
    systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi
}

stage_free_ports() {
  local port pids="" pid
  command -v lsof >/dev/null 2>&1 || return 0

  for port in "$DEFAULT_DASHBOARD_PORT" "$DEFAULT_API_PORT"; do
    if [ "$SERVICE_MANAGER" = "systemd-system" ]; then
      pids="$(run_with_sudo lsof -ti "tcp:$port" 2>/dev/null || true)"
    else
      pids="$(lsof -ti "tcp:$port" -a -u "$USER" 2>/dev/null || true)"
    fi
    [ -n "$pids" ] || continue
    if [ "$DRY_RUN" -eq 1 ]; then
      plan "kill $pids  (still listening on :$port)"
      continue
    fi
    say "Killing leftover process on :$port (pids: $(echo "$pids" | tr '\n' ' '))"
    if [ "$SERVICE_MANAGER" = "systemd-system" ]; then
      for pid in $pids; do
        run_with_sudo kill "$pid" 2>/dev/null || true
      done
    else
      for pid in $pids; do
        kill "$pid" 2>/dev/null || true
      done
    fi
    sleep 2
    if [ "$SERVICE_MANAGER" = "systemd-system" ]; then
      pids="$(run_with_sudo lsof -ti "tcp:$port" 2>/dev/null || true)"
    else
      pids="$(lsof -ti "tcp:$port" -a -u "$USER" 2>/dev/null || true)"
    fi
    if [ -n "$pids" ]; then
      if [ "$SERVICE_MANAGER" = "systemd-system" ]; then
        for pid in $pids; do
          run_with_sudo kill -9 "$pid" 2>/dev/null || true
        done
      else
        for pid in $pids; do
          kill -9 "$pid" 2>/dev/null || true
        done
      fi
    fi
  done
}

stage_remove_cli_launcher() {
  rm_path "$CLI_LAUNCHER_PATH" "CLI launcher"
}

stage_remove_env_local() {
  local env_file="$REPO_DIR/.env.local"
  rm_path "$env_file" "repo .env.local"
}

stage_remove_data_dir() {
  [ "$KEEP_DATA_DIR" -eq 0 ] || { say "Keeping data dir (--keep-data-dir)"; return 0; }
  rm_path "$DATA_DIR" "data dir"
}

stage_remove_watch_dir() {
  [ "$KEEP_WATCH_DIR" -eq 0 ] || { say "Keeping watch dir (--keep-watch-dir)"; return 0; }
  rm_path "$WATCH_DIR" "watch dir"
}

stage_remove_openclaw_workspace() {
  [ "$KEEP_OPENCLAW_WORKSPACE" -eq 0 ] || { say "Keeping Alfred Intelligence workspace (--keep-intelligence-workspace)"; return 0; }

  case "$OPENCLAW_WORKSPACE_DIR" in
    */alfred) ;;
    *)
      warn "Intelligence workspace path does not end in /alfred — skipping to avoid removing an unrelated workspace: $OPENCLAW_WORKSPACE_DIR"
      return 0
      ;;
  esac
  rm_path "$OPENCLAW_WORKSPACE_DIR" "Alfred Intelligence workspace"
}

stage_remove_repo() {
  [ "$KEEP_REPO" -eq 0 ] || { say "Keeping repo (--keep-repo)"; return 0; }
  if [ ! -d "$REPO_DIR" ]; then
    return 0
  fi
  if [ ! -d "$REPO_DIR/.git" ]; then
    warn "Repo dir $REPO_DIR is not a git checkout; skipping to stay safe."
    return 0
  fi
  if [ ! -f "$REPO_DIR/scripts/install.sh" ] && [ ! -f "$REPO_DIR/scripts/install-openclaw.sh" ]; then
    warn "Repo at $REPO_DIR does not look like the Alfred repo (missing scripts/install.sh); skipping."
    return 0
  fi
  rm_path "$REPO_DIR" "Alfred repo checkout"
}

stage_purge_openclaw_cli() {
  [ "$PURGE_OPENCLAW_CLI" -eq 1 ] || return 0
  if ! command -v npm >/dev/null 2>&1; then
    say "npm not found, cannot uninstall Alfred Intelligence"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    plan "remove Alfred Intelligence CLI from the user-local npm prefix"
    plan "remove Alfred Intelligence CLI from the global npm prefix"
    return 0
  fi
  say "Uninstalling Alfred Intelligence CLI"
  npm uninstall -g --prefix "$HOME/.local" openclaw >/dev/null 2>&1 \
    || npm uninstall -g openclaw >/dev/null 2>&1 \
    || warn "npm uninstall failed (ignored)"
}

stage_purge_telegram_token() {
  [ "$PURGE_TELEGRAM_TOKEN" -eq 1 ] || return 0
  rm_path "$TELEGRAM_TOKEN_FILE" "Telegram bot token file"
}

stage_purge_node_tools() {
  [ "$PURGE_NODE_TOOLS" -eq 1 ] || return 0
  case "$OS_KIND" in
    macos)
      if ! command -v brew >/dev/null 2>&1; then
        warn "--purge-node-tools: Homebrew not found, skipping"
        return 0
      fi
      if [ "$DRY_RUN" -eq 1 ]; then
        plan "brew uninstall --ignore-dependencies node@22 pnpm gh  (best effort)"
        return 0
      fi
      say "Uninstalling node@22, pnpm, gh via Homebrew (best effort)"
      brew uninstall --ignore-dependencies node@22 2>/dev/null || true
      brew uninstall --ignore-dependencies pnpm   2>/dev/null || true
      brew uninstall --ignore-dependencies gh     2>/dev/null || true
      ;;
    linux)
      if command -v apt-get >/dev/null 2>&1; then
        if [ "$DRY_RUN" -eq 1 ]; then
          plan "sudo apt-get remove --purge -y nodejs gh  (best effort)"
          return 0
        fi
        say "Uninstalling nodejs, gh via apt-get (best effort)"
        run_with_sudo apt-get remove --purge -y nodejs gh >/dev/null 2>&1 || true
        run_with_sudo apt-get autoremove --purge -y >/dev/null 2>&1 || true
      else
        warn "--purge-node-tools: apt-get not found, skipping"
      fi
      ;;
    *)
      warn "--purge-node-tools: unsupported platform $OS_KIND, skipping"
      ;;
  esac
}

resolve_defaults
summarize

if [ "$DRY_RUN" -eq 1 ]; then
  say "Dry-run — no changes will be made."
fi

if [ "$INSTALL_MODE" = "cloud" ] && [ "$KEEP_DATA_DIR" -eq 0 ]; then
  warn "Cloud cleanup removes VM-local onboarding state, secrets, and chat history stored on this runtime."
fi

if [ "$DRY_RUN" -eq 0 ]; then
  if ! confirm "Proceed with Alfred cleanup?"; then
    say "Aborted."
    exit 0
  fi
fi

stage_cloud_decommission
stage_stop_via_cli
stage_stop_launchd
stage_stop_systemd
stage_free_ports

stage_remove_env_local

stage_remove_cli_launcher
stage_remove_data_dir
stage_remove_watch_dir
stage_remove_openclaw_workspace
stage_remove_repo

stage_purge_openclaw_cli
stage_purge_telegram_token
stage_purge_node_tools

echo
if [ "$DRY_RUN" -eq 1 ]; then
  ok "Dry-run complete. Re-run without --dry-run to apply."
else
  ok "Alfred cleanup complete."
  cat <<EOF

Reinstall from scratch with:
  curl -fsSL https://raw.githubusercontent.com/alfreds-inc/alfred-install/main/install.sh | bash

EOF
fi
