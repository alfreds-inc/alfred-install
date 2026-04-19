#!/usr/bin/env bash
set -euo pipefail

INSTALLER_VERSION="2026.04-cloud-scaffold"
INSTALL_STATE_SCHEMA_VERSION="1"

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
if [ -d "$HOME/.local/bin" ]; then
  export PATH="$HOME/.local/bin:$PATH"
fi

REPO_SLUG="${ALFRED_REPO_SLUG:-alfreds-inc/alfred}"
BRANCH="${ALFRED_REPO_BRANCH:-main}"
MODE="${ALFRED_INSTALL_MODE:-local}"
DEV_MODE=0
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
USER_SET_SKIP_OPENCLAW_WIZARD=0
USER_SET_SKIP_ENTITY_WIZARD=0
USER_SET_TELEGRAM_TOKEN_FILE=0
ENROLLMENT_TOKEN="${ALFRED_CLOUD_ENROLLMENT_TOKEN:-}"
FORCE_REENROLL=0

RAW_REPO_DIR="${ALFRED_REPO_DIR:-}"
RAW_DATA_DIR="${ALFRED_DATA_DIR:-}"
RAW_WATCH_DIR="${ALFRED_WATCH_DIR:-}"
RAW_CLI_LAUNCHER_PATH="${ALFRED_CLI_LAUNCHER:-}"
REPO_DIR=""
DATA_DIR=""
WATCH_DIR=""
CLI_LAUNCHER_PATH=""

OPENCLAW_PARENT_DIR="${OPENCLAW_WORKSPACE_PARENT_DIR:-${OPENCLAW_WORKSPACE_DIR:-$HOME/.openclaw/workspace}}"
OPENCLAW_WORKSPACE_DIR="$OPENCLAW_PARENT_DIR/alfred"

INSTALL_STATE_FILE=""
CLOUD_ENV_FILE=""
TUNNEL_ENV_FILE=""
INSTALL_STATUS="not_started"
INSTALL_ID=""
INSTALL_STARTED_AT_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

CLOUD_SERVICE_USER="${ALFRED_CLOUD_SERVICE_USER:-alfred}"
CLOUD_API_BASE_URL="${ALFRED_CLOUD_API_BASE_URL:-}"
CLOUD_ENROLLMENT_URL="${ALFRED_CLOUD_ENROLLMENT_URL:-}"
CLOUD_DECOMMISSION_URL="${ALFRED_CLOUD_DECOMMISSION_URL:-}"
CLOUD_ENROLLMENT_STUB_FILE="${ALFRED_CLOUD_ENROLLMENT_STUB_FILE:-}"
CLOUD_MACHINE_REGION="${ALFRED_CLOUD_MACHINE_REGION:-}"
CLOUD_TUNNEL_PROVIDER="${ALFRED_CLOUD_TUNNEL_PROVIDER:-wireguard}"
CLOUD_TUNNEL_PUBLIC_KEY="${ALFRED_CLOUD_TUNNEL_PUBLIC_KEY:-}"
CLOUD_RUNTIME_VERSION_HINT="${ALFRED_RUNTIME_VERSION_HINT:-}"

CLOUD_REUSED_EXISTING_BOOTSTRAP=0
CLOUD_DID_ENROLL=0
CLOUD_TENANT_ID=""
CLOUD_TENANT_SLUG=""
CLOUD_RUNTIME_ID=""
CLOUD_RUNTIME_SECRET=""
CLOUD_HEARTBEAT_INTERVAL_S="30"
CLOUD_EDGE_ISSUER=""
CLOUD_EDGE_AUDIENCE=""
CLOUD_EDGE_JWKS_URL=""
CLOUD_TUNNEL_CONFIG_JSON="{}"
CLAIM_URL=""

if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  SUDO=""
fi

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_BLUE=$'\033[38;5;75m'
  C_GREEN=$'\033[38;5;114m'
  C_YELLOW=$'\033[38;5;179m'
  C_RED=$'\033[38;5;174m'
  C_CYAN=$'\033[38;5;110m'
  C_MAGENTA=$'\033[38;5;176m'
else
  C_RESET=""
  C_BOLD=""
  C_DIM=""
  C_BLUE=""
  C_GREEN=""
  C_YELLOW=""
  C_RED=""
  C_CYAN=""
  C_MAGENTA=""
fi

LAST_PROGRESS_TEXT=""
LAST_PROGRESS_REWIND=0

# Print a trailing blank line on exit so the terminal always ends with
# breathing room. TTY-gated so piped/redirected output stays clean.
_alfred_exit_trailing_newline() {
  [ -t 1 ] && printf '\n'
}
trap _alfred_exit_trailing_newline EXIT

_alfred_remember_progress() {
  LAST_PROGRESS_TEXT="$1"
  LAST_PROGRESS_REWIND="${2:-0}"
}

_alfred_forget_progress() {
  LAST_PROGRESS_TEXT=""
  LAST_PROGRESS_REWIND=0
}

banner() {
  if [ "${ALFRED_BANNER_SHOWN:-0}" = "1" ]; then
    _alfred_forget_progress
    return 0
  fi
  printf '\n%sAlfred%s %sInstaller%s\n' "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
  export ALFRED_BANNER_SHOWN=1
  _alfred_forget_progress
}

section() {
  local title="$1"
  local color="${2:-}"
  local title_prefix="$C_BOLD"
  if [ -n "$color" ]; then
    title_prefix="$color$C_BOLD"
  fi
  printf '\n%s%s%s\n' "$title_prefix" "$title" "$C_RESET"
  _alfred_forget_progress
}

step() {
  _alfred_remember_progress "$*" 1
  printf '  %s%s%s\n' "$C_BOLD" "$*" "$C_RESET"
}

ok() {
  _alfred_forget_progress
  printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"
}

note() {
  _alfred_remember_progress "$*" 1
  printf '    %s%s%s\n' "$C_DIM" "$*" "$C_RESET"
}

info() {
  _alfred_forget_progress
  printf '    %s%s%s\n' "$C_CYAN" "$*" "$C_RESET"
}

warn() {
  _alfred_forget_progress
  printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2
}

confirm_default_yes() {
  local prompt="$1"
  local response=""

  if ! can_prompt || [ "$NON_INTERACTIVE" -eq 1 ]; then
    return 0
  fi

  printf '%s [Y/n]: ' "$prompt" > /dev/tty
  read -r response < /dev/tty || response=""
  case "${response:-y}" in
    [Nn]|[Nn][Oo]) return 1 ;;
    *) return 0 ;;
  esac
}

