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
export STABILITY_THRESHOLD=60 DEG_REQUIRE_MOUNTPOINT=0
DEPLOY="$REPO/scripts/process/deploy/process-uploads.sh"
FETCH="$REPO/scripts/process/fetch/process-fetch-requests.sh"
CLEANUP="$REPO/scripts/process/cleanup/cleanup-deg.sh"
REBUILD="$REPO/scripts/process/index/rebuild-index.sh"
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

echo "# per-case packages: package folder, loose case file, case with mismatching content"
mkdir -p "$DEG_PATH/UKF/upload/UKF_2026-09-24_10"
mkpkg "$DEG_PATH/UKF/upload/UKF_2026-09-24_10" UKF_00201 UKF_00201
mkpkg "$DEG_PATH/UKF/upload/UKF_2026-09-24_10" UKF_00202 UKF_00202
mkpkg "$DEG_PATH/UKF/upload" UKF_00203 UKF_00203
mkpkg "$DEG_PATH/UKF/upload" UKF_00204 UKF_00205
run "$DEPLOY" deploy_case
check "cases from package folder stored"   '[[ -d $DATA_LAKE_PATH/Data/UKF/00200/UKF_00201 && -d $DATA_LAKE_PATH/Data/UKF/00200/UKF_00202 ]]'
check "loose case file stored"             '[[ -d $DATA_LAKE_PATH/Data/UKF/00200/UKF_00203 ]]'
check "content mismatch stored but warned" '[[ -d $DATA_LAKE_PATH/Data/UKF/00200/UKF_00205 ]] && grep -q content_mismatch $T/deploy_case.log'
check "package folder emptied, kept"       '[[ -d $DEG_PATH/UKF/upload/UKF_2026-09-24_10 && -z "$(ls -A $DEG_PATH/UKF/upload/UKF_2026-09-24_10)" ]]'
check "one stored message per case"        '[[ $(msgs UKF upload_stored_UKF_0020) -eq 4 ]]'
rmdir "$DEG_PATH/UKF/upload/UKF_2026-09-24_10"

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

echo "# missing checksum: wait, reject after timeout; legacy fallback with REQUIRE_CHECKSUM=0"
mkpkg "$DEG_PATH/UKF/upload" UKF_00301 UKF_00301; rm "$DEG_PATH/UKF/upload/UKF_00301.tar.zst.sha256"
age '5 minutes ago' "$DEG_PATH/UKF/upload/UKF_00301.tar.zst"
run "$DEPLOY" deploy_nochk1
check "stable archive without checksum waits" '[[ -f $DEG_PATH/UKF/upload/UKF_00301.tar.zst && ! -d $DATA_LAKE_PATH/Data/UKF/00300/UKF_00301 ]]'
age '2 hours ago' "$DEG_PATH/UKF/upload/UKF_00301.tar.zst"
run "$DEPLOY" deploy_nochk2
check "rejected after checksum timeout"    '[[ -f $DEG_PATH/UKF/upload/UKF_00301.tar.zst.rejected ]] && grep -q "No checksum file" $DEG_PATH/UKF/messages/*upload_rejected_UKF_00301*'
rm -f "$DEG_PATH/UKF/upload/UKF_00301.tar.zst.rejected"
mkpkg "$DEG_PATH/UKF/upload" UKF_00302 UKF_00302; rm "$DEG_PATH/UKF/upload/UKF_00302.tar.zst.sha256"
age '5 minutes ago' "$DEG_PATH/UKF/upload/UKF_00302.tar.zst"
REQUIRE_CHECKSUM=0 run "$DEPLOY" deploy_nochk3
check "legacy mode processes stable file" '[[ -d $DATA_LAKE_PATH/Data/UKF/00300/UKF_00302 ]]'

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
DL="$DEG_PATH/UKF/download/UKF_fetch_2026-09-24_00"
check "per-case packages + valid checksums" '(cd $DL && sha256sum -c --quiet UKK_00301.tar.zst.sha256 UKK_00150.tar.zst.sha256)'
check "case package contains case folder"  '[[ "$(tar -tf $DL/UKK_00301.tar.zst --use-compress-program=zstd | head -1)" == "UKK_00301/" ]]'
check "manifest lists both cases"          '[[ $(jq ".cases | length" $DL/manifest.json) -eq 2 ]]'
check "requests folder emptied"            '[[ -z "$(ls $DEG_PATH/UKF/requests)" ]]'
check "failed requests archived"           '[[ $(ls $DEG_PATH/UKF/archived-requests | grep -c FAILED) -eq 2 ]]'
check "two distinct error messages"        '[[ $(msgs UKF fetch_error) -eq 2 ]]'
check "ready message lists skipped id"     'jq -e ".skipped_ids == [\"UKK_00999\"] and .download_folder == \"download/UKF_fetch_2026-09-24_00\"" $DEG_PATH/UKF/messages/*fetch_ready* >/dev/null'
run "$FETCH" fetch2
check "second cycle writes no new errors"  '[[ $(msgs UKF fetch_error) -eq 2 ]]'

