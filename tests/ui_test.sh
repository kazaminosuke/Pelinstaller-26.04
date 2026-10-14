#!/bin/bash
# Screen-transition and input-validation tests for the Pelinstaller CLI.
#
# Every scenario feeds scripted answers on stdin to the real install.sh / ui/*.sh
# and inspects the output. Network access and package managers are replaced by
# the stubs in tests/stubs, and every scenario ends on a "No" answer, so nothing
# is ever installed. The scripts need root and write to /tmp and /var/log, so
# this file refuses to run outside a disposable container (see tests/run.sh).

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PELINSTALLER_REPO="$REPO"

if [ "${PELINSTALLER_TEST_SANDBOX:-}" != 1 ] || [ "$EUID" -ne 0 ]; then
  echo "Refusing to run: use tests/run.sh (needs root inside a throwaway container)." >&2
  exit 2
fi

export PATH="$REPO/tests/stubs:$PATH"
export TERM=dumb

PASS=0
FAIL=0
OUT=""

strip_ansi() { sed -e 's/\x1b\[[0-9;]*m//g' -e 's/\x1b\]8;;[^\a]*\a//g'; }

# run_script <stdin> <script> : runs the script with scripted input, sets OUT and RC
run_script() {
  local input="$1" script="$2"
  printf '%b' "$input" >/tmp/ui_test.stdin
  timeout 30 bash "$REPO/$script" </tmp/ui_test.stdin >/tmp/ui_test.out 2>&1
  RC=$?
  OUT="$(strip_ansi </tmp/ui_test.out)"
}

# run_menu <stdin> : runs install.sh (main menu)
run_menu() { run_script "$1" install.sh; }

