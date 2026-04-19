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
OPENCLAW_CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}"
OPENCLAW_CONFIG_FILE="${OPENCLAW_CONFIG_PATH:-$OPENCLAW_CONFIG_DIR/openclaw.json}"
OPENCLAW_ENV_FILE="$OPENCLAW_CONFIG_DIR/.env"
OPENCLAW_SECRETS_DIR="$OPENCLAW_CONFIG_DIR/secrets"
OPENCLAW_GATEWAY_UNIT_FILE="$HOME/.config/systemd/user/openclaw-gateway.service"
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

if [ -t 1 ]; then
  TTY_RESET=$'\033[0m'
  TTY_BOLD=$'\033[1m'
  TTY_DIM=$'\033[2m'
  TTY_BLUE=$'\033[38;5;111m'
  TTY_GREEN=$'\033[38;5;34m'
  TTY_YELLOW=$'\033[38;5;214m'
else
  TTY_RESET=""
  TTY_BOLD=""
  TTY_DIM=""
  TTY_BLUE=""
  TTY_GREEN=""
  TTY_YELLOW=""
fi

CLEANUP_PREFIX="${TTY_DIM}[alfred-cleanup]${TTY_RESET}"
CLEANUP_RULE="────────────────────────────────────────"

fmt_path() {
  local p="${1:-}"
  if [ -z "$p" ]; then printf -- '—'; return; fi
  if [ -n "${HOME:-}" ] && [ "${p#$HOME}" != "$p" ]; then
    printf '~%s' "${p#$HOME}"
  else
    printf '%s' "$p"
  fi
}

fmt_presence() {
  local p="$1" kind="${2:-path}"
  case "$kind" in
    dir)   if [ -d "$p" ]; then printf '[present]'; else printf '[missing]'; fi ;;
    file)  if [ -f "$p" ]; then printf '[present]'; else printf '[missing]'; fi ;;
    git)   if [ -d "$p/.git" ]; then printf '[present]'; else printf '[missing]'; fi ;;
    any)   if [ -e "$p" ] || [ -L "$p" ]; then printf '[present]'; else printf '[missing]'; fi ;;
  esac
}

tty_header() {
  printf '\n%b->%b %b%s%b\n\n' "$TTY_BLUE" "$TTY_RESET" "$TTY_BOLD" "$1" "$TTY_RESET"
}

tty_rule() {
  printf '%s\n' "$CLEANUP_RULE"
}

tty_kv() {
  # tty_kv LABEL VALUE [HINT]
  local label="$1" value="${2:-—}" hint="${3:-}"
  if [ -n "$hint" ]; then
    printf '  %-20s %s  %b%s%b\n' "$label" "$value" "$TTY_DIM" "$hint" "$TTY_RESET"
  else
    printf '  %-20s %s\n' "$label" "$value"
  fi
}

tty_note() {
  printf '  %b%s%b\n' "$TTY_DIM" "$*" "$TTY_RESET"
}

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

say()  { printf '%b %s\n' "$CLEANUP_PREFIX" "$*"; }
ok()   { printf '%b %b✓%b %s\n' "$CLEANUP_PREFIX" "$TTY_GREEN" "$TTY_RESET" "$*"; }
warn() { printf '%b %b!%b %s\n' "$CLEANUP_PREFIX" "$TTY_YELLOW" "$TTY_RESET" "$*" >&2; }
plan() { printf '%b %bplan%b %s\n' "$CLEANUP_PREFIX" "$TTY_DIM" "$TTY_RESET" "$*"; }

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
  local default_yes="${2:-0}"
  if [ "$YES" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi
  if ! [ -t 0 ] || ! [ -r /dev/tty ]; then
    warn "Non-interactive shell without -y; aborting to stay safe."
    exit 1
  fi
  local hint='[y/N]'
  [ "$default_yes" = "1" ] && hint='[Y/n]'
  printf '%s %s ' "$msg" "$hint" > /dev/tty
  local reply=""
  read -r reply < /dev/tty || reply=""
  if [ "$default_yes" = "1" ]; then
    [[ -z "$reply" || "$reply" =~ ^[Yy]$ ]]
  else
    [[ "$reply" =~ ^[Yy]$ ]]
  fi
}

menu_can_prompt() {
  [ "$YES" -eq 1 ] && return 1
  [ "$DRY_RUN" -eq 1 ] && return 1
  # If CLI flags already flipped any toggle, treat CLI as the authoritative UI.
  if [ "$KEEP_REPO" -eq 1 ] \
     || [ "$KEEP_DATA_DIR" -eq 1 ] \
     || [ "$KEEP_WATCH_DIR" -eq 1 ] \
     || [ "$KEEP_OPENCLAW_WORKSPACE" -eq 1 ] \
     || [ "$KEEP_CLOUD_REGISTRATION" -eq 1 ] \
     || [ "$PURGE_OPENCLAW_CLI" -eq 1 ] \
     || [ "$PURGE_TELEGRAM_TOKEN" -eq 1 ] \
     || [ "$PURGE_NODE_TOOLS" -eq 1 ]; then
    return 1
  fi
  [ -t 0 ] && [ -r /dev/tty ] && return 0
  return 1
}

