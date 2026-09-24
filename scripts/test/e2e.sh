#!/bin/bash
# =============================================================================
# PRECISE Hub - End-to-end test against local fake mount directories
# Usage: scripts/test/e2e.sh [workdir]   (exit code 0 = all checks passed)
# =============================================================================
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="${1:-$(mktemp -d /tmp/precise-e2e.XXXXXX)}"
rm -rf "${T:?}"/*
export DEG_PATH="$T/deg" FORSCHUNGSSPEICHER_PATH="$T/fs" DATA_LAKE_PATH="$T/dl" LOCAL_STAGING_PATH="$T/staging"
export STABILITY_THRESHOLD=60
DEPLOY="$REPO/scripts/process/deploy/process-uploads.sh"
FETCH="$REPO/scripts/process/fetch/process-fetch-requests.sh"
mkdir -p "$DEG_PATH"/{UKF,UKK}/{upload,requests,download,messages} "$DATA_LAKE_PATH" "$FORSCHUNGSSPEICHER_PATH/UKF/upload"

FAIL=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; FAIL=$((FAIL + 1)); fi; }
run() { "$1" > "$T/$2.log" 2>&1 || echo "  (cycle exited non-zero, see $T/$2.log)"; }
age() { touch -d "$1" "${@:2}"; }

# mkpkg DIR NAME EXAM...  -> NAME.tar.zst (+ .sha256) containing one folder per exam
mkpkg() {
  local dir=$1 name=$2; shift 2; local w; w=$(mktemp -d)
  for e in "$@"; do mkdir -p "$w/$e"; head -c 20000 /dev/urandom > "$w/$e/data.bin"; done
  tar -cf - -C "$w" . | zstd -q -o "$dir/$name.tar.zst"
  (cd "$dir" && sha256sum "$name.tar.zst" > "$name.tar.zst.sha256"); rm -rf "$w"
}
msgs() { ls "$DEG_PATH/$1/messages" | grep -c "$2"; }

echo "# batch upload"
mkpkg "$DEG_PATH/UKF/upload" UKF_2026-09-24_00 UKF_00042 UKF_00043 UKF_99999x
mkpkg "$DEG_PATH/UKK/upload" UKK_2026-09-24_00 UKK_00301 UKK_00150
run "$DEPLOY" deploy1
check "exam folders stored in shards"      '[[ -d $DATA_LAKE_PATH/Data/UKF/00000/UKF_00043 && -d $DATA_LAKE_PATH/Data/UKK/00300/UKK_00301 ]]'
check "source archives deleted"            '[[ -z "$(find $DEG_PATH/UKF/upload $DEG_PATH/UKK/upload -type f)" ]]'
check "stored message written"             '[[ $(msgs UKF upload_stored) -eq 1 ]]'
check "invalid folder listed in message"   'jq -e ".invalid_folders == [\"UKF_99999x\"]" $DEG_PATH/UKF/messages/*upload_stored* >/dev/null'

echo "# checksum mismatch: wait while fresh, mark when stable, accept corrected checksum"
mkpkg "$DEG_PATH/UKF/upload" UKF_2026-09-24_01 UKF_00050
cp "$DEG_PATH/UKF/upload/UKF_2026-09-24_01.tar.zst.sha256" "$T/good.sha256"
echo "deadbeef  UKF_2026-09-24_01.tar.zst" > "$DEG_PATH/UKF/upload/UKF_2026-09-24_01.tar.zst.sha256"
run "$DEPLOY" deploy2
check "fresh mismatching upload untouched" '[[ -f $DEG_PATH/UKF/upload/UKF_2026-09-24_01.tar.zst.sha256 ]]'
age '5 minutes ago' "$DEG_PATH/UKF/upload/UKF_2026-09-24_01.tar.zst"
run "$DEPLOY" deploy3
check "mismatch marker after stable"       '[[ -f $DEG_PATH/UKF/upload/UKF_2026-09-24_01.tar.zst.sha256.mismatch ]]'
check "rejected message written"           '[[ $(msgs UKF upload_rejected_UKF_2026-09-24_01) -eq 1 ]]'
run "$DEPLOY" deploy4
check "marked archive skipped quietly"     '! grep -q ERROR $T/deploy4.log'
cp "$T/good.sha256" "$DEG_PATH/UKF/upload/UKF_2026-09-24_01.tar.zst.sha256"
run "$DEPLOY" deploy5
check "corrected checksum processed"       '[[ -d $DATA_LAKE_PATH/Data/UKF/00000/UKF_00050 && ! -e $DEG_PATH/UKF/upload/UKF_2026-09-24_01.tar.zst ]]'

echo "# rejections: invalid name, empty package; retry after data lake failure"
mkpkg "$DEG_PATH/UKF/upload" badname UKF_00045
w=$(mktemp -d); echo x > "$w/readme.txt"; tar -cf - -C "$w" . | zstd -q -o "$DEG_PATH/UKF/upload/UKF_2026-09-24_02.tar.zst"
(cd "$DEG_PATH/UKF/upload" && sha256sum UKF_2026-09-24_02.tar.zst > UKF_2026-09-24_02.tar.zst.sha256)
mkpkg "$DEG_PATH/UKF/upload" UKF_2026-09-24_03 UKF_00160
age '5 minutes ago' "$DEG_PATH/UKF/upload/badname.tar.zst"
mkdir -p "$DATA_LAKE_PATH/Data/UKF/00100" && chmod 555 "$DATA_LAKE_PATH/Data/UKF/00100"
run "$DEPLOY" deploy6
check "invalid name renamed .rejected"     '[[ -f $DEG_PATH/UKF/upload/badname.tar.zst.rejected ]]'
check "empty package rejected"             '[[ -f $DEG_PATH/UKF/upload/UKF_2026-09-24_02.tar.zst.rejected ]]'
check "source kept after store failure"    '[[ -f $DEG_PATH/UKF/upload/UKF_2026-09-24_03.tar.zst ]]'
chmod 755 "$DATA_LAKE_PATH/Data/UKF/00100"
run "$DEPLOY" deploy7
check "retry stores folder"                '[[ -d $DATA_LAKE_PATH/Data/UKF/00100/UKF_00160 && ! -e $DEG_PATH/UKF/upload/UKF_2026-09-24_03.tar.zst ]]'
check "no partial folders left"            '[[ -z "$(find $DATA_LAKE_PATH -name ".partial_*")" ]]'

echo "# fetch: valid request with one missing id, invalid json, unknown org"
echo '{"organization":"UKF","requested_ids":["UKK_00301","UKK_00150","UKK_00999"]}' > "$DEG_PATH/UKF/requests/request_2026-09-24_00.json"
echo '{oops' > "$DEG_PATH/UKF/requests/request_2026-09-24_01.json"
echo '{"organization":"XXX","requested_ids":["UKK_00301"]}' > "$DEG_PATH/UKF/requests/request_2026-09-24_02.json"
run "$FETCH" fetch1
check "download package + valid checksum"  '(cd $DEG_PATH/UKF/download && sha256sum -c --quiet *.sha256)'
check "requests folder emptied"            '[[ -z "$(ls $DEG_PATH/UKF/requests)" ]]'
check "failed requests archived"           '[[ $(ls $DEG_PATH/UKF/archived-requests | grep -c FAILED) -eq 2 ]]'
check "two distinct error messages"        '[[ $(msgs UKF fetch_error) -eq 2 ]]'
check "ready message lists skipped id"     'jq -e ".skipped_ids == [\"UKK_00999\"]" $DEG_PATH/UKF/messages/*fetch_ready* >/dev/null'
run "$FETCH" fetch2
check "second cycle writes no new errors"  '[[ $(msgs UKF fetch_error) -eq 2 ]]'

echo "# download expiry"
age '50 hours ago' "$DEG_PATH/UKF/download"/*
run "$FETCH" fetch3
check "downloads older than 48h removed"   '[[ -z "$(ls $DEG_PATH/UKF/download)" ]]'
check "expired message written"            '[[ $(msgs UKF fetch_expired) -eq 1 ]]'

echo "# staging"
check "staging clean after cycles"         '[[ -z "$(find $LOCAL_STAGING_PATH/deploy $LOCAL_STAGING_PATH/fetch -type f)" ]]'

echo
if [[ $FAIL -eq 0 ]]; then echo "ALL CHECKS PASSED ($T)"; else echo "$FAIL CHECK(S) FAILED ($T)"; fi
exit $FAIL