pass() { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() {
  FAIL=$((FAIL + 1))
  echo "FAIL - $1"
  echo "----- output -----"
  echo "$OUT" | tail -40
  echo "------------------"
}

# expect <name> <fixed string>... : all strings must appear in OUT
expect() {
  local name="$1" s
  shift
  for s in "$@"; do
    if ! grep -qF -- "$s" <<<"$OUT"; then
      fail "$name (missing: '$s')"
      return
    fi
  done
  pass "$name"
}

# reject <name> <fixed string> : string must not appear in OUT
reject() {
  if grep -qF -- "$2" <<<"$OUT"; then fail "$1 (unexpected: '$2')"; else pass "$1"; fi
}

count() { grep -cF -- "$1" <<<"$OUT"; }

cleanup_state() { rm -rf /var/www/pelican /etc/pelican /tmp/lib.sh; }

# ------------------------------------------------------------------ #
# Main menu
# ------------------------------------------------------------------ #
cleanup_state

run_menu "4\n"
expect "menu lists all five options" \
  "Install the Panel" "Install Wings" "Install Both" "Test Environment" "uninstall"
expect "menu shows copyright notices" "Vilhelm Prytz" "Matthew Jacob" "not associated with the official Pelican Project"
expect "option 4 opens uninstall screen" "Nothing to uninstall"

run_menu "\n4\n"
expect "empty input is rejected and menu is shown again" "Input is required" "Nothing to uninstall"
[ "$(count "Install the Panel")" -ge 2 ] && pass "menu redrawn after empty input" || fail "menu redrawn after empty input"

for bad in 5 9 12 abc; do
  run_menu "$bad\n4\n"
  expect "out-of-range input '$bad' is rejected" "Invalid option" "Nothing to uninstall"
done

# Inputs that used to slip through the substring/regex match and crash the menu
for bad in . "1 2" "[0-4]" 00 -1 "0;1"; do
  run_menu "$bad\n4\n"
  expect "malformed input '$bad' is rejected without crashing" "Invalid option" "Nothing to uninstall"
done

rm -f /tmp/curl-stub.log
GITHUB_SOURCE=feature/some-branch run_menu "4\n"
OUT="$(cat /tmp/curl-stub.log)"
expect "GITHUB_SOURCE selects the branch scripts are loaded from" "/feature/some-branch/lib/lib.sh" "/feature/some-branch/ui/uninstall.sh"
reject "no script loaded from Production when a branch is given" "/Production/"

run_menu ""
[ "$RC" -ne 0 ] && pass "EOF on stdin exits instead of looping (rc=$RC)" || fail "EOF on stdin exits instead of looping"

mkdir -p /etc/pelican
run_menu "9\n4\nn\n"
expect "menu shows detected components" "Panel not installed" "Wings (/etc/pelican)"
[ "$(count "Wings (/etc/pelican)")" -ge 2 ] && pass "status shown again after invalid input" || fail "status shown again after invalid input"
rm -rf /etc/pelican

# ------------------------------------------------------------------ #
# Panel screen (option 0)
# ------------------------------------------------------------------ #
run_menu "0\nn\n\npanel.test\nn\nn\n"
expect "panel: empty FQDN rejected, summary shown, abort honoured" \
  "FQDN cannot be empty" "Hostname/FQDN" "panel.test" "official release" "Installation aborted"
reject "panel: nothing installed after abort" "Base installation complete"

run_menu "0\ny\n\nowner/repo\n\nmy-branch\npanel.test\nn\nn\n"
expect "panel: custom source requires repo and branch" \
  "Repository (owner/repo) cannot be empty" "Branch cannot be empty" "owner/repo" "my-branch" "Installation aborted"

# A resolvable domain: Let's Encrypt is offered and the firewall opt-out warned about
export STUB_IP_RC=1
run_menu "0\nn\npanel.test\nn\nn\nn\nn\n"
expect "panel: firewall opt-out warning shown before Let's Encrypt" \
  "Let's Encrypt requires port 80/443" "Assume SSL" "Installation aborted"
unset STUB_IP_RC

mkdir -p /var/www/pelican
run_menu "0\nn\n"
expect "panel: existing installation warning, 'n' aborts" "already have Pelican panel" "Installation aborted"
rm -rf /var/www/pelican

# ------------------------------------------------------------------ #
# Wings screen (option 1)
# ------------------------------------------------------------------ #
run_menu "1\nn\nn\nn\nn\n"
expect "wings: defaults then abort" "Wings" "Configure database host?" "Installation aborted"

run_menu "1\nn\ny\nn\nbad-name\n\n\nsecret\nn\nn\n"
expect "wings: db user hyphen rejected, empty password rejected" \
  "Database user cannot contain hyphens" "Password cannot be empty" "Installation aborted"

# ------------------------------------------------------------------ #
# Panel + Wings (option 2) and test environment (option 3)
# ------------------------------------------------------------------ #
run_menu "2\nn\npanel.test\nn\nn\nn\n"
expect "both: declining the wings step aborts it" "Installation of wings aborted"

run_menu "2\nn\npanel.test\nn\nn\ny\nn\nn\nn\nn\n"
expect "both: accepting continues to the wings screen" "proceed to wings" "Proceed with installation"

run_menu "3\nn\n"
expect "test environment: summary then abort" "admin" "192.0.2.10" "Installation aborted"

# ------------------------------------------------------------------ #
# Uninstall screen (option 4)
# ------------------------------------------------------------------ #
mkdir -p /var/www/pelican /etc/pelican
run_menu "4\ny\nn\nn\n"
expect "uninstall: detects panel and wings, abort honoured" \
  "Panel installation has been detected" "This will remove all the servers" "Uninstallation aborted"
reject "uninstall: nothing removed after abort" "uninstallation completed"
cleanup_state

# ------------------------------------------------------------------ #
# Library input helpers (unit level)
# ------------------------------------------------------------------ #
# shellcheck source=lib/lib.sh
source "$REPO/lib/lib.sh"

valid_email "admin@example.com" && pass "valid_email accepts a normal address" || fail "valid_email accepts a normal address"
for e in "" "foo" "a@b" "@example.com"; do
  valid_email "$e" && fail "valid_email rejects '$e'" || pass "valid_email rejects '$e'"
done

OUT="$(required_input V "Name: " "" "fallback" <<<"" 2>&1; echo "=[$V]")"
expect "required_input falls back to default" "=[fallback]"

OUT="$( { printf '\nvalue\n' | { required_input V "Name: " "Name cannot be empty"; echo "=[$V]"; }; } 2>&1)"
expect "required_input re-asks until non-empty" "Name cannot be empty" "=[value]"

OUT="$( { printf 'nope\nuser@example.com\n' | { email_input V "Email: " "Email invalid"; echo "=[$V]"; }; } 2>&1)"
expect "email_input re-asks on invalid address" "Email invalid" "=[user@example.com]"

for a in y Y yes; do
  confirm "Q?" <<<"$a" >/dev/null && pass "confirm accepts '$a'" || fail "confirm accepts '$a'"
done
for a in "" n N no; do
  confirm "Q?" <<<"$a" >/dev/null && fail "confirm rejects '$a'" || pass "confirm rejects '$a'"
done

OUT="$( { print_kv "Label" "value"; print_status true "Panel" "/var/www/pelican"; print_status false "Wings"; } | strip_ansi)"
expect "summary/status rows render" "Label" "value" "✔ Panel" "✖ Wings"

OUT="$(NO_COLOR=1 bash -c 'source "$0"; success ok; print_section Title; print_menu_item 0 Item Desc' "$REPO/lib/lib.sh" 2>&1)"
if grep -q $'\x1b\[' <<<"$OUT"; then fail "NO_COLOR removes all colour codes"; else pass "NO_COLOR removes all colour codes"; fi

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