menu_mark() {
  # menu_mark FLAG_VALUE → prints "x" or " " in TTY box
  if [ "${1:-0}" = "1" ]; then
    printf '%bx%b' "$TTY_GREEN" "$TTY_RESET"
  else
    printf ' '
  fi
}

menu_row() {
  # menu_row NUMBER FLAG_VALUE NAME DESCRIPTION
  local num="$1" val="$2" name="$3" desc="$4"
  printf '  [%s] %d) %-32s %b%s%b\n' "$(menu_mark "$val")" "$num" "$name" "$TTY_DIM" "$desc" "$TTY_RESET"
}

menu_apply_preset() {
  # Reset then apply preset. Called with preset name.
  DRY_RUN=0
  KEEP_REPO=0
  KEEP_DATA_DIR=0
  KEEP_WATCH_DIR=0
  KEEP_OPENCLAW_WORKSPACE=0
  KEEP_CLOUD_REGISTRATION=0
  PURGE_OPENCLAW_CLI=0
  PURGE_TELEGRAM_TOKEN=0
  PURGE_NODE_TOOLS=0

  case "$1" in
    default) ;;
    keep_data)
      KEEP_DATA_DIR=1
      KEEP_WATCH_DIR=1
      KEEP_OPENCLAW_WORKSPACE=1
      ;;
    keep_repo)
      KEEP_REPO=1
      ;;
    full_purge)
      PURGE_OPENCLAW_CLI=1
      PURGE_TELEGRAM_TOKEN=1
      PURGE_NODE_TOOLS=1
      ;;
    dry_run)
      DRY_RUN=1
      ;;
  esac
}

menu_customize() {
  local reply
  while true; do
    tty_header "Customize flags"
    tty_note "press a number to toggle; empty line to continue; 'q' to go back"
    printf '\n'
    menu_row 1 "$DRY_RUN"                   "dry-run"                       "Preview only — nothing is changed."
    menu_row 2 "$KEEP_REPO"                 "keep-repo"                     "Don't remove the Alfred repo checkout."
    menu_row 3 "$KEEP_DATA_DIR"             "keep-data-dir"                 "Don't remove the runtime data dir (SQLite, secrets, chat)."
    menu_row 4 "$KEEP_WATCH_DIR"            "keep-watch-dir"                "Don't remove the watch directory."
    menu_row 5 "$KEEP_OPENCLAW_WORKSPACE"   "keep-intelligence-workspace"   "Don't remove the Alfred Intelligence workspace."
    menu_row 6 "$KEEP_CLOUD_REGISTRATION"   "keep-cloud-registration"       "Cloud only: skip runtime decommission."
    menu_row 7 "$PURGE_OPENCLAW_CLI"        "purge-intelligence-cli"        "Also remove the Alfred Intelligence CLI npm package."
    menu_row 8 "$PURGE_TELEGRAM_TOKEN"      "purge-telegram-token"          "Also remove $TELEGRAM_TOKEN_FILE."
    menu_row 9 "$PURGE_NODE_TOOLS"          "purge-node-tools"              "Also uninstall Node, pnpm, gh (best effort)."
    printf '\n'
    printf '> ' > /dev/tty
    read -r reply < /dev/tty || reply=""
    case "$reply" in
      "") return 0 ;;
      q|Q) return 1 ;;
      1) DRY_RUN=$((1 - DRY_RUN)) ;;
      2) KEEP_REPO=$((1 - KEEP_REPO)) ;;
      3) KEEP_DATA_DIR=$((1 - KEEP_DATA_DIR)) ;;
      4) KEEP_WATCH_DIR=$((1 - KEEP_WATCH_DIR)) ;;
      5) KEEP_OPENCLAW_WORKSPACE=$((1 - KEEP_OPENCLAW_WORKSPACE)) ;;
      6) KEEP_CLOUD_REGISTRATION=$((1 - KEEP_CLOUD_REGISTRATION)) ;;
      7) PURGE_OPENCLAW_CLI=$((1 - PURGE_OPENCLAW_CLI)) ;;
      8) PURGE_TELEGRAM_TOKEN=$((1 - PURGE_TELEGRAM_TOKEN)) ;;
      9) PURGE_NODE_TOOLS=$((1 - PURGE_NODE_TOOLS)) ;;
      *) tty_note "Unknown option: $reply" ;;
    esac
  done
}

