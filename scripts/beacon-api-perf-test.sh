#!/bin/bash
# Beacon API performance test — runs locally or in-cluster.
#
# Configure targets via env vars (empty = skip):
#   DUGTRIO_URL        default: http://dugtrio:8080
#   QUICKNODE_URL      default: (empty, skip unless set)
#   LOCAL_BEACON_URL   default: (empty, skip unless set)
#
# Port-forward commands for local testing:
#   kubectl port-forward pod/dugtrio-0 -n angkor-rpc-gateway 8080:8080
#   kubectl port-forward pod/l1-stack-hoodi-execution-beacon-fallback-0 -n angkor-rpc-gateway 5052:5052
#
# Example local run against all three:
#   DUGTRIO_URL=http://localhost:8080 \
#   LOCAL_BEACON_URL=http://localhost:5052 \
#   QUICKNODE_URL=https://... \
#   ./beacon-api-perf-test.sh

DUGTRIO_URL="${DUGTRIO_URL:-http://dugtrio:8080}"
QUICKNODE_URL="${QUICKNODE_URL:-}"
LOCAL_BEACON_URL="${LOCAL_BEACON_URL:-}"
SCAN_SLOTS="${SCAN_SLOTS:-10}"
CALLS="${CALLS:-30}"

# Build list of (label url) pairs for configured endpoints
TARGETS=()
[ -n "$DUGTRIO_URL" ]       && TARGETS+=("dugtrio" "$DUGTRIO_URL")
[ -n "$QUICKNODE_URL" ]     && TARGETS+=("quicknode" "$QUICKNODE_URL")
[ -n "$LOCAL_BEACON_URL" ]  && TARGETS+=("local-beacon" "$LOCAL_BEACON_URL")

if [ "${#TARGETS[@]}" -eq 0 ]; then
    echo "No endpoints configured, exiting." >&2
    exit 1
fi

# Use the first configured endpoint to discover the best slot
SCAN_URL="${TARGETS[1]}"
echo "Scanning for best slot via ${TARGETS[0]} ($SCAN_URL)..."

HEAD=$(curl -sL "$SCAN_URL/eth/v1/beacon/headers/head" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['header']['message']['slot'])")
echo "Head slot: $HEAD — scanning last $SCAN_SLOTS slots for most blobs..."

TMPDIR_SCAN=$(mktemp -d)
touch "$TMPDIR_SCAN/done.log"
for i in $(seq 1 $SCAN_SLOTS); do
    S=$((HEAD - i))
    (curl -sL "$SCAN_URL/eth/v1/beacon/blobs/$S" -o "$TMPDIR_SCAN/$S.json"; echo "$S" >> "$TMPDIR_SCAN/done.log") &
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

# Extract versioned hashes using the first endpoint
VHASH_FILE=$(mktemp)
curl -sL "$SCAN_URL/eth/v1/beacon/blob_sidecars/$SLOT" | python3 -c "
import json, hashlib, sys
d = json.load(sys.stdin)
items = d.get('data', [])
for b in items:
    commitment = bytes.fromhex(b['kzg_commitment'][2:])
    digest = hashlib.sha256(commitment).digest()
    versioned = b'\x01' + digest[1:]
    print('0x' + versioned.hex())
" > "$VHASH_FILE" 2>/dev/null

echo "Extracted $(wc -l < "$VHASH_FILE" | tr -d ' ') versioned hashes"

VHASH1=$(sed -n '1p' "$VHASH_FILE")
VHASH2=$(sed -n '2p' "$VHASH_FILE")
rm -f "$VHASH_FILE"

VHASH_VALID=false
if [[ "$VHASH1" =~ ^0x[0-9a-f]{64}$ ]]; then
    VHASH_VALID=true
else
    echo "Warning: versioned hash extraction failed, skipping versioned_hashes tests"
fi

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
        BYTES=$(curl -sL -o /dev/null -w "%{size_download}" "$url")
        END=$(date +%s%3N)
        ELAPSED=$((END - START))
        TIMES+=($ELAPSED)
        echo "Call #$i: ${BYTES} bytes, ${ELAPSED} ms"
    done
    stats "$label" "${TIMES[@]}"
}

# Run all tests for each configured endpoint
i=0
while [ $i -lt "${#TARGETS[@]}" ]; do
    LABEL="${TARGETS[$i]}"
    URL="${TARGETS[$((i+1))]}"
    i=$((i+2))

    echo ""
    echo "=== Testing: $LABEL ($URL) ==="
    run_test "[$LABEL] GET /eth/v1/beacon/blobs/$SLOT" "$URL/eth/v1/beacon/blobs/$SLOT"
    if [ "$VHASH_VALID" = true ]; then
        run_test "[$LABEL] GET /eth/v1/beacon/blobs/$SLOT?versioned_hashes=$VHASH1" "$URL/eth/v1/beacon/blobs/$SLOT?versioned_hashes=$VHASH1"
        run_test "[$LABEL] GET /eth/v1/beacon/blobs/$SLOT?versioned_hashes=$VHASH1,$VHASH2" "$URL/eth/v1/beacon/blobs/$SLOT?versioned_hashes=$VHASH1,$VHASH2"
    fi
    run_test "[$LABEL] GET /eth/v1/beacon/blob_sidecars/$SLOT" "$URL/eth/v1/beacon/blob_sidecars/$SLOT"
done
