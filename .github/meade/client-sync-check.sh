#!/usr/bin/env bash
# The Nextcloud desktop client's own sync engine (nextcloudcmd) against a
# fresh OxiCloud: a 30 MiB file goes up as three 10 MiB chunks, a second sync
# must find nothing to do, and a second folder must download the same bytes.
# On stock 0.9.3 the first sync fails with "Missing File ID from server" and
# every later sync uploads the file again.
#
# Usage: client-sync-check.sh <base-url> <work-dir>
# The server must be new: this creates its first admin account. Test data only.
set -euo pipefail

BASE=${1:?base url}
WORK=${2:?work dir}
USER_NAME=probe
PASS="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')"

fail() { echo "client-sync-check: FAIL: $*" >&2; exit 1; }

rm -rf "$WORK"
mkdir -p "$WORK/up" "$WORK/down"

curl -fsS -o /dev/null -X POST "$BASE/api/setup" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$USER_NAME\",\"email\":\"probe@example.com\",\"password\":\"$PASS\"}"

# An app password through Login Flow v2, the way the desktop client gets one.
flow="$(curl -fsS -X POST "$BASE/index.php/login/v2")"
poll_token="$(printf '%s' "$flow" | python3 -c 'import sys, json; print(json.load(sys.stdin)["poll"]["token"])')"
flow_token="$(printf '%s' "$flow" | python3 -c 'import sys, json; print(json.load(sys.stdin)["login"].split("/flow/")[1])')"
curl -fsS -o /dev/null -X POST "$BASE/login/v2/flow/$flow_token" \
  --data-urlencode "user=$USER_NAME" --data-urlencode "password=$PASS"
APP_PASS="$(curl -fsS -X POST "$BASE/login/v2/poll" -d "token=$poll_token" \
  | python3 -c 'import sys, json; print(json.load(sys.stdin)["appPassword"])')"

curl -fsS -o /dev/null -u "$USER_NAME:$APP_PASS" -X MKCOL "$BASE/remote.php/dav/files/$USER_NAME/check"
head -c $((30 * 1024 * 1024)) /dev/urandom > "$WORK/up/big.bin"
echo small > "$WORK/up/small.txt"

sync_dir() { # <local dir> <log name>
  OWNCLOUD_CHUNK_SIZE=10485760 OWNCLOUD_MAX_CHUNK_SIZE=10485760 \
    nextcloudcmd --non-interactive -u "$USER_NAME" -p "$APP_PASS" --path /check \
    "$1" "$BASE" > "$WORK/$2.log" 2>&1
}

sync_dir "$WORK/up" first || fail "first sync exited $? (log: $WORK/first.log)"
! grep -q 'Missing File ID' "$WORK/first.log" || fail "first sync: Missing File ID from server"
grep -q 'PropagateUploadFileNG' "$WORK/first.log" || fail "first sync did not use chunked upload"

sync_dir "$WORK/up" second || fail "second sync exited $? (log: $WORK/second.log)"
! grep -q 'propagation of' "$WORK/second.log" || fail "second sync propagated something; it should be idle"

sync_dir "$WORK/down" download || fail "download sync exited $? (log: $WORK/download.log)"
cmp -s "$WORK/up/big.bin" "$WORK/down/big.bin" || fail "downloaded big.bin differs"
cmp -s "$WORK/up/small.txt" "$WORK/down/small.txt" || fail "downloaded small.txt differs"

echo "client-sync-check: OK (chunked upload, idle second sync, identical download)"
