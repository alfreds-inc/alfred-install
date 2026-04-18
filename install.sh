#!/usr/bin/env bash
set -euo pipefail

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
if [ -d "$HOME/.local/bin" ]; then
  export PATH="$HOME/.local/bin:$PATH"
fi
DEFAULT_REPO_DIR="$HOME/.local/opt/alfred"
REPO_DIR="${ALFRED_REPO_DIR:-$DEFAULT_REPO_DIR}"
case "$(uname -s)" in
  Darwin) DEFAULT_DATA_DIR="$HOME/Library/Application Support/Alfred" ;;
  *)      DEFAULT_DATA_DIR="$HOME/.local/share/alfred" ;;
esac
DATA_DIR="${ALFRED_DATA_DIR:-$DEFAULT_DATA_DIR}"
REPO_SLUG="${ALFRED_REPO_SLUG:-sinapsysxyz/alfred}"
BRANCH="${ALFRED_REPO_BRANCH:-main}"
MODE="prod"
INSTALL_LAUNCHD=0
INSTALL_SYSTEMD=""
FRESH_DB=0
AUTO_FRESH_DB=0
MIGRATE_DB_PATH=""
SKIP_OPENCLAW_WIZARD=0
SKIP_ENTITY_WIZARD=0
NON_INTERACTIVE=0
SKIP_START=0
PRINT_SUMMARY_ONLY=0
TELEGRAM_TOKEN_FILE=""
SUDO=""

if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

# Pretty output
if [ -t 1 ]; then
  C_RESET=$'\033[0m'
  C_BLUE=$'\033[38;5;75m'
  C_GREEN=$'\033[38;5;114m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_BOLD=$'\033[1m'
else
  C_RESET=""
  C_BLUE=""
  C_GREEN=""
  C_DIM=""
  C_RED=""
  C_BOLD=""
fi

banner() {
  printf '\n  %s%sAlfred%s %sInstaller%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET" "$C_DIM" "$C_RESET"
  printf '  %s-----------------%s\n\n' "$C_DIM" "$C_RESET"
}

step() {
  printf '  %s->%s %s\n' "$C_BLUE" "$C_RESET" "$*"
}

ok() {
  printf '  %sOK%s  %s\n' "$C_GREEN" "$C_RESET" "$*"
}

note() {
  printf '     %s%s%s\n' "$C_DIM" "$*" "$C_RESET"
}

confirm_default_yes() {
  local prompt="$1"
  local response=""

  if ! can_prompt || [ "$NON_INTERACTIVE" -eq 1 ]; then
    return 0
  fi

  printf '  %s [Y/n]: ' "$prompt" > /dev/tty
  read -r response < /dev/tty || response=""
  case "${response:-y}" in
    [Nn]|[Nn][Oo]) return 1 ;;
    *) return 0 ;;
  esac
}

fail() {
  printf '  %sERROR:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
  exit 1
}

run_quiet() {
  local label="$1"
  shift
  local log_file persisted_log
  log_file="$(mktemp "${TMPDIR:-/tmp}/alfred-install.XXXXXX")"
  persisted_log="${log_file}.log"

  if "$@" >"$log_file" 2>&1; then
    rm -f "$log_file"
    return 0
  fi

  mv "$log_file" "$persisted_log"
  printf '\n' >&2
  printf '  %sERROR:%s %s failed\n' "$C_RED" "$C_RESET" "$label" >&2
  printf '  %sRecent output:%s\n' "$C_DIM" "$C_RESET" >&2
  tail -n 80 "$persisted_log" >&2 || true
  printf '  %sFull log:%s %s\n' "$C_DIM" "$C_RESET" "$persisted_log" >&2
  exit 1
}

repo_has_local_changes() {
  [ -d "$REPO_DIR/.git" ] || return 1

  if ! git -C "$REPO_DIR" diff --quiet --ignore-submodules --; then
    return 0
  fi
  if ! git -C "$REPO_DIR" diff --cached --quiet --ignore-submodules --; then
    return 0
  fi
  if [ -n "$(git -C "$REPO_DIR" ls-files --others --exclude-standard)" ]; then
    return 0
  fi

  return 1
}

