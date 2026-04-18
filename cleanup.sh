#!/usr/bin/env bash
set -euo pipefail
# cleanup.sh — Full cleanup of Alfred from this machine.
#
# Canonical public entrypoint:
#   curl -fsSL https://raw.githubusercontent.com/sinapsysxyz/alfred-install/main/cleanup.sh | bash
#
# This script is STANDALONE — it does not depend on any other file in the repo,
# so it keeps working even as it deletes the Alfred repo checkout itself.
#
# Defaults are narrow: only Alfred-owned state is removed. Shared tooling
# (Node, pnpm, nvm, gh, global @openclaw/cli) is preserved unless you pass
# an explicit --purge-* flag. Run with --dry-run first if unsure.

# ── Defaults (may be overridden by env + flags) ──────────────────────────────
case "$(uname -s)" in
  Darwin) OS_KIND="macos"; DEFAULT_DATA_DIR="$HOME/Library/Application Support/Alfred" ;;
  Linux)  OS_KIND="linux"; DEFAULT_DATA_DIR="$HOME/.local/share/alfred" ;;
  *)      OS_KIND="other"; DEFAULT_DATA_DIR="$HOME/.local/share/alfred" ;;
esac

REPO_DIR="${ALFRED_REPO_DIR:-$HOME/.local/opt/alfred}"
DATA_DIR="${ALFRED_DATA_DIR:-$DEFAULT_DATA_DIR}"
WATCH_DIR="${ALFRED_WATCH_DIR:-$HOME/Documents/Alfred}"
CLI_LAUNCHER_PATH="${ALFRED_CLI_LAUNCHER:-$HOME/.local/bin/alfred}"

DEFAULT_OPENCLAW_PARENT_DIR="$HOME/.openclaw/workspace"
OPENCLAW_PARENT_DIR="${OPENCLAW_WORKSPACE_PARENT_DIR:-${OPENCLAW_WORKSPACE_DIR:-$DEFAULT_OPENCLAW_PARENT_DIR}}"
OPENCLAW_WORKSPACE_DIR="$OPENCLAW_PARENT_DIR/alfred"

LAUNCHD_LABEL="com.sinapsys.alfred.dashboard"
LAUNCHD_PLIST_PATH="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"
SYSTEMD_UNIT_DIR="$HOME/.config/systemd/user"
SYSTEMD_UNITS=(alfred-api.service alfred-dashboard.service alfred-worker.service alfred-worker.timer)

DEFAULT_DASHBOARD_PORT="${ALFRED_DASHBOARD_PORT:-${ALFRED_PORT:-3100}}"
DEFAULT_API_PORT="${ALFRED_API_PORT:-3101}"

TELEGRAM_TOKEN_FILE="$HOME/.openclaw/secrets/telegram-bot-token"

# ── Flags ────────────────────────────────────────────────────────────────────
DRY_RUN=0
YES=0
KEEP_REPO=0
KEEP_DATA_DIR=0
KEEP_WATCH_DIR=0
KEEP_OPENCLAW_WORKSPACE=0
PURGE_OPENCLAW_CLI=0
PURGE_TELEGRAM_TOKEN=0
PURGE_NODE_TOOLS=0