# Reads a secret interactively. Echoes '*' per keystroke capped at MAX_ECHO so
# long keys do not wrap. On <Enter> rewrites the line with a dim reveal of the
# last four chars.
read_secret_with_reveal() {
  local __var="$1"
  local prompt="$2"
  local answer=""
  local max_echo=16
  local echoed=0

  if ! can_prompt; then
    printf '%s' "$prompt"
    read -rs answer || true
    printf '\n'
    printf -v "$__var" '%s' "$answer"
    return 0
  fi

  local ch
  printf '%s' "$prompt" > /dev/tty
  while IFS= read -r -n1 -s ch < /dev/tty; do
    if [ -z "$ch" ]; then
      break
    fi
    case "$ch" in
      $'\x7f'|$'\b')
        if [ -n "$answer" ]; then
          answer="${answer%?}"
          if [ "$echoed" -gt 0 ]; then
            printf '\b \b' > /dev/tty
            echoed=$(( echoed - 1 ))
          fi
        fi
        ;;
      $'\x03')
        printf '\n' > /dev/tty
        exit 130
        ;;
      *)
        answer+="$ch"
        if [ "$echoed" -lt "$max_echo" ]; then
          printf '*' > /dev/tty
          echoed=$(( echoed + 1 ))
        fi
        ;;
    esac
  done

  local len=${#answer}
  local visible=""
  local star_count="$len"
  if [ "$len" -ge 5 ]; then
    visible="${answer: -4}"
    star_count=$(( len - 4 ))
    if [ "$star_count" -gt 12 ]; then
      star_count=12
    fi
  fi
  local stars=""
  if [ "$star_count" -gt 0 ]; then
    stars="$(printf '%*s' "$star_count" '' | tr ' ' '*')"
  fi
  printf '\r\033[2K%s%s%s%s%s\n' "$prompt" "$C_DIM" "$stars" "$C_RESET" "$visible" > /dev/tty

  printf -v "$__var" '%s' "$answer"
}

fail() {
  _alfred_forget_progress
  printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
  exit 1
}

ALFRED_SPINNER_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

_alfred_render_spinner_line() {
  local message="$1"
  local frame="$2"
  printf '\r\033[2K  %s%s%s %s' "$C_DIM" "$frame" "$C_RESET" "$message"
}

_alfred_render_status_line() {
  local message="$1"
  local mark="$2"
  local color="$3"
  printf '\r\033[2K  %s%s%s %s\n' "$color" "$mark" "$C_RESET" "$message"
}

_alfred_spin_while() {
  [ -t 1 ] || return 0
  local pid="$1"
  local message="$2"
  local attach="${3:-0}"
  local rewind="${4:-0}"
  local i=0

  if [ "$attach" -eq 1 ] && [ "$rewind" -gt 0 ]; then
    printf '\033[%sA' "$rewind"
  fi

  while kill -0 "$pid" 2>/dev/null; do
    _alfred_render_spinner_line "$message" "${ALFRED_SPINNER_FRAMES[$i]}"
    i=$(( (i + 1) % ${#ALFRED_SPINNER_FRAMES[@]} ))
    sleep 0.08
  done
}

run_quiet() {
  local label="$1"
  shift
  local log_file persisted_log cmd_pid cmd_status
  local message="$label"
  local attach=0
  local rewind=0
  log_file="$(mktemp "${TMPDIR:-/tmp}/alfred-install.XXXXXX")"
  persisted_log="${log_file}.log"

  if [ -n "${LAST_PROGRESS_TEXT:-}" ]; then
    message="$LAST_PROGRESS_TEXT"
    attach=1
    rewind="${LAST_PROGRESS_REWIND:-0}"
  fi
  _alfred_forget_progress

  if [ -t 1 ]; then
    "$@" >"$log_file" 2>&1 &
    cmd_pid=$!
    _alfred_spin_while "$cmd_pid" "$message" "$attach" "$rewind"
    set +e
    wait "$cmd_pid"
    cmd_status=$?
    set -e
  elif "$@" >"$log_file" 2>&1; then
    rm -f "$log_file"
    return 0
  else
    cmd_status=$?
  fi

  if [ "${cmd_status:-0}" -eq 0 ]; then
    if [ -t 1 ]; then
      _alfred_render_status_line "$message" "✓" "$C_GREEN"
    fi
    rm -f "$log_file"
    return 0
  fi

  if [ -t 1 ]; then
    _alfred_render_status_line "$message" "✗" "$C_RED"
  else
    printf '  ✗ %s\n' "$message" >&2
  fi
  mv "$log_file" "$persisted_log"
  printf '    %sRecent output:%s\n' "$C_DIM" "$C_RESET" >&2
  tail -n 80 "$persisted_log" >&2 || true
  printf '    %sFull log:%s %s\n' "$C_DIM" "$C_RESET" "$persisted_log" >&2
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
    note "Existing repo has local changes; skipping automatic update"
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
      note "Remote has a newer Alfred version available on origin/$BRANCH"
      if ! confirm_default_yes "Update local checkout to the latest remote revision?"; then
        note "Leaving local checkout unchanged at $(git -C "$REPO_DIR" rev-parse --short HEAD)"
        return 0
      fi
      run_quiet "repository update" git -C "$REPO_DIR" merge --ff-only "origin/$BRANCH"
      ok "Repository updated"
      return 0
    fi

    if git -C "$REPO_DIR" merge-base --is-ancestor "$remote_sha" "$head_sha"; then
      note "Existing repo is ahead of origin/$BRANCH; leaving checkout unchanged"
      return 0
    fi

    note "Existing repo diverged from origin/$BRANCH; leaving checkout unchanged"
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
    if ! $SUDO -n true 2>/dev/null; then
      note "Administrator access required — you may be prompted for your password"
    fi
    $SUDO -v
    _alfred_forget_progress
  fi
}

usage() {
  cat <<EOF
Usage: bash install.sh [options]

Canonical Alfred installer entrypoint for a fresh machine or an existing checkout.
The installer supports two product modes:
  • local (default): self-hosted workstation/laptop install
  • cloud: operator-run VM bootstrap for Alfred Cloud hosted runtimes

Cloud installs are infra-only. Customer business setup moves into the Alfred
dashboard onboarding flow and must not stay in the terminal.

Options:
  --mode local|cloud       Install mode (default: local)
  --repo-dir PATH          Target repo path (mode-dependent default)
  --data-dir PATH          Alfred runtime data dir (mode-dependent default)
  --branch NAME            Git branch to clone or refresh (default: $BRANCH)
  --dev                    Install for local development workflow (local mode only)
  --launchd                Generate and install a per-user LaunchAgent, then load it
  --systemd                Force Linux systemd user unit install (local mode)
  --no-systemd             Skip Linux systemd user unit install (local mode)
  --non-interactive        Skip prompts where possible and rely on env/flags for config
  --fresh-db               Explicitly initialize a fresh local DB when none exists
  --migrate-db PATH        Copy an existing SQLite DB into Alfred runtime if target DB is absent
  --enrollment-token TOKEN Cloud mode only: one-time Alfred Cloud enrollment token
  --force-reenroll         Cloud mode only: ignore existing runtime cloud config and enroll again
  --skip-intelligence-wizard
                           Deprecated no-op. Guided setup now runs after install via
                           'alfred setup' and the focused Alfred CLI commands.
  --skip-entity-wizard     Deprecated no-op. Entity setup moved out of the main installer.
  --telegram-token-file PATH
                           Deprecated no-op. Run 'alfred telegram --telegram-token-file PATH'
                           after install instead.
  --no-start               Install Alfred without starting services at the end
  --summary                Print resolved install plan and exit
  --help, -h               Show this help

Environment:
  GITHUB_TOKEN                     GitHub token with read access to $REPO_SLUG
  ALFRED_INSTALL_MODE              Alternative default for --mode
  ALFRED_CLOUD_API_BASE_URL        Alfred Cloud control-plane base URL
  ALFRED_CLOUD_ENROLLMENT_URL      Explicit Alfred Cloud enrollment URL
  ALFRED_CLOUD_ENROLLMENT_STUB_FILE
                                   Dev/test JSON stub for enrollment responses
  ALFRED_CLOUD_MACHINE_REGION      Optional machine region hint for enrollment
  ALFRED_CLOUD_TUNNEL_PROVIDER     Tunnel provider preference (default: wireguard)
  ALFRED_CLOUD_TUNNEL_PUBLIC_KEY   Optional tunnel public key presented at enrollment
  ALFRED_RUNTIME_VERSION_HINT      Optional runtime version/ref hint sent at enrollment
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
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

default_local_repo_dir() {
  printf '%s\n' "$HOME/.local/opt/alfred"
}

default_cloud_repo_dir() {
  printf '%s\n' "/opt/alfred"
}

default_local_data_dir() {
  case "$(uname -s)" in
    Darwin) printf '%s\n' "$HOME/Library/Application Support/Alfred" ;;
    *) printf '%s\n' "$HOME/.local/share/alfred" ;;
  esac
}

default_cloud_data_dir() {
  printf '%s\n' "/var/lib/alfred"
}

default_watch_dir() {
  printf '%s\n' "$HOME/Documents/Alfred"
}

default_local_cli_launcher() {
  printf '%s\n' "$HOME/.local/bin/alfred"
}

default_cloud_cli_launcher() {
  printf '%s\n' "/usr/local/bin/alfred"
}

derive_cloud_api_base_url_from_enrollment_url() {
  case "$CLOUD_ENROLLMENT_URL" in
    */v1/runtimes/enroll) printf '%s\n' "${CLOUD_ENROLLMENT_URL%/v1/runtimes/enroll}" ;;
    *) printf '%s\n' "$CLOUD_API_BASE_URL" ;;
  esac
}