interactive_menu() {
  menu_can_prompt || return 0

  while true; do
    tty_header "Choose what to clean"
    printf '  1) %-18s %b%s%b\n' "Default cleanup"   "$TTY_DIM" "Remove Alfred state; keep shared tooling. (recommended)" "$TTY_RESET"
    printf '  2) %-18s %b%s%b\n' "Keep user data"    "$TTY_DIM" "Preserve data dir, watch dir, and intelligence workspace." "$TTY_RESET"
    printf '  3) %-18s %b%s%b\n' "Keep the repo"     "$TTY_DIM" "Preserve the Alfred repo checkout." "$TTY_RESET"
    printf '  4) %-18s %b%s%b\n' "Full purge"        "$TTY_DIM" "Default + Intelligence CLI + Telegram token + Node tools." "$TTY_RESET"
    printf '  5) %-18s %b%s%b\n' "Dry run"           "$TTY_DIM" "Preview only — no changes." "$TTY_RESET"
    printf '  6) %-18s %b%s%b\n' "Custom..."         "$TTY_DIM" "Toggle individual flags one by one." "$TTY_RESET"
    printf '  0) %-18s %b%s%b\n' "Abort"             "$TTY_DIM" "Quit without changes." "$TTY_RESET"
    printf '\nSelect [1]: ' > /dev/tty
    local reply=""
    read -r reply < /dev/tty || reply=""
    case "${reply:-1}" in
      1) menu_apply_preset default;     return 0 ;;
      2) menu_apply_preset keep_data;   return 0 ;;
      3) menu_apply_preset keep_repo;   return 0 ;;
      4) menu_apply_preset full_purge;  return 0 ;;
      5) menu_apply_preset dry_run;     return 0 ;;
      6) menu_customize && return 0 ;;
      0|q|Q) say "Aborted."; exit 0 ;;
      *) tty_note "Unknown option: $reply"; printf '\n' ;;
    esac
  done
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

rm_empty_dir() {
  local target="$1"
  local label="${2:-$target}"

  [ -n "$target" ] || return 0
  [ -d "$target" ] || return 0
  [ "$(realpath "$target" 2>/dev/null || printf '%s' "$target")" != "$HOME" ] || return 0
  [ -z "$(ls -A "$target" 2>/dev/null)" ] || return 0

  if [ "$DRY_RUN" -eq 1 ]; then
    plan "rmdir $target ($label)"
    return 0
  fi

  if path_needs_sudo "$target"; then
    run_with_sudo rmdir "$target" 2>/dev/null || true
  else
    rmdir "$target" 2>/dev/null || true
  fi

  if [ ! -d "$target" ]; then
    ok "Removed empty $label ($target)"
  fi
}