refresh_existing_repo() {
  local current_branch head_sha remote_sha

  if repo_has_local_changes; then
    note "Existing repo has local changes; skipping automatic update."
    return 0
  fi

  step "Checking Alfred checkout for updates"
  run_quiet "repository fetch" git -C "$REPO_DIR" fetch --prune origin

  if git -C "$REPO_DIR" show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
    current_branch="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [ "$current_branch" != "$BRANCH" ]; then
      if git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$BRANCH"; then
        run_quiet "repository checkout" git -C "$REPO_DIR" checkout "$BRANCH"
      else
        run_quiet "repository checkout" git -C "$REPO_DIR" checkout --track -b "$BRANCH" "origin/$BRANCH"
      fi
    fi

    head_sha="$(git -C "$REPO_DIR" rev-parse HEAD)"
    remote_sha="$(git -C "$REPO_DIR" rev-parse "origin/$BRANCH")"

    if [ "$head_sha" = "$remote_sha" ]; then
      ok "Repository already up to date"
      return 0
    fi

    if git -C "$REPO_DIR" merge-base --is-ancestor "$head_sha" "$remote_sha"; then
      note "Remote has a newer Alfred version available on origin/$BRANCH."
      if ! confirm_default_yes "Update local checkout to the latest remote revision?"; then
        note "Leaving local checkout unchanged at $(git -C "$REPO_DIR" rev-parse --short HEAD)."
        return 0
      fi
      run_quiet "repository update" git -C "$REPO_DIR" merge --ff-only "origin/$BRANCH"
      ok "Repository updated"
      return 0
    fi

    if git -C "$REPO_DIR" merge-base --is-ancestor "$remote_sha" "$head_sha"; then
      note "Existing repo is ahead of origin/$BRANCH; leaving checkout unchanged."
      return 0
    fi

    note "Existing repo diverged from origin/$BRANCH; leaving checkout unchanged."
  else
    run_quiet "repository checkout" git -C "$REPO_DIR" checkout "$BRANCH"
    ok "Repository updated"
    return 0
  fi
}

run_with_sudo() {
  if [ -n "$SUDO" ]; then
    "$SUDO" "$@"
  else
    "$@"
  fi
}

ensure_sudo_session() {
  if [ -n "$SUDO" ] && [ "$(id -u)" -ne 0 ]; then
    note "Administrator access is required for system packages."
    $SUDO -v
  fi
}

usage() {
  cat <<EOF
Usage: bash install.sh [options]

Canonical Alfred installer entrypoint for a fresh machine or an existing checkout.
It authenticates with GitHub if needed, clones the private Alfred repo, then runs
Alfred's host bootstrap and product installer from that checkout. On a first install with no Alfred DB, it
creates a fresh local DB automatically.

Options:
  --repo-dir PATH         Target repo path (default: $DEFAULT_REPO_DIR)
  --data-dir PATH         Alfred runtime data dir
  --branch NAME           Git branch to clone or refresh (default: $BRANCH)
  --dev                   Install for local development workflow
  --launchd               Generate and install a per-user LaunchAgent, then load it
  --systemd               Force Linux systemd user unit install
  --no-systemd            Skip Linux systemd user unit install
  --non-interactive       Skip prompts where possible and rely on env/flags for config
  --fresh-db              Explicitly initialize a fresh local DB when none exists
  --migrate-db PATH       Copy an existing SQLite DB into Alfred runtime if target DB is absent
  --skip-openclaw-wizard  Provision OpenClaw workspace but skip the interactive email/Telegram wizard (CI)
  --skip-entity-wizard    Skip the interactive first-entity setup (CI)
  --telegram-token-file PATH
                          Non-interactive Telegram setup: read the bot token from PATH.
                          Alternative: export TELEGRAM_BOT_TOKEN in the environment.
  --no-start              Install Alfred without starting services at the end
  --summary               Print resolved install plan and exit
  --help, -h              Show this help

Environment:
  GITHUB_TOKEN            GitHub token with read access to $REPO_SLUG
  TELEGRAM_BOT_TOKEN      Telegram bot token (alternative to --telegram-token-file)
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1. Install prerequisites with: brew install git node@22 pnpm"
}

can_prompt() {
  [ -r /dev/tty ] && [ -w /dev/tty ]
}

detect_os() {
  case "$(uname -s)" in
    Darwin) printf 'macos\n' ;;
    Linux)
      if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}${ID_LIKE:-}" in
          *debian*|*ubuntu*) printf 'debian\n' ;;
          *) printf 'linux-other\n' ;;
        esac
      else
        printf 'linux-other\n'
      fi
      ;;
    *) printf 'unknown\n' ;;
  esac
}

ensure_brew() {
  if command -v brew >/dev/null 2>&1; then
    ok "Homebrew ready"
    return
  fi

  step "Installing Homebrew"
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
  ok "Homebrew ready"
}