usage() {
  cat <<EOF
Usage: bash cleanup.sh [options]

Remove Alfred from this machine, thoroughly enough for a clean reinstall.

By default the script removes only Alfred-owned state:
  • Alfred launchd plist (macOS) or systemd user units (Linux)
  • running Alfred API/dashboard processes
  • CLI launcher at $CLI_LAUNCHER_PATH
  • Alfred repo checkout at $REPO_DIR
  • repo .env.local (secrets)
  • runtime data dir at $DATA_DIR
  • watch dir at $WATCH_DIR
  • OpenClaw workspace at $OPENCLAW_WORKSPACE_DIR

Shared tooling (Node, pnpm, nvm, gh, global @openclaw/cli) is preserved
unless you pass an explicit --purge-* flag, because removing it can break
other projects on the same machine.

Options:
  --dry-run                      Show what would be removed, do nothing.
  -y, --yes                      Skip confirmation prompts.
  --keep-repo                    Don't remove the Alfred repo checkout.
  --keep-data-dir                Don't remove the Alfred runtime data dir.
  --keep-watch-dir               Don't remove the watch directory.
                                 Useful if it holds personal files outside
                                 entity-specific subfolders.
  --keep-openclaw-workspace      Don't remove the Alfred OpenClaw workspace.
  --purge-openclaw-cli           Also run 'npm uninstall -g @openclaw/cli'.
  --purge-telegram-token         Also remove $TELEGRAM_TOKEN_FILE.
                                 Only do this if Alfred was the sole OpenClaw
                                 consumer on this machine.
  --purge-node-tools             Also attempt to uninstall Node, pnpm, gh.
                                 Macros: Homebrew on macOS, apt on Linux. Best
                                 effort; skipped on other platforms.
  --purge-all                    Shortcut: --purge-openclaw-cli
                                           --purge-telegram-token
                                           --purge-node-tools
  -h, --help                     Show this help.

Environment:
  ALFRED_REPO_DIR                Repo location   (default: $REPO_DIR)
  ALFRED_DATA_DIR                Runtime data    (default: $DATA_DIR)
  ALFRED_WATCH_DIR               Watch dir       (default: $WATCH_DIR)
  ALFRED_CLI_LAUNCHER            CLI launcher    (default: $CLI_LAUNCHER_PATH)
  OPENCLAW_WORKSPACE_PARENT_DIR  OpenClaw parent dir (preferred)
  OPENCLAW_WORKSPACE_DIR         Legacy alias for the parent dir

Examples:
  bash cleanup.sh --dry-run                 # preview only
  bash cleanup.sh -y                        # full default cleanup, no prompts
  bash cleanup.sh -y --keep-watch-dir       # preserve personal documents
  bash cleanup.sh -y --purge-all            # everything including shared tooling
  curl -fsSL https://raw.githubusercontent.com/sinapsysxyz/alfred-install/main/cleanup.sh | bash -s -- -y
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)                 DRY_RUN=1 ;;
    -y|--yes)                  YES=1 ;;
    --keep-repo)               KEEP_REPO=1 ;;
    --keep-data-dir)           KEEP_DATA_DIR=1 ;;
    --keep-watch-dir)          KEEP_WATCH_DIR=1 ;;
    --keep-openclaw-workspace) KEEP_OPENCLAW_WORKSPACE=1 ;;
    --purge-openclaw-cli)      PURGE_OPENCLAW_CLI=1 ;;
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

# ── Helpers ──────────────────────────────────────────────────────────────────
say()  { printf '[alfred-cleanup] %s\n' "$*"; }
ok()   { printf '[alfred-cleanup] \xe2\x9c\x93 %s\n' "$*"; }
warn() { printf '[alfred-cleanup] WARN: %s\n' "$*"; }
plan() { printf '[alfred-cleanup] plan: %s\n' "$*"; }

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

# Run or simulate a shell command (argv form). First argument is a human label.
run_cmd() {
  local label="$1"; shift
  if [ "$DRY_RUN" -eq 1 ]; then
    plan "$label"
    return 0
  fi
  "$@"
}

# Remove a filesystem path if it exists. Refuses to touch obviously wrong paths.
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
  rm -rf -- "$target"
  ok "Removed $label ($target)"
}

# ── Discovery + summary ──────────────────────────────────────────────────────
summarize() {
  echo
  echo "Alfred cleanup plan"
  echo "==================="
  echo "  OS:                    $OS_KIND"
  echo "  Repo:                  $REPO_DIR$( [ -d "$REPO_DIR/.git" ] && echo ' [present]' || echo ' [missing]')"
  echo "  Data dir:              $DATA_DIR$( [ -d "$DATA_DIR" ] && echo ' [present]' || echo ' [missing]')"
  echo "  Watch dir:             $WATCH_DIR$( [ -d "$WATCH_DIR" ] && echo ' [present]' || echo ' [missing]')"
  echo "  CLI launcher:          $CLI_LAUNCHER_PATH$( [ -e "$CLI_LAUNCHER_PATH" ] && echo ' [present]' || echo ' [missing]')"
  echo "  OpenClaw workspace:    $OPENCLAW_WORKSPACE_DIR$( [ -d "$OPENCLAW_WORKSPACE_DIR" ] && echo ' [present]' || echo ' [missing]')"
  echo "  OpenClaw parent (KEEP):$OPENCLAW_PARENT_DIR"
  if [ "$OS_KIND" = "macos" ]; then
    echo "  launchd plist:         $LAUNCHD_PLIST_PATH$( [ -f "$LAUNCHD_PLIST_PATH" ] && echo ' [present]' || echo ' [missing]')"
  fi
  if [ "$OS_KIND" = "linux" ]; then
    echo "  systemd user units:    $SYSTEMD_UNIT_DIR/{alfred-*.service,alfred-*.timer}"
  fi
  echo
  echo "Flags: dry_run=$DRY_RUN yes=$YES"
  echo "       keep_repo=$KEEP_REPO keep_data=$KEEP_DATA_DIR keep_watch=$KEEP_WATCH_DIR keep_openclaw_workspace=$KEEP_OPENCLAW_WORKSPACE"
  echo "       purge_openclaw_cli=$PURGE_OPENCLAW_CLI purge_telegram_token=$PURGE_TELEGRAM_TOKEN purge_node_tools=$PURGE_NODE_TOOLS"
  echo
}