openclaw_runtime_owned_by_alfred() {
  if [ -d "$OPENCLAW_WORKSPACE_DIR" ]; then
    return 0
  fi

  if [ -f "$OPENCLAW_CONFIG_FILE" ]; then
    grep -Fqs "$OPENCLAW_WORKSPACE_DIR" "$OPENCLAW_CONFIG_FILE" && return 0
    grep -Eq '"workspace"[[:space:]]*:[[:space:]]*".*/alfred"' "$OPENCLAW_CONFIG_FILE" && return 0
  fi

  return 1
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
  tty_header "Alfred cleanup plan"
  tty_kv "Mode"            "$INSTALL_MODE"
  tty_kv "Install state"   "$(fmt_path "$INSTALL_STATE_FILE")"   "$(fmt_presence "$INSTALL_STATE_FILE" file)"
  tty_kv "Repo"            "$(fmt_path "$REPO_DIR")"             "$(fmt_presence "$REPO_DIR" git)"
  tty_kv "Data dir"        "$(fmt_path "$DATA_DIR")"             "$(fmt_presence "$DATA_DIR" dir)"
  tty_kv "Watch dir"       "$(fmt_path "$WATCH_DIR")"            "$(fmt_presence "$WATCH_DIR" dir)"
  tty_kv "CLI launcher"    "$(fmt_path "$CLI_LAUNCHER_PATH")"    "$(fmt_presence "$CLI_LAUNCHER_PATH" any)"
  tty_kv "Service manager" "$SERVICE_MANAGER"
  tty_kv "Service units"   "${SERVICE_UNITS_VALUE:-<none>}"
  tty_kv "Intelligence ws" "$(fmt_path "$OPENCLAW_WORKSPACE_DIR")" "$(fmt_presence "$OPENCLAW_WORKSPACE_DIR" dir)"
  if [ "$INSTALL_MODE" = "cloud" ]; then
    tty_kv "Cloud env"       "$(fmt_path "$CLOUD_ENV_FILE")"       "$(fmt_presence "$CLOUD_ENV_FILE" file)"
    tty_kv "Tenant slug"     "${CLOUD_TENANT_SLUG:-<unknown>}"
    tty_kv "Runtime id"      "${CLOUD_RUNTIME_ID:-<unknown>}"
    tty_kv "Decommission URL" "$(decommission_url)"
  fi

  printf '\n'
  tty_note "flags: dry_run=$DRY_RUN  yes=$YES"
  tty_note "       keep_repo=$KEEP_REPO  keep_data=$KEEP_DATA_DIR  keep_watch=$KEEP_WATCH_DIR  keep_intel=$KEEP_OPENCLAW_WORKSPACE  keep_cloud=$KEEP_CLOUD_REGISTRATION"
  tty_note "       purge_intel=$PURGE_OPENCLAW_CLI  purge_telegram=$PURGE_TELEGRAM_TOKEN  purge_node=$PURGE_NODE_TOOLS"
  printf '\n'
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

stage_remove_openclaw_runtime_state() {
  if ! openclaw_runtime_owned_by_alfred; then
    return 0
  fi

  if [ -f "$OPENCLAW_GATEWAY_UNIT_FILE" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      plan "systemctl --user disable --now openclaw-gateway.service"
      plan "rm $OPENCLAW_GATEWAY_UNIT_FILE (Alfred Intelligence gateway unit)"
    else
      if command -v systemctl >/dev/null 2>&1; then
        systemctl --user disable --now openclaw-gateway.service >/dev/null 2>&1 || true
      fi
      rm -f "$OPENCLAW_GATEWAY_UNIT_FILE"
      if command -v systemctl >/dev/null 2>&1; then
        systemctl --user daemon-reload >/dev/null 2>&1 || true
      fi
      ok "Removed Alfred Intelligence gateway unit ($OPENCLAW_GATEWAY_UNIT_FILE)"
    fi
  fi

  rm_path "$OPENCLAW_CONFIG_FILE" "Alfred Intelligence config"
  rm_path "$OPENCLAW_ENV_FILE" "Alfred Intelligence env file"

  rm_empty_dir "$OPENCLAW_SECRETS_DIR" "Alfred Intelligence secrets dir"
  rm_empty_dir "$OPENCLAW_PARENT_DIR" "Alfred Intelligence workspace parent"
  rm_empty_dir "$OPENCLAW_CONFIG_DIR/workspace" "Alfred Intelligence workspace root"
  rm_empty_dir "$OPENCLAW_CONFIG_DIR" "Alfred Intelligence home"
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
  rm_empty_dir "$OPENCLAW_SECRETS_DIR" "Alfred Intelligence secrets dir"
  rm_empty_dir "$OPENCLAW_PARENT_DIR" "Alfred Intelligence workspace parent"
  rm_empty_dir "$OPENCLAW_CONFIG_DIR/workspace" "Alfred Intelligence workspace root"
  rm_empty_dir "$OPENCLAW_CONFIG_DIR" "Alfred Intelligence home"
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
interactive_menu
summarize

if [ "$DRY_RUN" -eq 1 ]; then
  say "Dry-run — no changes will be made."
fi

if [ "$INSTALL_MODE" = "cloud" ] && [ "$KEEP_DATA_DIR" -eq 0 ]; then
  warn "Cloud cleanup removes VM-local onboarding state, secrets, and chat history stored on this runtime."
fi

if [ "$DRY_RUN" -eq 0 ]; then
  if ! confirm "Apply the plan above?" 1; then
    say "Aborted."
    exit 0
  fi
fi

tty_header "Stopping services"
stage_cloud_decommission
stage_stop_via_cli
stage_stop_launchd
stage_stop_systemd
stage_free_ports

tty_header "Removing Alfred state"
stage_remove_env_local
stage_remove_cli_launcher
stage_remove_data_dir
stage_remove_watch_dir
stage_remove_openclaw_workspace
stage_remove_openclaw_runtime_state
stage_remove_repo

if [ "$PURGE_OPENCLAW_CLI" -eq 1 ] || [ "$PURGE_TELEGRAM_TOKEN" -eq 1 ] || [ "$PURGE_NODE_TOOLS" -eq 1 ]; then
  tty_header "Purging optional components"
  stage_purge_openclaw_cli
  stage_purge_telegram_token
  stage_purge_node_tools
fi

printf '\n'
tty_rule
if [ "$DRY_RUN" -eq 1 ]; then
  ok "Dry-run complete. Re-run without --dry-run to apply."
else
  ok "Alfred cleanup complete."
  printf '\n'
  tty_note "Reinstall from scratch with:"
  printf '  %bcurl -fsSL https://raw.githubusercontent.com/alfreds-inc/alfred-install/main/install.sh | bash%b\n\n' "$TTY_BOLD" "$TTY_RESET"
fi