resolve_mode_defaults() {
  if [ "$MODE" = "cloud" ]; then
    REPO_DIR="${RAW_REPO_DIR:-$(default_cloud_repo_dir)}"
    DATA_DIR="${RAW_DATA_DIR:-$(default_cloud_data_dir)}"
    CLI_LAUNCHER_PATH="${RAW_CLI_LAUNCHER_PATH:-$(default_cloud_cli_launcher)}"
  else
    REPO_DIR="${RAW_REPO_DIR:-$(default_local_repo_dir)}"
    DATA_DIR="${RAW_DATA_DIR:-$(default_local_data_dir)}"
    CLI_LAUNCHER_PATH="${RAW_CLI_LAUNCHER_PATH:-$(default_local_cli_launcher)}"
  fi

  WATCH_DIR="${RAW_WATCH_DIR:-$(default_watch_dir)}"
  INSTALL_STATE_FILE="${ALFRED_INSTALL_STATE_FILE:-$DATA_DIR/install/install-state.env}"
  CLOUD_ENV_FILE="${ALFRED_CLOUD_ENV_FILE:-$DATA_DIR/config/cloud-bootstrap.env}"
  TUNNEL_ENV_FILE="${ALFRED_CLOUD_TUNNEL_ENV_FILE:-$DATA_DIR/config/tunnel.env}"

  if [ -z "$CLOUD_API_BASE_URL" ] && [ -n "$CLOUD_ENROLLMENT_URL" ]; then
    CLOUD_API_BASE_URL="$(derive_cloud_api_base_url_from_enrollment_url)"
  fi
}

service_manager_name() {
  if [ "$MODE" = "cloud" ]; then
    printf '%s\n' "systemd-system"
    return
  fi

  case "$(detect_os)" in
    macos)
      if [ "$INSTALL_LAUNCHD" -eq 1 ]; then
        printf '%s\n' "launchd"
      else
        printf '%s\n' "manual"
      fi
      ;;
    debian|linux-other)
      if [ -n "$INSTALL_SYSTEMD" ] && [ "$INSTALL_SYSTEMD" -eq 0 ]; then
        printf '%s\n' "manual"
      else
        printf '%s\n' "systemd-user"
      fi
      ;;
    *)
      printf '%s\n' "manual"
      ;;
  esac
}

service_units_value() {
  if [ "$MODE" = "cloud" ]; then
    printf '%s\n' "alfred-api.service alfred-dashboard.service alfred-worker.service alfred-worker.timer alfred-proxy.service alfred-tunnel.service"
    return
  fi

  case "$(service_manager_name)" in
    systemd-user) printf '%s\n' "alfred-api.service alfred-dashboard.service alfred-worker.service alfred-worker.timer" ;;
    *) printf '%s\n' "" ;;
  esac
}

launchd_labels_value() {
  if [ "$MODE" = "local" ] && [ "$(service_manager_name)" = "launchd" ]; then
    printf '%s\n' "com.sinapsys.alfred.dashboard"
  else
    printf '%s\n' ""
  fi
}

generate_install_id() {
  if [ -n "$INSTALL_ID" ]; then
    return
  fi

  if command -v uuidgen >/dev/null 2>&1; then
    INSTALL_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    return
  fi
  if command -v openssl >/dev/null 2>&1; then
    INSTALL_ID="$(openssl rand -hex 16)"
    return
  fi

  INSTALL_ID="install-$(date +%s)-$$"
}