ensure_github_cli() {
  if command -v gh >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
    ok "GitHub CLI and git ready"
    return
  fi

  case "$(detect_os)" in
    macos)
      ensure_brew
      step "Installing GitHub CLI and git"
      note "Using Homebrew."
      brew install gh git
      ok "GitHub CLI and git ready"
      ;;
    debian)
      if [ -z "$SUDO" ] && [ "$(id -u)" -ne 0 ]; then
        fail "sudo not available and not running as root. Install GitHub CLI and git manually, or run as root."
      fi
      step "Installing GitHub CLI and git"
      note "Using apt on Debian/Ubuntu. This can take a minute on a fresh machine."
      ensure_sudo_session
      run_quiet "apt package index update" run_with_sudo apt-get update -yq
      run_quiet "GitHub CLI and git installation" run_with_sudo env DEBIAN_FRONTEND=noninteractive \
        apt-get install -yq --no-install-recommends ca-certificates curl git gh
      ok "GitHub CLI and git ready"
      ;;
    *)
      fail "GitHub CLI and git are required to fetch the private Alfred repo. Install them manually, then re-run."
      ;;
  esac
}

ensure_github_auth() {
  if gh auth status >/dev/null 2>&1; then
    ok "GitHub authenticated"
    gh auth setup-git >/dev/null 2>&1 || true
    return
  fi

  if [ -z "$GITHUB_TOKEN" ]; then
    if ! can_prompt; then
      fail "GitHub authentication is required to fetch $REPO_SLUG. Re-run with GITHUB_TOKEN set to a token that has repo read access."
    fi

    note "A GitHub token with read access to $REPO_SLUG is required."
    printf '  GitHub token for %s: ' "$REPO_SLUG" > /dev/tty
    read -rs GITHUB_TOKEN < /dev/tty || true
    printf '\n' > /dev/tty

    [ -n "$GITHUB_TOKEN" ] || fail "GitHub token is required to fetch the private Alfred repo."
  fi

  step "Authenticating GitHub"
  gh auth login --hostname github.com --with-token <<< "$GITHUB_TOKEN" >/dev/null
  gh auth setup-git >/dev/null 2>&1 || true
  ok "GitHub authenticated"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-dir)
      shift
      REPO_DIR="${1:-}"
      ;;
    --data-dir)
      shift
      DATA_DIR="${1:-}"
      ;;
    --branch)
      shift
      BRANCH="${1:-}"
      ;;
    --dev)
      MODE="dev"
      ;;
    --launchd)
      INSTALL_LAUNCHD=1
      ;;
    --systemd)
      INSTALL_SYSTEMD=1
      ;;
    --no-systemd)
      INSTALL_SYSTEMD=0
      ;;
    --non-interactive)
      NON_INTERACTIVE=1
      ;;
    --fresh-db)
      FRESH_DB=1
      ;;
    --migrate-db)
      shift
      MIGRATE_DB_PATH="${1:-}"
      ;;
    --skip-openclaw-wizard)
      SKIP_OPENCLAW_WIZARD=1
      ;;
    --skip-entity-wizard)
      SKIP_ENTITY_WIZARD=1
      ;;
    --telegram-token-file)
      shift
      TELEGRAM_TOKEN_FILE="${1:-}"
      ;;
    --no-start)
      SKIP_START=1
      ;;
    --summary)
      PRINT_SUMMARY_ONLY=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
  shift
done

[ -n "$REPO_DIR" ] || fail "Repo dir cannot be empty"
[ -n "$DATA_DIR" ] || fail "Data dir cannot be empty"

if [ "$FRESH_DB" -eq 1 ] && [ -n "$MIGRATE_DB_PATH" ]; then
  fail "Choose either --fresh-db or --migrate-db PATH, not both"
fi

if [ -n "$MIGRATE_DB_PATH" ] && [ ! -f "$MIGRATE_DB_PATH" ]; then
  fail "Migration source not found: $MIGRATE_DB_PATH"
fi

if [ -n "$TELEGRAM_TOKEN_FILE" ] && [ ! -r "$TELEGRAM_TOKEN_FILE" ]; then
  fail "Telegram token file not readable: $TELEGRAM_TOKEN_FILE"
fi

DEFAULT_DB_PATH="$DATA_DIR/data/finance_ops.sqlite"
if [ "$FRESH_DB" -eq 0 ] && [ -z "$MIGRATE_DB_PATH" ] && [ ! -f "$DEFAULT_DB_PATH" ]; then
  FRESH_DB=1
  AUTO_FRESH_DB=1