# ── Stages ───────────────────────────────────────────────────────────────────

# Stage: stop Alfred's own foreground processes via the CLI if it's available
# (best-effort — still works if launcher/repo are already gone).
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

# Stage: unload launchd plist (macOS). Idempotent.
stage_stop_launchd() {
  [ "$OS_KIND" = "macos" ] || return 0
  if [ ! -f "$LAUNCHD_PLIST_PATH" ]; then
    return 0
  fi
  local domain="gui/$(id -u)"
  if [ "$DRY_RUN" -eq 1 ]; then
    plan "launchctl bootout $domain $LAUNCHD_PLIST_PATH"
    plan "rm $LAUNCHD_PLIST_PATH"
    return 0
  fi
  say "Unloading launchd agent $LAUNCHD_LABEL"
  launchctl bootout "$domain" "$LAUNCHD_PLIST_PATH" >/dev/null 2>&1 || true
  rm -f "$LAUNCHD_PLIST_PATH"
  ok "Removed launchd plist ($LAUNCHD_PLIST_PATH)"
}

# Stage: stop and remove systemd user units (Linux). Idempotent.
stage_stop_systemd() {
  [ "$OS_KIND" = "linux" ] || return 0
  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi

  # Only act if any of our unit files exist — avoids noisy "not found" output
  # on machines that never installed systemd units.
  local any=0
  local unit
  for unit in "${SYSTEMD_UNITS[@]}"; do
    if [ -f "$SYSTEMD_UNIT_DIR/$unit" ]; then
      any=1
      break
    fi
  done
  if [ "$any" -eq 0 ]; then
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    plan "systemctl --user disable --now ${SYSTEMD_UNITS[*]}"
    for unit in "${SYSTEMD_UNITS[@]}"; do
      [ -f "$SYSTEMD_UNIT_DIR/$unit" ] && plan "rm $SYSTEMD_UNIT_DIR/$unit"
    done
    plan "systemctl --user daemon-reload"
    return 0
  fi

  say "Stopping + disabling Alfred systemd user units"
  systemctl --user disable --now "${SYSTEMD_UNITS[@]}" >/dev/null 2>&1 || true
  for unit in "${SYSTEMD_UNITS[@]}"; do
    if [ -f "$SYSTEMD_UNIT_DIR/$unit" ]; then
      rm -f "$SYSTEMD_UNIT_DIR/$unit"
      ok "Removed $SYSTEMD_UNIT_DIR/$unit"
    fi
  done
  systemctl --user daemon-reload >/dev/null 2>&1 || true
}

# Stage: nothing listened on Alfred ports? Good. If something does, and
# it looks like it belongs to this user, give it SIGTERM. Best-effort.
stage_free_ports() {
  local port
  for port in "$DEFAULT_DASHBOARD_PORT" "$DEFAULT_API_PORT"; do
    local pids=""
    if command -v lsof >/dev/null 2>&1; then
      pids="$(lsof -ti "tcp:$port" -a -u "$USER" 2>/dev/null || true)"
    fi
    [ -n "$pids" ] || continue
    if [ "$DRY_RUN" -eq 1 ]; then
      plan "kill $pids  (still listening on :$port)"
      continue
    fi
    say "Killing leftover process on :$port (pids: $(echo "$pids" | tr '\n' ' '))"
    echo "$pids" | xargs -r kill 2>/dev/null || true
    # Give 2s to exit, then SIGKILL if needed.
    sleep 2
    pids="$(lsof -ti "tcp:$port" -a -u "$USER" 2>/dev/null || true)"
    if [ -n "$pids" ]; then
      echo "$pids" | xargs -r kill -9 2>/dev/null || true
    fi
  done
}

# Stage: remove the CLI launcher. Only touches the one exact path.
stage_remove_cli_launcher() {
  rm_path "$CLI_LAUNCHER_PATH" "CLI launcher"
}