load_env_file() {
  local file="$1"
  [ -f "$file" ] || return 1
  # shellcheck disable=SC1090
  . "$file"
}

load_existing_install_state() {
  if ! load_env_file "$INSTALL_STATE_FILE"; then
    return 0
  fi

  INSTALL_ID="${ALFRED_INSTALL_ID:-$INSTALL_ID}"
  if [ "$MODE" = "cloud" ]; then
    CLOUD_TENANT_SLUG="${ALFRED_TENANT_SLUG:-$CLOUD_TENANT_SLUG}"
    CLOUD_RUNTIME_ID="${ALFRED_RUNTIME_ID:-$CLOUD_RUNTIME_ID}"
  fi
}

write_env_assignment() {
  local file="$1"
  local key="$2"
  local value="$3"
  printf '%s=%q\n' "$key" "$value" >>"$file"
}

prepare_env_file() {
  local file="$1"
  local dir
  dir="$(dirname "$file")"
  mkdir -p "$dir"
  (umask 077 && : >"$file")
}

persist_install_state() {
  local file="$INSTALL_STATE_FILE"
  prepare_env_file "$file"
  write_env_assignment "$file" "ALFRED_INSTALL_STATE_SCHEMA" "$INSTALL_STATE_SCHEMA_VERSION"
  write_env_assignment "$file" "ALFRED_INSTALL_ID" "$INSTALL_ID"
  write_env_assignment "$file" "ALFRED_INSTALLER_VERSION" "$INSTALLER_VERSION"
  write_env_assignment "$file" "ALFRED_INSTALL_MODE" "$MODE"
  write_env_assignment "$file" "ALFRED_INSTALL_STATUS" "$INSTALL_STATUS"
  write_env_assignment "$file" "ALFRED_REPO_DIR" "$REPO_DIR"
  write_env_assignment "$file" "ALFRED_DATA_DIR" "$DATA_DIR"
  write_env_assignment "$file" "ALFRED_WATCH_DIR" "$WATCH_DIR"
  write_env_assignment "$file" "ALFRED_CLI_LAUNCHER" "$CLI_LAUNCHER_PATH"
  write_env_assignment "$file" "OPENCLAW_WORKSPACE_PARENT_DIR" "$OPENCLAW_PARENT_DIR"
  write_env_assignment "$file" "OPENCLAW_WORKSPACE_DIR" "$OPENCLAW_WORKSPACE_DIR"
  write_env_assignment "$file" "ALFRED_SERVICE_MANAGER" "$(service_manager_name)"
  write_env_assignment "$file" "ALFRED_SERVICE_UNITS" "$(service_units_value)"
  write_env_assignment "$file" "ALFRED_LAUNCHD_LABELS" "$(launchd_labels_value)"
  write_env_assignment "$file" "ALFRED_REPO_SLUG" "$REPO_SLUG"
  write_env_assignment "$file" "ALFRED_REPO_REF" "$BRANCH"
  write_env_assignment "$file" "ALFRED_INSTALL_STATE_FILE" "$INSTALL_STATE_FILE"
  write_env_assignment "$file" "ALFRED_CLOUD_ENV_FILE" "$CLOUD_ENV_FILE"
  write_env_assignment "$file" "ALFRED_CLOUD_TUNNEL_ENV_FILE" "$TUNNEL_ENV_FILE"
  write_env_assignment "$file" "ALFRED_CLOUD_API_BASE_URL" "$CLOUD_API_BASE_URL"
  write_env_assignment "$file" "ALFRED_CLOUD_DECOMMISSION_URL" "$CLOUD_DECOMMISSION_URL"
  write_env_assignment "$file" "ALFRED_CLOUD_SERVICE_USER" "$CLOUD_SERVICE_USER"
  write_env_assignment "$file" "ALFRED_TENANT_SLUG" "$CLOUD_TENANT_SLUG"
  write_env_assignment "$file" "ALFRED_RUNTIME_ID" "$CLOUD_RUNTIME_ID"
  write_env_assignment "$file" "ALFRED_INSTALLED_AT_UTC" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}

persist_cloud_config() {
  [ "$MODE" = "cloud" ] || return 0

  prepare_env_file "$CLOUD_ENV_FILE"
  write_env_assignment "$CLOUD_ENV_FILE" "ALFRED_INSTALL_MODE" "$MODE"
  write_env_assignment "$CLOUD_ENV_FILE" "ALFRED_TENANT_ID" "$CLOUD_TENANT_ID"
  write_env_assignment "$CLOUD_ENV_FILE" "ALFRED_TENANT_SLUG" "$CLOUD_TENANT_SLUG"
  write_env_assignment "$CLOUD_ENV_FILE" "ALFRED_RUNTIME_ID" "$CLOUD_RUNTIME_ID"
  write_env_assignment "$CLOUD_ENV_FILE" "ALFRED_RUNTIME_SECRET" "$CLOUD_RUNTIME_SECRET"
  write_env_assignment "$CLOUD_ENV_FILE" "ALFRED_CLOUD_API_BASE_URL" "$CLOUD_API_BASE_URL"
  write_env_assignment "$CLOUD_ENV_FILE" "ALFRED_CLOUD_ENROLLMENT_URL" "$CLOUD_ENROLLMENT_URL"
  write_env_assignment "$CLOUD_ENV_FILE" "ALFRED_CLOUD_DECOMMISSION_URL" "$CLOUD_DECOMMISSION_URL"
  write_env_assignment "$CLOUD_ENV_FILE" "ALFRED_CLOUD_EDGE_ISSUER" "$CLOUD_EDGE_ISSUER"
  write_env_assignment "$CLOUD_ENV_FILE" "ALFRED_CLOUD_EDGE_AUDIENCE" "$CLOUD_EDGE_AUDIENCE"
  write_env_assignment "$CLOUD_ENV_FILE" "ALFRED_CLOUD_EDGE_JWKS_URL" "$CLOUD_EDGE_JWKS_URL"
  write_env_assignment "$CLOUD_ENV_FILE" "ALFRED_CLOUD_HEARTBEAT_INTERVAL_S" "$CLOUD_HEARTBEAT_INTERVAL_S"
  write_env_assignment "$CLOUD_ENV_FILE" "ALFRED_CLOUD_SERVICE_USER" "$CLOUD_SERVICE_USER"
}

