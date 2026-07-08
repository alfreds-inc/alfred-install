#!/usr/bin/env bash
set -euo pipefail
# test-cleanup-himalaya.sh — self-contained test for stage_remove_himalaya_accounts.
#
# cleanup.sh must stay a single curl-able file, so its stages can't be sourced
# from a helper. This test extracts the real function body from cleanup.sh and
# runs it against fixtures with the output helpers stubbed, so it exercises the
# exact code that ships (no reimplementation to drift from).

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP="$HERE/cleanup.sh"
PASS=0
FAIL=0

# Extract `stage_remove_himalaya_accounts() { ... }` (def line to first line that
# is a bare `}` at column 0) so we can eval just that function.
extract_stage() {
  awk '
    /^stage_remove_himalaya_accounts\(\) \{/ { grab=1 }
    grab { print }
    grab && /^\}/ { exit }
  ' "$CLEANUP"
}

run_stage() {
  # $1 = HOME to use; any further args are extra `VAR=value` env assignments
  # splatted ahead of the harness (e.g. KEEP_OPENCLAW_WORKSPACE=1). Stubs keep
  # output quiet + deterministic.
  local home="$1"; shift
  HOME="$home" INSTALL_MODE="local" DATA_DIR="$home/data" DRY_RUN=0 env "$@" \
    bash -c "
      set -euo pipefail
      say(){ :; }; ok(){ :; }; warn(){ :; }; plan(){ :; }
      $(extract_stage)
      stage_remove_himalaya_accounts
    "
}

check() { # desc, condition already evaluated via [ ]
  if [ "$1" = "0" ]; then printf 'PASS  %s\n' "$2"; PASS=$((PASS + 1));
  else printf 'FAIL  %s\n' "$2"; FAIL=$((FAIL + 1)); fi
}

managed_block() { # name email secretpath
  printf '# >>> Alfred mail account: %s >>>\n' "$1"
  printf '[accounts."%s"]\n' "$1"
  printf 'email = "%s"\n' "$2"
  printf 'backend.auth.cmd = "cat \\"%s\\""\n' "$3"
  printf '# <<< Alfred mail account: %s <<<\n' "$1"
}

# --- Case 1: managed + unmanaged → keep file, drop only Alfred's blocks -------
t1="$(mktemp -d)"
mkdir -p "$t1/.config/himalaya"
{
  managed_block "sinapsys" "sinapsys@example.com" "$t1/secrets/sinapsys"
  printf '\n'
  managed_block "nicolau-farre" "nicolau@example.com" "$t1/secrets/nicolau"
  printf '\n[accounts."hand-rolled"]\nemail = "manual@example.com"\n'
} > "$t1/.config/himalaya/config.toml"

run_stage "$t1"
cfg="$t1/.config/himalaya/config.toml"
[ -f "$cfg" ]; check "$?" "case1: config file preserved (unmanaged account present)"
if grep -q 'Alfred mail account' "$cfg"; then check 1 "case1: no Alfred markers remain"; else check 0 "case1: no Alfred markers remain"; fi
if grep -q '\[accounts."hand-rolled"\]' "$cfg"; then check 0 "case1: unmanaged account retained"; else check 1 "case1: unmanaged account retained"; fi
if grep -q '\[accounts."sinapsys"\]' "$cfg"; then check 1 "case1: managed account removed"; else check 0 "case1: managed account removed"; fi

# --- Case 2: only Alfred-managed accounts → remove the file entirely ----------
t2="$(mktemp -d)"
mkdir -p "$t2/.config/himalaya"
{
  managed_block "sinapsys" "sinapsys@example.com" "$t2/secrets/sinapsys"
  printf '\n'
  managed_block "nicolau-farre" "nicolau@example.com" "$t2/secrets/nicolau"
} > "$t2/.config/himalaya/config.toml"

run_stage "$t2"
if [ -f "$t2/.config/himalaya/config.toml" ]; then check 1 "case2: Alfred-only config file removed"; else check 0 "case2: Alfred-only config file removed"; fi

# --- Case 3: no config file → no-op, no error --------------------------------
t3="$(mktemp -d)"
run_stage "$t3"
check "$?" "case3: missing config is a clean no-op"

# --- Case 4: KEEP_OPENCLAW_WORKSPACE=1 → stage is a no-op, file untouched -----
t4="$(mktemp -d)"
mkdir -p "$t4/.config/himalaya"
{
  managed_block "sinapsys" "sinapsys@example.com" "$t4/secrets/sinapsys"
  printf '\n'
  managed_block "nicolau-farre" "nicolau@example.com" "$t4/secrets/nicolau"
} > "$t4/.config/himalaya/config.toml"
cfg4="$t4/.config/himalaya/config.toml"
before4="$(shasum "$cfg4" | awk '{print $1}')"
run_stage "$t4" KEEP_OPENCLAW_WORKSPACE=1
after4="$(shasum "$cfg4" | awk '{print $1}')"
if [ -f "$cfg4" ] && [ "$before4" = "$after4" ]; then check 0 "case4: keep-workspace leaves config byte-identical"; else check 1 "case4: keep-workspace leaves config byte-identical"; fi

# --- Case 5: managed block + top-level setting (no unmanaged account) ---------
#     → keep the file (non-whitespace survivor rule), strip Alfred's markers.
t5="$(mktemp -d)"
mkdir -p "$t5/.config/himalaya"
{
  printf 'downloads-dir = "/tmp/x"\n\n'
  managed_block "sinapsys" "sinapsys@example.com" "$t5/secrets/sinapsys"
} > "$t5/.config/himalaya/config.toml"
cfg5="$t5/.config/himalaya/config.toml"
run_stage "$t5"
[ -f "$cfg5" ]; check "$?" "case5: config kept (top-level setting survives)"
if grep -q 'downloads-dir = "/tmp/x"' "$cfg5"; then check 0 "case5: top-level setting retained"; else check 1 "case5: top-level setting retained"; fi
if grep -q 'Alfred mail account' "$cfg5"; then check 1 "case5: no Alfred markers remain"; else check 0 "case5: no Alfred markers remain"; fi

rm -rf "$t1" "$t2" "$t3" "$t4" "$t5"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