# Stage: remove repo .env.local explicitly BEFORE removing the repo itself,
# so that even with --keep-repo the file (which contains secrets) is gone.
stage_remove_env_local() {
  local env_file="$REPO_DIR/.env.local"
  rm_path "$env_file" "repo .env.local"
}

# Stage: remove data dir (pidfiles, sqlite db, logs, exports, backups).
stage_remove_data_dir() {
  [ "$KEEP_DATA_DIR" -eq 0 ] || { say "Keeping data dir (--keep-data-dir)"; return 0; }
  rm_path "$DATA_DIR" "data dir"
}

# Stage: remove watch dir (entity subfolders, _Staging, etc.).
stage_remove_watch_dir() {
  [ "$KEEP_WATCH_DIR" -eq 0 ] || { say "Keeping watch dir (--keep-watch-dir)"; return 0; }
  rm_path "$WATCH_DIR" "watch dir"
}

# Stage: remove Alfred's OpenClaw workspace subdir only. Never touches the
# parent (`~/.openclaw/`) or other workspaces siblings may own.
stage_remove_openclaw_workspace() {
  [ "$KEEP_OPENCLAW_WORKSPACE" -eq 0 ] || { say "Keeping OpenClaw workspace (--keep-openclaw-workspace)"; return 0; }

  # Narrow invariant: only remove when the path actually ends in /alfred.
  # Anything else means the user is using a custom layout we don't recognize.
  case "$OPENCLAW_WORKSPACE_DIR" in
    */alfred) ;;
    *)
      warn "OpenClaw workspace path does not end in /alfred — skipping to avoid removing an unrelated workspace: $OPENCLAW_WORKSPACE_DIR"
      return 0
      ;;
  esac
  rm_path "$OPENCLAW_WORKSPACE_DIR" "OpenClaw workspace (Alfred)"
}

# Stage: remove the Alfred repo checkout. Only if it actually looks like a git
# checkout of Alfred — refuses to nuke a random directory.
stage_remove_repo() {
  [ "$KEEP_REPO" -eq 0 ] || { say "Keeping repo (--keep-repo)"; return 0; }
  if [ ! -d "$REPO_DIR" ]; then
    return 0
  fi
  if [ ! -d "$REPO_DIR/.git" ]; then
    warn "Repo dir $REPO_DIR is not a git checkout; skipping to stay safe."
    return 0
  fi
  # Extra sanity: look for an Alfred marker file so we don't nuke the wrong repo.
  if [ ! -f "$REPO_DIR/scripts/install.sh" ] && [ ! -f "$REPO_DIR/scripts/install-openclaw.sh" ]; then
    warn "Repo at $REPO_DIR does not look like the Alfred repo (missing scripts/install.sh); skipping."
    return 0
  fi
  rm_path "$REPO_DIR" "Alfred repo checkout"
}

# Stage: optional purges — shared tooling.
stage_purge_openclaw_cli() {
  [ "$PURGE_OPENCLAW_CLI" -eq 1 ] || return 0
  if ! command -v npm >/dev/null 2>&1; then
    say "npm not found, cannot uninstall @openclaw/cli"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    plan "npm uninstall -g @openclaw/cli"
    return 0
  fi
  say "Uninstalling @openclaw/cli globally"
  npm uninstall -g @openclaw/cli >/dev/null 2>&1 || warn "npm uninstall failed (ignored)"
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
        sudo apt-get remove --purge -y nodejs gh >/dev/null 2>&1 || true
        sudo apt-get autoremove --purge -y      >/dev/null 2>&1 || true
      else
        warn "--purge-node-tools: apt-get not found, skipping"
      fi
      ;;
    *)
      warn "--purge-node-tools: unsupported platform $OS_KIND, skipping"
      ;;
  esac
}

# ── Main ─────────────────────────────────────────────────────────────────────
summarize

if [ "$DRY_RUN" -eq 1 ]; then
  say "Dry-run — no changes will be made."
fi

if [ "$DRY_RUN" -eq 0 ]; then
  if ! confirm "Proceed with Alfred cleanup?"; then
    say "Aborted."
    exit 0
  fi
fi

# Stop first, then remove.
stage_stop_via_cli
stage_stop_launchd
stage_stop_systemd
stage_free_ports

# Remove env file BEFORE touching the repo so --keep-repo still wipes secrets.
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
  curl -fsSL https://raw.githubusercontent.com/sinapsysxyz/alfred-install/main/install.sh | bash

EOF
fi