persist_tunnel_config() {
  [ "$MODE" = "cloud" ] || return 0

  prepare_env_file "$TUNNEL_ENV_FILE"
  write_env_assignment "$TUNNEL_ENV_FILE" "ALFRED_CLOUD_TUNNEL_PROVIDER" "$CLOUD_TUNNEL_PROVIDER"
  write_env_assignment "$TUNNEL_ENV_FILE" "ALFRED_CLOUD_TUNNEL_PUBLIC_KEY" "$CLOUD_TUNNEL_PUBLIC_KEY"
  write_env_assignment "$TUNNEL_ENV_FILE" "ALFRED_CLOUD_TUNNEL_CONFIG_JSON" "$CLOUD_TUNNEL_CONFIG_JSON"
}

warn_deprecated_flags() {
  if [ "$USER_SET_SKIP_OPENCLAW_WIZARD" -eq 1 ]; then
    warn "--skip-intelligence-wizard is deprecated and ignored — guided setup now runs after install via 'alfred setup'"
  fi
  if [ "$USER_SET_SKIP_ENTITY_WIZARD" -eq 1 ]; then
    warn "--skip-entity-wizard is deprecated and ignored — run 'alfred entities' after install if you need it"
  fi
  if [ "$USER_SET_TELEGRAM_TOKEN_FILE" -eq 1 ]; then
    warn "--telegram-token-file is deprecated and ignored during install — run 'alfred telegram --telegram-token-file PATH' after install"
  fi
}

validate_args() {
  [ -n "$REPO_DIR" ] || fail "Repo dir cannot be empty"
  [ -n "$DATA_DIR" ] || fail "Data dir cannot be empty"

  case "$MODE" in
    local|cloud) ;;
    *) fail "Unknown install mode: $MODE" ;;
  esac

  if [ "$FRESH_DB" -eq 1 ] && [ -n "$MIGRATE_DB_PATH" ]; then
    fail "Choose either --fresh-db or --migrate-db PATH, not both"
  fi

  if [ -n "$MIGRATE_DB_PATH" ] && [ ! -f "$MIGRATE_DB_PATH" ]; then
    fail "Migration source not found: $MIGRATE_DB_PATH"
  fi

  if [ "$MODE" = "cloud" ]; then
    if [ "$DEV_MODE" -eq 1 ]; then
      fail "--dev is local-only. Cloud mode must use the runtime's hosted deployment mode."
    fi
    if [ "$INSTALL_LAUNCHD" -eq 1 ]; then
      fail "--launchd is local-only. Cloud mode is Linux-only and uses systemd system services."
    fi
    if [ -n "$INSTALL_SYSTEMD" ] && [ "$INSTALL_SYSTEMD" -eq 0 ]; then
      fail "--no-systemd is incompatible with cloud mode."
    fi
    if [ "$FRESH_DB" -eq 1 ] || [ -n "$MIGRATE_DB_PATH" ]; then
      fail "--fresh-db and --migrate-db are local-only. Cloud mode bootstraps infra and leaves product setup to browser onboarding."
    fi
    if [ "$FORCE_REENROLL" -eq 1 ] && [ -z "$ENROLLMENT_TOKEN" ]; then
      fail "--force-reenroll requires --enrollment-token TOKEN."
    fi
  fi
}

enforce_runtime_host_constraints() {
  if [ "$MODE" != "cloud" ]; then
    return 0
  fi

  case "$(detect_os)" in
    debian|linux-other) ;;
    *)
      fail "Cloud mode is Linux-only in v1."
      ;;
  esac

  if [ -z "$SUDO" ] && [ "$(id -u)" -ne 0 ]; then
    fail "Cloud mode requires root or sudo-capable package/service management."
  fi
}

print_summary() {
  cat <<EOF
installer_version=$INSTALLER_VERSION
mode=$MODE
repo_dir=$REPO_DIR
data_dir=$DATA_DIR
watch_dir=$WATCH_DIR
cli_launcher=$CLI_LAUNCHER_PATH
branch=$BRANCH
repo_slug=$REPO_SLUG
service_manager=$(service_manager_name)
service_units=$(service_units_value)
launchd_labels=$(launchd_labels_value)
dev_mode=$DEV_MODE
launchd=$INSTALL_LAUNCHD
systemd=$INSTALL_SYSTEMD
fresh_db=$FRESH_DB
migrate_db=${MIGRATE_DB_PATH:-}
non_interactive=$NON_INTERACTIVE
skip_start=$SKIP_START
install_state_file=$INSTALL_STATE_FILE
cloud_env_file=$CLOUD_ENV_FILE
tunnel_env_file=$TUNNEL_ENV_FILE
cloud_enrollment_required=$([ "$MODE" = "cloud" ] && printf '1' || printf '0')
cloud_enrollment_url=${CLOUD_ENROLLMENT_URL:-}
cloud_api_base_url=${CLOUD_API_BASE_URL:-}
cloud_decommission_url=${CLOUD_DECOMMISSION_URL:-}
cloud_stub_file=${CLOUD_ENROLLMENT_STUB_FILE:-}
cloud_service_user=$CLOUD_SERVICE_USER
force_reenroll=$FORCE_REENROLL
enrollment_token_present=$([ -n "$ENROLLMENT_TOKEN" ] && printf '1' || printf '0')
EOF
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
      note "Using Homebrew"
      brew install gh git
      ok "GitHub CLI and git ready"
      ;;
    debian)
      if [ -z "$SUDO" ] && [ "$(id -u)" -ne 0 ]; then
        fail "sudo not available and not running as root. Install GitHub CLI and git manually, or run as root."
      fi
      step "Installing GitHub CLI and git"
      note "Using apt on Debian/Ubuntu"
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

ensure_jq() {
  if command -v jq >/dev/null 2>&1; then
    ok "jq ready"
    return
  fi

  case "$(detect_os)" in
    macos)
      ensure_brew
      step "Installing jq"
      brew install jq
      ok "jq ready"
      ;;
    debian)
      ensure_sudo_session
      step "Installing jq"
      run_quiet "jq installation" run_with_sudo env DEBIAN_FRONTEND=noninteractive \
        apt-get install -yq --no-install-recommends jq
      ok "jq ready"
      ;;
    *)
      fail "jq is required for cloud enrollment. Install it manually, then re-run."
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

    note "A GitHub token with read access to $REPO_SLUG is required"
    read_secret_with_reveal GITHUB_TOKEN "  GitHub token for $REPO_SLUG: "

    [ -n "$GITHUB_TOKEN" ] || fail "GitHub token is required to fetch the private Alfred repo."
  fi

  step "Authenticating GitHub"
  gh auth login --hostname github.com --with-token <<< "$GITHUB_TOKEN" >/dev/null
  gh auth setup-git >/dev/null 2>&1 || true
  ok "GitHub authenticated"
}

