#!/bin/bash
# Beacon API performance test — runs on Linux (in-cluster ubuntu pod).
# BASE_URL defaults to dugtrio service; override via env to compare endpoints.
#
# Usage:
#   BASE_URL=http://dugtrio:8080 ./beacon-api-perf-test.sh
#   BASE_URL=http://l1-stack-hoodi-execution-beacon-fallback-0.l1-stack-hoodi-execution-beacon-fallback:5052 ./beacon-api-perf-test.sh
#   BASE_URL="$QUICKNODE_HOODI_BEACON_URL" ./beacon-api-perf-test.sh

BASE_URL="${BASE_URL:-http://dugtrio:8080}"
SCAN_SLOTS="${SCAN_SLOTS:-10}"
CALLS="${CALLS:-30}"

echo "Testing: $BASE_URL"

HEAD=$(curl -s "$BASE_URL/eth/v1/beacon/headers/head" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['header']['message']['slot'])")
echo "Head slot: $HEAD — scanning last $SCAN_SLOTS slots for most blobs..."

TMPDIR_SCAN=$(mktemp -d)

touch "$TMPDIR_SCAN/done.log"
for i in $(seq 1 $SCAN_SLOTS); do
    S=$((HEAD - i))
    (curl -s "$BASE_URL/eth/v1/beacon/blobs/$S" -o "$TMPDIR_SCAN/$S.json"; echo "$S" >> "$TMPDIR_SCAN/done.log") &
done

while [ "$(wc -l < "$TMPDIR_SCAN/done.log" 2>/dev/null || echo 0)" -lt "$SCAN_SLOTS" ]; do
    COMPLETED=$(wc -l < "$TMPDIR_SCAN/done.log" 2>/dev/null || echo 0)
    printf "\rScanned %d/%d slots..." "$COMPLETED" "$SCAN_SLOTS"
    sleep 0.5
done
printf "\rScanned %d/%d slots. Done.\n" "$SCAN_SLOTS" "$SCAN_SLOTS"
wait

BEST_SLOT=""
BEST_COUNT=0
for f in "$TMPDIR_SCAN"/*.json; do
    COUNT=$(python3 -c "import sys,json; d=json.load(open('$f')); print(len(d.get('data',[])))" 2>/dev/null || echo 0)
    S=$(basename "$f" .json)
    if [ "$COUNT" -gt "$BEST_COUNT" ]; then
        BEST_COUNT=$COUNT
        BEST_SLOT=$S
    fi
done

if [ "$BEST_COUNT" -eq 0 ]; then
    echo "No blobs found in last $SCAN_SLOTS slots, exiting." >&2
    rm -rf "$TMPDIR_SCAN"
    exit 1
fi

SLOT=$BEST_SLOT
echo "Using slot $SLOT (head=$HEAD, blobs=$BEST_COUNT)"
rm -rf "$TMPDIR_SCAN"

VHASH_FILE=$(mktemp)
curl -s "$BASE_URL/eth/v1/beacon/blob_sidecars/$SLOT" | python3 -c "
import json, hashlib, sys
d = json.load(sys.stdin)
items = d.get('data', [])
for b in items:
    commitment = bytes.fromhex(b['kzg_commitment'][2:])
    digest = hashlib.sha256(commitment).digest()
    versioned = b'\x01' + digest[1:]
    print('0x' + versioned.hex())
" > "$VHASH_FILE" 2>&1

echo "Extracted $(wc -l < "$VHASH_FILE" | tr -d ' ') versioned hashes"

VHASH1=$(sed -n '1p' "$VHASH_FILE")
VHASH2=$(sed -n '2p' "$VHASH_FILE")
rm -f "$VHASH_FILE"

stats() {
    local label="$1"; shift
    python3 -c "
import sys, math
label = sys.argv[1]
vals = list(map(int, sys.argv[2:]))
avg = sum(vals) / len(vals)
std = math.sqrt(sum((x - avg) ** 2 for x in vals) / len(vals))
print(f'avg: {avg:.0f} ms  stddev: {std:.0f} ms  [{label}]')
" "$label" "$@"
}

run_test() {
    local label="$1"
    local url="$2"
    local TIMES=()
    echo "$label"
    for i in $(seq 1 $CALLS); do
        START=$(date +%s%3N)
        BYTES=$(curl -s -o /dev/null -w "%{size_download}" "$url")
        END=$(date +%s%3N)
        ELAPSED=$((END - START))
        TIMES+=($ELAPSED)
        echo "Call #$i: ${BYTES} bytes, ${ELAPSED} ms"
    done
    stats "$label" "${TIMES[@]}"
}

URL="$BASE_URL/eth/v1/beacon/blobs/$SLOT"

run_test "GET /eth/v1/beacon/blobs/$SLOT" "$URL"
run_test "GET /eth/v1/beacon/blobs/$SLOT?versioned_hashes=$VHASH1" "$URL?versioned_hashes=$VHASH1"
run_test "GET /eth/v1/beacon/blobs/$SLOT?versioned_hashes=$VHASH1,$VHASH2" "$URL?versioned_hashes=$VHASH1,$VHASH2"
run_test "GET /eth/v1/beacon/blob_sidecars/$SLOT" "$BASE_URL/eth/v1/beacon/blob_sidecars/$SLOT"