fi

if [ "$PRINT_SUMMARY_ONLY" -eq 1 ]; then
  cat <<EOF
repo_dir=$REPO_DIR
data_dir=$DATA_DIR
branch=$BRANCH
mode=$MODE
launchd=$INSTALL_LAUNCHD
systemd=$INSTALL_SYSTEMD
fresh_db=$FRESH_DB
migrate_db=${MIGRATE_DB_PATH:-}
skip_openclaw_wizard=$SKIP_OPENCLAW_WIZARD
skip_entity_wizard=$SKIP_ENTITY_WIZARD
non_interactive=$NON_INTERACTIVE
skip_start=$SKIP_START
telegram_token_file=${TELEGRAM_TOKEN_FILE:-}
repo_slug=$REPO_SLUG
EOF
  exit 0
fi

banner

if [ "$AUTO_FRESH_DB" -eq 1 ]; then
  note "Fresh install detected. Alfred will create a local database at $DEFAULT_DB_PATH."
fi

ensure_github_cli
ensure_github_auth
need_cmd git
mkdir -p "$(dirname "$REPO_DIR")" "$DATA_DIR"

if [ ! -d "$REPO_DIR/.git" ]; then
  step "Cloning Alfred into $REPO_DIR"
  if [ -n "$BRANCH" ]; then
    run_quiet "repository clone" gh repo clone "$REPO_SLUG" "$REPO_DIR" -- --branch "$BRANCH"
  else
    run_quiet "repository clone" gh repo clone "$REPO_SLUG" "$REPO_DIR"
  fi
  ok "Repository ready"
else
  ok "Using existing repo at $REPO_DIR"
  refresh_existing_repo
fi

cd "$REPO_DIR"

if [ ! -f "$REPO_DIR/scripts/bootstrap-host.sh" ]; then
  fail "Expected Alfred host bootstrap at $REPO_DIR/scripts/bootstrap-host.sh. Existing checkout may be stale; remove $REPO_DIR or clean it and rerun the installer."
fi
if [ ! -f "$REPO_DIR/scripts/install.sh" ]; then
  fail "Expected Alfred installer at $REPO_DIR/scripts/install.sh. Existing checkout may be stale; remove $REPO_DIR or clean it and rerun the installer."
fi

INSTALL_ARGS=(--repo-dir "$REPO_DIR" --data-dir "$DATA_DIR" --branch "$BRANCH")
if [ "$MODE" = "dev" ]; then
  INSTALL_ARGS+=(--dev)
fi
if [ "$INSTALL_LAUNCHD" -eq 1 ]; then
  INSTALL_ARGS+=(--launchd)
fi
if [ -n "$INSTALL_SYSTEMD" ]; then
  if [ "$INSTALL_SYSTEMD" -eq 1 ]; then
    INSTALL_ARGS+=(--systemd)
  else
    INSTALL_ARGS+=(--no-systemd)
  fi
fi
if [ "$NON_INTERACTIVE" -eq 1 ]; then
  INSTALL_ARGS+=(--non-interactive)
fi
if [ "$FRESH_DB" -eq 1 ]; then
  INSTALL_ARGS+=(--fresh-db)
fi
if [ -n "$MIGRATE_DB_PATH" ]; then
  INSTALL_ARGS+=(--migrate-db "$MIGRATE_DB_PATH")
fi
if [ "$SKIP_OPENCLAW_WIZARD" -eq 1 ]; then
  INSTALL_ARGS+=(--skip-openclaw-wizard)
fi
if [ "$SKIP_ENTITY_WIZARD" -eq 1 ]; then
  INSTALL_ARGS+=(--skip-entity-wizard)
fi
if [ -n "$TELEGRAM_TOKEN_FILE" ]; then
  INSTALL_ARGS+=(--telegram-token-file "$TELEGRAM_TOKEN_FILE")
fi
if [ "$SKIP_START" -eq 1 ]; then
  INSTALL_ARGS+=(--no-start)
fi

step "Preparing Alfred runtime"

bash "$REPO_DIR/scripts/bootstrap-host.sh"

step "Installing Alfred"

exec env \
  ALFRED_REPO_DIR="$REPO_DIR" \
  ALFRED_REPO_BRANCH="$BRANCH" \
  ALFRED_REPO_URL="https://github.com/$REPO_SLUG.git" \
  ALFRED_REPO_PREPARED=1 \
  bash "$REPO_DIR/scripts/install.sh" "${INSTALL_ARGS[@]}"