ensure_writable_directory() {
  local target="$1"

  if [ -d "$target" ]; then
    [ -w "$target" ] || fail "Directory exists but is not writable: $target"
    return
  fi

  if [ "$MODE" = "cloud" ]; then
    ensure_sudo_session
    run_quiet "create directory $target" run_with_sudo install -d -m 0755 -o "$USER" -g "$(id -gn)" "$target"
  else
    mkdir -p "$target"
  fi
}

ensure_runtime_directories() {
  ensure_writable_directory "$REPO_DIR"
  ensure_writable_directory "$DATA_DIR"
  mkdir -p "$(dirname "$INSTALL_STATE_FILE")" "$(dirname "$CLOUD_ENV_FILE")" "$(dirname "$TUNNEL_ENV_FILE")"
}

ensure_cloud_service_user() {
  [ "$MODE" = "cloud" ] || return 0
  case "$(detect_os)" in
    debian|linux-other) ;;
    *)
      fail "Cloud mode is Linux-only in v1."
      ;;
  esac

  if id "$CLOUD_SERVICE_USER" >/dev/null 2>&1; then
    ok "Cloud service user ready"
    return
  fi

  if ! command -v useradd >/dev/null 2>&1; then
    warn "useradd not found; skipping cloud service user creation. The runtime repo must handle its own service account until this host is prepared."
    return 0
  fi

  ensure_sudo_session
  step "Ensuring cloud service user"
  run_quiet "service user creation" run_with_sudo useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$CLOUD_SERVICE_USER"
  ok "Cloud service user ready"
}

collect_ssh_host_key_fingerprint() {
  local candidate
  for candidate in /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_rsa_key.pub; do
    if [ -r "$candidate" ] && command -v ssh-keygen >/dev/null 2>&1; then
      ssh-keygen -lf "$candidate" 2>/dev/null | awk '{print $2}' || true
      return 0
    fi
  done
  return 0
}

maybe_load_existing_cloud_bootstrap() {
  [ "$MODE" = "cloud" ] || return 0
  [ "$FORCE_REENROLL" -eq 0 ] || return 0
  [ -f "$CLOUD_ENV_FILE" ] || return 0

  load_env_file "$CLOUD_ENV_FILE"

  CLOUD_TENANT_ID="${ALFRED_TENANT_ID:-$CLOUD_TENANT_ID}"
  CLOUD_TENANT_SLUG="${ALFRED_TENANT_SLUG:-$CLOUD_TENANT_SLUG}"
  CLOUD_RUNTIME_ID="${ALFRED_RUNTIME_ID:-$CLOUD_RUNTIME_ID}"
  CLOUD_RUNTIME_SECRET="${ALFRED_RUNTIME_SECRET:-$CLOUD_RUNTIME_SECRET}"
  CLOUD_API_BASE_URL="${ALFRED_CLOUD_API_BASE_URL:-$CLOUD_API_BASE_URL}"
  CLOUD_ENROLLMENT_URL="${ALFRED_CLOUD_ENROLLMENT_URL:-$CLOUD_ENROLLMENT_URL}"
  CLOUD_DECOMMISSION_URL="${ALFRED_CLOUD_DECOMMISSION_URL:-$CLOUD_DECOMMISSION_URL}"
  CLOUD_EDGE_ISSUER="${ALFRED_CLOUD_EDGE_ISSUER:-$CLOUD_EDGE_ISSUER}"
  CLOUD_EDGE_AUDIENCE="${ALFRED_CLOUD_EDGE_AUDIENCE:-$CLOUD_EDGE_AUDIENCE}"
  CLOUD_EDGE_JWKS_URL="${ALFRED_CLOUD_EDGE_JWKS_URL:-$CLOUD_EDGE_JWKS_URL}"
  CLOUD_HEARTBEAT_INTERVAL_S="${ALFRED_CLOUD_HEARTBEAT_INTERVAL_S:-$CLOUD_HEARTBEAT_INTERVAL_S}"
  CLOUD_SERVICE_USER="${ALFRED_CLOUD_SERVICE_USER:-$CLOUD_SERVICE_USER}"

  if [ -f "$TUNNEL_ENV_FILE" ]; then
    load_env_file "$TUNNEL_ENV_FILE"
    CLOUD_TUNNEL_PROVIDER="${ALFRED_CLOUD_TUNNEL_PROVIDER:-$CLOUD_TUNNEL_PROVIDER}"
    CLOUD_TUNNEL_PUBLIC_KEY="${ALFRED_CLOUD_TUNNEL_PUBLIC_KEY:-$CLOUD_TUNNEL_PUBLIC_KEY}"
    CLOUD_TUNNEL_CONFIG_JSON="${ALFRED_CLOUD_TUNNEL_CONFIG_JSON:-$CLOUD_TUNNEL_CONFIG_JSON}"
  fi

  if [ -n "$CLOUD_RUNTIME_ID" ] && [ -n "$CLOUD_RUNTIME_SECRET" ]; then
    CLOUD_REUSED_EXISTING_BOOTSTRAP=1
    note "Existing cloud runtime bootstrap detected; reusing runtime_id=$CLOUD_RUNTIME_ID"
  fi
}

enrollment_response_value() {
  local response="$1"
  local jq_expr="$2"
  local label="$3"
  local value

  value="$(printf '%s' "$response" | jq -er "$jq_expr" 2>/dev/null || true)"
  [ -n "$value" ] || fail "Cloud enrollment response missing $label"
  printf '%s\n' "$value"
}

maybe_override_branch_from_enrollment() {
  local response="$1"
  local runtime_ref

  runtime_ref="$(printf '%s' "$response" | jq -r '(.runtime_ref // .runtime_repo_ref // .runtime.ref // empty)' 2>/dev/null || true)"
  if [ -n "$runtime_ref" ] && [ "$runtime_ref" != "null" ]; then
    BRANCH="$runtime_ref"
    note "Alfred Cloud pinned runtime ref: $BRANCH"
  fi
}