echo "# size limits and DEG space"
echo '{"organization":"UKF","requested_ids":["UKK_00301","UKK_00150"]}' > "$DEG_PATH/UKF/requests/request_2026-09-24_03.json"
FETCH_MAX_CASE_SIZE=10K run "$FETCH" fetch_case_limit
check "all cases too large -> error"       'grep -q "exceed the per-case limit" $DEG_PATH/UKF/messages/*fetch_error_request_2026-09-24_03*'
echo '{"organization":"UKF","requested_ids":["UKK_00301","UKK_00150"]}' > "$DEG_PATH/UKF/requests/request_2026-09-24_04.json"
FETCH_MAX_SIZE=30K run "$FETCH" fetch_total_limit
check "total too large -> error"           'grep -q "Request too large" $DEG_PATH/UKF/messages/*fetch_error_request_2026-09-24_04*'
echo '{"organization":"UKF","requested_ids":["UKK_00301","UKK_00150"]}' > "$DEG_PATH/UKF/requests/request_2026-09-24_05.json"
DEG_CAPACITY_BYTES=100K DEG_SPACE_MARGIN=1K run "$FETCH" fetch_deg_full
check "DEG full -> error, nothing built"   'grep -q "Not enough space on the DEG" $DEG_PATH/UKF/messages/*fetch_error_request_2026-09-24_05* && [[ ! -d $DEG_PATH/UKF/download/UKF_fetch_2026-09-24_05 ]]'
echo '{"organization":"UKF","requested_ids":["UKK_00301","UKK_00150"]}' > "$DEG_PATH/UKF/requests/request_2026-09-24_06.json"
DEG_CAPACITY_BYTES=100M DEG_SPACE_MARGIN=1K run "$FETCH" fetch_deg_ok
check "capacity mode with room -> ready"   '[[ -f $DEG_PATH/UKF/download/UKF_fetch_2026-09-24_06/manifest.json ]]'

echo "# DEG cleanup"
age '50 hours ago' "$DEG_PATH/UKF/download/UKF_fetch_2026-09-24_00"/* "$DEG_PATH/UKF/upload/badname.tar.zst.rejected"
mkdir -p "$DEG_PATH/UKF/upload/UKF_2026-09-24_99"; age '2 hours ago' "$DEG_PATH/UKF/upload/UKF_2026-09-24_99"
echo keep > "$DEG_PATH/UKF/upload/fresh.tar.zst"
DEG_REQUIRE_MOUNTPOINT=1 "$CLEANUP" --force > "$T/cleanup_refused.log" 2>&1; rc=$?
check "cleanup refuses non-mountpoint"     '[[ $rc -ne 0 && -f $DEG_PATH/UKF/download/UKF_fetch_2026-09-24_00/manifest.json ]]'
"$CLEANUP" --dry-run > "$T/cleanup_dry.log" 2>&1
check "dry-run removes nothing"            '[[ -f $DEG_PATH/UKF/download/UKF_fetch_2026-09-24_00/manifest.json ]] && grep -q "would remove" $T/cleanup_dry.log'
"$CLEANUP" --force > "$T/cleanup.log" 2>&1
check "old download folder removed"        '[[ ! -e $DEG_PATH/UKF/download/UKF_fetch_2026-09-24_00 ]]'
check "recent download folder kept"        '[[ -f $DEG_PATH/UKF/download/UKF_fetch_2026-09-24_06/manifest.json ]]'
check "old rejected upload removed"        '[[ ! -e $DEG_PATH/UKF/upload/badname.tar.zst.rejected ]]'
check "fresh upload kept"                  '[[ -f $DEG_PATH/UKF/upload/fresh.tar.zst ]]'
check "empty old package folder removed"   '[[ ! -e $DEG_PATH/UKF/upload/UKF_2026-09-24_99 ]]'
check "expired messages written"           '[[ $(msgs UKF fetch_expired) -eq 1 && $(msgs UKF upload_expired) -eq 1 ]]'
"$CLEANUP" > "$T/cleanup_throttled.log" 2>&1
check "second run throttled"               '! grep -q "cleanup started" $T/cleanup_throttled.log'
rm -f "$DEG_PATH/UKF/upload/fresh.tar.zst"

echo "# data index"
IDX="$DATA_LAKE_PATH/index/index.json"
check "index on data lake"                 '[[ $(jq ".case_count" $IDX) -eq 11 ]] && jq -e ".cases[] | select(.id==\"UKF_00042\") | .size_bytes > 0 and .file_count == 1 and .source == \"deg\"" $IDX >/dev/null'
check "index published to every org"       '[[ -f $DEG_PATH/UKF/index.json && -f $DEG_PATH/UKK/index.json && -f $DEG_PATH/UKF/index.csv ]] && [[ $(wc -l < $DEG_PATH/UKF/index.csv) -eq 12 ]]'
added=$(jq -r '.cases[] | select(.id=="UKF_00042") | .added_at' $IDX)
mkdir -p "$DATA_LAKE_PATH/Data/UKK/00500/UKK_00501" && echo x > "$DATA_LAKE_PATH/Data/UKK/00500/UKK_00501/f"
"$REBUILD" > "$T/rebuild.log" 2>&1
check "rebuild finds injected case"        '[[ $(jq ".case_count" $IDX) -eq 12 ]] && jq -e ".cases[] | select(.id==\"UKK_00501\") | .source == \"unknown\"" $IDX >/dev/null'
check "rebuild keeps added_at"             '[[ "$(jq -r ".cases[] | select(.id==\"UKF_00042\") | .added_at" $IDX)" == "$added" ]]'
check "rebuild republished"                '[[ $(jq ".case_count" $DEG_PATH/UKK/index.json) -eq 12 ]]'

echo "# staging"
check "staging clean after cycles"         '[[ -z "$(find $LOCAL_STAGING_PATH/deploy $LOCAL_STAGING_PATH/fetch -type f)" ]]'

echo
if [[ $FAIL -eq 0 ]]; then echo "ALL CHECKS PASSED ($T)"; else echo "$FAIL CHECK(S) FAILED ($T)"; fi
exit $FAIL
