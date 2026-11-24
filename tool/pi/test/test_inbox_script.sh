#!/usr/bin/env bash
# Regression test for setup_inbox.sh: runs against temp paths, no root, no Pi.
#   bash tool/pi/test/test_inbox_script.sh

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PI="$(cd "$HERE/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
FAILS=0; PASSES=0
check() { local n="$1"; shift; if "$@"; then PASSES=$((PASSES + 1)); echo "ok   $n"; else FAILS=$((FAILS + 1)); echo "FAIL $n"; fi; }

export TVSAVER_TEST=1 TVSAVER_OWNER=tester
export TVSAVER_INBOX_DIR="$T/inbox" TVSAVER_SMB_CONF="$T/smb.conf"
printf '[global]\n   workgroup = WORKGROUP\n' > "$T/smb.conf"
run() { bash "$PI/setup_inbox.sh" "$@"; }

out1="$(run)"; code1=$?
check "first run succeeds" test "$code1" = 0
check "creates the folder" test -d "$T/inbox"
check "writes the share" grep -q '^\[inbox\]' "$T/smb.conf"
check "keeps existing config" grep -q 'workgroup = WORKGROUP' "$T/smb.conf"
check "share requires a login" grep -q 'guest ok = no' "$T/smb.conf"
check "tells how to set the password" grep -q 'smbpasswd' <<<"$out1"

out2="$(run)"
check "second run changes nothing" test "$out2" = "no changes"
check "block appears once" test "$(grep -c '^\[inbox\]' "$T/smb.conf")" = 1

sed -i 's/read only = no/read only = yes/' "$T/smb.conf"
out3="$(run)"
check "repairs a modified share" grep -q 'read only = no' "$T/smb.conf"
check "repair is reported" grep -q 'done: 1 change' <<<"$out3"

cp "$T/smb.conf" "$T/before"
sed -i 's/read only = no/read only = yes/' "$T/smb.conf"; cp "$T/smb.conf" "$T/dry"
out4="$(run --dry-run)"
check "dry run does not write" cmp -s "$T/smb.conf" "$T/dry"
check "dry run says what it would do" grep -q 'dry-run' <<<"$out4"
check "bad argument is an error" bash -c "! bash '$PI/setup_inbox.sh' --nope 2>/dev/null"

echo "passed $PASSES, failed $FAILS"
test "$FAILS" = 0