enroll_cloud_runtime() {
  local response machine_hostname machine_arch machine_os machine_region machine_ssh_fp runtime_version_hint request_body

  [ "$MODE" = "cloud" ] || return 0

  if [ "$CLOUD_REUSED_EXISTING_BOOTSTRAP" -eq 1 ]; then
    persist_cloud_config
    persist_tunnel_config
    return 0
  fi

  [ -n "$ENROLLMENT_TOKEN" ] || fail "Cloud mode requires --enrollment-token TOKEN."
  [ -n "$CLOUD_ENROLLMENT_STUB_FILE" ] || [ -n "$CLOUD_ENROLLMENT_URL" ] || [ -n "$CLOUD_API_BASE_URL" ] || \
    fail "Cloud mode requires ALFRED_CLOUD_ENROLLMENT_URL or ALFRED_CLOUD_API_BASE_URL (or ALFRED_CLOUD_ENROLLMENT_STUB_FILE for dev/test)."

  ensure_jq
  need_cmd curl

  if [ -z "$CLOUD_ENROLLMENT_URL" ] && [ -n "$CLOUD_API_BASE_URL" ]; then
    CLOUD_ENROLLMENT_URL="${CLOUD_API_BASE_URL%/}/v1/runtimes/enroll"
  fi

  machine_hostname="$(hostname 2>/dev/null || uname -n)"
  machine_arch="$(uname -m)"
  machine_os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  machine_region="$CLOUD_MACHINE_REGION"
  machine_ssh_fp="$(collect_ssh_host_key_fingerprint)"
  runtime_version_hint="${CLOUD_RUNTIME_VERSION_HINT:-$BRANCH}"

  request_body="$(jq -n \
    --arg enrollment_token "$ENROLLMENT_TOKEN" \
    --arg installer_version "$INSTALLER_VERSION" \
    --arg runtime_version "$runtime_version_hint" \
    --arg hostname "$machine_hostname" \
    --arg os "$machine_os" \
    --arg arch "$machine_arch" \
    --arg region "$machine_region" \
    --arg ssh_host_key_fingerprint "$machine_ssh_fp" \
    --arg provider_preference "$CLOUD_TUNNEL_PROVIDER" \
    --arg public_key "$CLOUD_TUNNEL_PUBLIC_KEY" \
    '
    {
      enrollment_token: $enrollment_token,
      installer_version: $installer_version,
      runtime_version: $runtime_version,
      machine: {
        hostname: $hostname,
        os: $os,
        arch: $arch,
        region: $region
      },
      tunnel: {
        provider_preference: $provider_preference,
        public_key: $public_key
      }
    }
    | if $ssh_host_key_fingerprint != "" then
        .machine.ssh_host_key_fingerprint = $ssh_host_key_fingerprint
      else
        .
      end
    ' )"

  if [ -n "$CLOUD_ENROLLMENT_STUB_FILE" ]; then
    [ -r "$CLOUD_ENROLLMENT_STUB_FILE" ] || fail "Enrollment stub file not readable: $CLOUD_ENROLLMENT_STUB_FILE"
    step "Loading cloud enrollment stub"
    response="$(<"$CLOUD_ENROLLMENT_STUB_FILE")"
  else
    step "Enrolling runtime with Alfred Cloud"
    response="$(curl -fsSL \
      --connect-timeout 10 \
      --max-time 30 \
      -H 'Content-Type: application/json' \
      -X POST \
      --data "$request_body" \
      "$CLOUD_ENROLLMENT_URL")"
  fi

  maybe_override_branch_from_enrollment "$response"
  CLOUD_RUNTIME_ID="$(enrollment_response_value "$response" '.runtime_id' 'runtime_id')"
  CLOUD_TENANT_ID="$(enrollment_response_value "$response" '.tenant_id' 'tenant_id')"
  CLOUD_TENANT_SLUG="$(enrollment_response_value "$response" '.tenant_slug' 'tenant_slug')"
  CLOUD_RUNTIME_SECRET="$(enrollment_response_value "$response" '.runtime_secret' 'runtime_secret')"
  CLOUD_EDGE_ISSUER="$(enrollment_response_value "$response" '.edge.issuer' 'edge.issuer')"
  CLOUD_EDGE_AUDIENCE="$(enrollment_response_value "$response" '.edge.audience' 'edge.audience')"
  CLOUD_EDGE_JWKS_URL="$(enrollment_response_value "$response" '.edge.jwks_url' 'edge.jwks_url')"
  CLAIM_URL="$(enrollment_response_value "$response" '.claim_url' 'claim_url')"
  CLOUD_HEARTBEAT_INTERVAL_S="$(printf '%s' "$response" | jq -r '(.heartbeat_interval_s // 30 | tostring)' 2>/dev/null || printf '30')"
  CLOUD_TUNNEL_PROVIDER="$(printf '%s' "$response" | jq -r '(.tunnel.provider // "wireguard")' 2>/dev/null || printf 'wireguard')"
  CLOUD_TUNNEL_CONFIG_JSON="$(printf '%s' "$response" | jq -c '.tunnel.config // {}' 2>/dev/null || printf '{}')"
  CLOUD_DID_ENROLL=1

  if [ -z "$CLOUD_API_BASE_URL" ] && [ -n "$CLOUD_ENROLLMENT_URL" ]; then
    CLOUD_API_BASE_URL="$(derive_cloud_api_base_url_from_enrollment_url)"
  fi

  persist_cloud_config
  persist_tunnel_config
  ok "Cloud runtime enrolled"
}

invoke_runtime_install() {
  local install_args runtime_exit
  install_args=(--repo-dir "$REPO_DIR" --data-dir "$DATA_DIR" --branch "$BRANCH")

  if [ "$MODE" = "local" ] && [ "$DEV_MODE" -eq 1 ]; then
    install_args+=(--dev)
  fi
  if [ "$MODE" = "local" ] && [ "$INSTALL_LAUNCHD" -eq 1 ]; then
    install_args+=(--launchd)
  fi
  if [ "$MODE" = "local" ] && [ -n "$INSTALL_SYSTEMD" ]; then
    if [ "$INSTALL_SYSTEMD" -eq 1 ]; then
      install_args+=(--systemd)
    else
      install_args+=(--no-systemd)
    fi
  fi
  if [ "$NON_INTERACTIVE" -eq 1 ] || [ "$MODE" = "cloud" ]; then
    install_args+=(--non-interactive)
  fi
  if [ "$MODE" = "local" ] && [ "$FRESH_DB" -eq 1 ]; then
    install_args+=(--fresh-db)
  fi
  if [ "$MODE" = "local" ] && [ -n "$MIGRATE_DB_PATH" ]; then
    install_args+=(--migrate-db "$MIGRATE_DB_PATH")
  fi
  if [ "$MODE" = "local" ] && [ "$SKIP_OPENCLAW_WIZARD" -eq 1 ]; then
    install_args+=(--skip-intelligence-wizard)
  fi
  if [ "$MODE" = "local" ] && [ "$SKIP_ENTITY_WIZARD" -eq 1 ]; then
    install_args+=(--skip-entity-wizard)
  fi
  if [ "$SKIP_START" -eq 1 ]; then
    install_args+=(--no-start)
  fi

  step "Preparing Alfred runtime"
  bash "$REPO_DIR/scripts/bootstrap-host.sh"

  step "Installing Alfred"
  set +e
  env \
    ALFRED_REPO_DIR="$REPO_DIR" \
    ALFRED_REPO_BRANCH="$BRANCH" \
    ALFRED_REPO_URL="https://github.com/$REPO_SLUG.git" \
    ALFRED_REPO_PREPARED=1 \
    ALFRED_INSTALL_MODE="$MODE" \
    ALFRED_DEPLOYMENT_MODE="$MODE" \
    ALFRED_INSTALL_STATE_FILE="$INSTALL_STATE_FILE" \
    ALFRED_CLOUD_ENV_FILE="$CLOUD_ENV_FILE" \
    ALFRED_CLOUD_TUNNEL_ENV_FILE="$TUNNEL_ENV_FILE" \
    ALFRED_CLOUD_SERVICE_USER="$CLOUD_SERVICE_USER" \
    ALFRED_CLOUD_API_BASE_URL="$CLOUD_API_BASE_URL" \
    ALFRED_CLOUD_ENROLLMENT_URL="$CLOUD_ENROLLMENT_URL" \
    ALFRED_CLOUD_DECOMMISSION_URL="$CLOUD_DECOMMISSION_URL" \
    ALFRED_TENANT_ID="$CLOUD_TENANT_ID" \
    ALFRED_TENANT_SLUG="$CLOUD_TENANT_SLUG" \
    ALFRED_RUNTIME_ID="$CLOUD_RUNTIME_ID" \
    ALFRED_RUNTIME_SECRET="$CLOUD_RUNTIME_SECRET" \
    ALFRED_CLOUD_EDGE_ISSUER="$CLOUD_EDGE_ISSUER" \
    ALFRED_CLOUD_EDGE_AUDIENCE="$CLOUD_EDGE_AUDIENCE" \
    ALFRED_CLOUD_EDGE_JWKS_URL="$CLOUD_EDGE_JWKS_URL" \
    ALFRED_CLOUD_HEARTBEAT_INTERVAL_S="$CLOUD_HEARTBEAT_INTERVAL_S" \
    ALFRED_CLOUD_TUNNEL_PROVIDER="$CLOUD_TUNNEL_PROVIDER" \
    ALFRED_CLOUD_TUNNEL_CONFIG_JSON="$CLOUD_TUNNEL_CONFIG_JSON" \
    bash "$REPO_DIR/scripts/install.sh" "${install_args[@]}"
  runtime_exit=$?
  set -e

  return "$runtime_exit"
}

print_cloud_handoff() {
  [ "$MODE" = "cloud" ] || return 0

  if [ -n "$CLAIM_URL" ]; then
    section "Cloud enrollment" "$C_MAGENTA"
    note "Hand this claim URL to the customer owner exactly once:"
    printf '    %s\n' "$CLAIM_URL"
    note "Do not store this URL in shared logs or tickets."
  else
    note "Cloud runtime already had stored enrollment state; no new claim URL was emitted"
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode)
      shift
      MODE="${1:-}"
      ;;
    --repo-dir)
      shift
      RAW_REPO_DIR="${1:-}"
      ;;
    --data-dir)
      shift
      RAW_DATA_DIR="${1:-}"
      ;;
    --branch)
      shift
      BRANCH="${1:-}"
      ;;
    --dev)
      DEV_MODE=1
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
    --enrollment-token)
      shift
      ENROLLMENT_TOKEN="${1:-}"
      ;;
    --force-reenroll)
      FORCE_REENROLL=1
      ;;
    --skip-intelligence-wizard|--skip-openclaw-wizard)
      SKIP_OPENCLAW_WIZARD=1
      USER_SET_SKIP_OPENCLAW_WIZARD=1
      ;;
    --skip-entity-wizard)
      SKIP_ENTITY_WIZARD=1
      USER_SET_SKIP_ENTITY_WIZARD=1
      ;;
    --telegram-token-file)
      shift
      TELEGRAM_TOKEN_FILE="${1:-}"
      USER_SET_TELEGRAM_TOKEN_FILE=1
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

if [ "$MODE" = "cloud" ]; then
  NON_INTERACTIVE=1
  SKIP_OPENCLAW_WIZARD=1
  SKIP_ENTITY_WIZARD=1
  TELEGRAM_TOKEN_FILE=""
fi

resolve_mode_defaults
validate_args
load_existing_install_state
generate_install_id

DEFAULT_DB_PATH="$DATA_DIR/data/finance_ops.sqlite"
if [ "$MODE" = "local" ] && [ "$FRESH_DB" -eq 0 ] && [ -z "$MIGRATE_DB_PATH" ] && [ ! -f "$DEFAULT_DB_PATH" ]; then
  FRESH_DB=1
  AUTO_FRESH_DB=1
fi

if [ "$PRINT_SUMMARY_ONLY" -eq 1 ]; then
  print_summary
  exit 0
fi

banner
warn_deprecated_flags

if [ "$AUTO_FRESH_DB" -eq 1 ]; then
  note "Fresh install detected — Alfred will create a local database at $DEFAULT_DB_PATH"
fi

enforce_runtime_host_constraints
ensure_runtime_directories
persist_install_state

if [ "$MODE" = "cloud" ]; then
  ensure_cloud_service_user
  maybe_load_existing_cloud_bootstrap
fi

INSTALL_STATUS="preflight"
persist_install_state

section "Prerequisites" "$C_CYAN"
ensure_github_cli
ensure_github_auth
need_cmd git
need_cmd curl

if [ "$MODE" = "cloud" ]; then
  enroll_cloud_runtime
  persist_install_state
fi

section "Repository" "$C_BLUE"
if [ ! -d "$REPO_DIR/.git" ]; then
  step "Cloning Alfred into $REPO_DIR"
  if [ -n "$BRANCH" ]; then
    run_quiet "repository clone" gh repo clone "$REPO_SLUG" "$REPO_DIR" -- --branch "$BRANCH"
  else
    run_quiet "repository clone" gh repo clone "$REPO_SLUG" "$REPO_DIR"
  fi
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

INSTALL_STATUS="runtime_install"
persist_install_state

if ! invoke_runtime_install; then
  INSTALL_STATUS="runtime_install_failed"
  persist_install_state
  if [ "$MODE" = "cloud" ] && [ "$CLOUD_DID_ENROLL" -eq 1 ]; then
    warn "Cloud enrollment succeeded but runtime installation failed. The claim URL was not persisted and may need to be reissued before customer handoff."
  fi
  exit 1
fi

INSTALL_STATUS="completed"
persist_install_state
print_cloud_handoff
