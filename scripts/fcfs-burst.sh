#!/usr/bin/env bash
# Fire N concurrent requests at the orchestrator to exercise the FCFS wait queue.
#
# Use together with `./inject-failure.sh scenario fcfs-queue --model <M>`, which
# pins all pods serving <M> to high latency so workers stay busy and excess
# requests park in wait_queue:{model}.
#
# Each request is tagged with a sequence number in the prompt and a unique
# X-Request-ID header. We record arrival timestamp before firing, and
# completion timestamp on response. A summary reports success/503 counts,
# p50/p95 total latency, and an FCFS-order score.
#
# Usage:
#   ./scripts/fcfs-burst.sh <model> <concurrency> [max-wait-seconds]
#
# Example:
#   ./scripts/fcfs-burst.sh Flux-Dev 12 90
#
# Environment overrides:
#   API_KEY   — bearer token (defaults to the shared dev key)
#   BASE_URL  — orchestrator URL (default https://orchestrator.turiyam.dev)
#   ENDPOINT  — path under BASE_URL (default /v1/images/edits)

set -euo pipefail

MODEL="${1:?usage: $0 <model> <concurrency> [max-wait-seconds]}"
CONCURRENCY="${2:?usage: $0 <model> <concurrency> [max-wait-seconds]}"
MAX_WAIT="${3:-90}"

API_KEY="${API_KEY:-sk-turiyam-609c4774285022039b35a778903c6dfa82d36d31f69a1b60}"
BASE_URL="${BASE_URL:-https://orchestrator.turiyam.dev}"
ENDPOINT="${ENDPOINT:-/v1/images/edits}"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'

# Per-request output file; lines look like:
#   <seq> <req_id> <http_code> <time_total_seconds> <t_start_epoch> <t_end_epoch>
RESULTS=$(mktemp -t fcfs-burst-XXXXXX.tsv)
trap 'rm -f "$RESULTS"' EXIT

echo -e "${CYAN}━━━ FCFS burst: $CONCURRENCY concurrent requests to ${MODEL} ━━━${NC}"
echo    "  base:       $BASE_URL$ENDPOINT"
echo    "  max wait:   ${MAX_WAIT}s per request"
echo    "  results:    $RESULTS"
echo

START_EPOCH_MS=$(python3 -c 'import time; print(int(time.time()*1000))')

fire_one() {
    local seq="$1"
    local req_id
    req_id=$(printf 'fcfs-%s-%03d-%d' "$MODEL" "$seq" "$$")

    # Arrival timestamp (ms since burst start)
    local t_start_ms
    t_start_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
    local t_arrive_rel=$((t_start_ms - START_EPOCH_MS))

    # Use '|' as field separator so a malformed time_total can't bleed into
    # the http_code parsing. Capture curl's output and exit code separately.
    local code_time
    set +e
    code_time=$(curl -s -o /dev/null \
        -w '%{http_code}|%{time_total}' \
        --max-time "$MAX_WAIT" \
        -X POST "${BASE_URL}${ENDPOINT}" \
        -H "Authorization: Bearer ${API_KEY}" \
        -H "X-Request-ID: ${req_id}" \
        -F "model=${MODEL}" \
        -F "prompt=fcfs-burst seq=${seq}" \
        -F "response_format=b64_json" \
        2>/dev/null)
    local curl_exit=$?
    set -e
    if [[ -z "$code_time" || "$code_time" != *"|"* ]]; then
        code_time="000|0"
    fi

    local http_code="${code_time%%|*}"
    local time_total="${code_time##*|}"
    # Guard against non-numeric time_total (e.g., curl wrote nothing on hard failure).
    if ! [[ "$time_total" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        time_total="0"
    fi
    local t_end_ms
    t_end_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
    local t_done_rel=$((t_end_ms - START_EPOCH_MS))

    printf '%d\t%s\t%s\t%s\t%d\t%d\n' \
        "$seq" "$req_id" "$http_code" "$time_total" "$t_arrive_rel" "$t_done_rel" \
        >> "$RESULTS"

    # Colorize status for live output
    local colour
    case "$http_code" in
        200)      colour="$GREEN" ;;
        503|504)  colour="$YELLOW" ;;  # queue timeout — expected at overflow
        500|502)  colour="$RED" ;;
        *)        colour="$RED" ;;
    esac
    printf '  [%3d] %s %6sms → %s%s%s  req_id=%s\n' \
        "$seq" "arrived+${t_arrive_rel}ms" "$(printf '%.0f' "$(echo "$time_total * 1000" | bc)")" \
        "$colour" "$http_code" "$NC" "$req_id"
}

echo -e "${CYAN}firing…${NC}"
for seq in $(seq 1 "$CONCURRENCY"); do
    fire_one "$seq" &
done
wait

echo
echo -e "${CYAN}━━━ summary ━━━${NC}"

python3 - <<PY
import sys
from pathlib import Path

rows = []
for line in Path("$RESULTS").read_text().splitlines():
    if not line.strip():
        continue
    seq, req_id, code, time_total, t_arrive_rel, t_done_rel = line.split("\t")
    rows.append({
        "seq":        int(seq),
        "req_id":     req_id,
        "code":       int(code),
        "latency_ms": float(time_total) * 1000.0,
        "arrive_ms":  int(t_arrive_rel),
        "done_ms":    int(t_done_rel),
    })

if not rows:
    print("no results")
    sys.exit(1)

rows.sort(key=lambda r: r["arrive_ms"])
arrivals = [r["seq"] for r in rows]

rows_by_done = sorted(rows, key=lambda r: r["done_ms"])
completions = [r["seq"] for r in rows_by_done]

# FCFS score: Kendall tau-ish — count pairs (i, j) where arrivals[i] < arrivals[j]
# but completions put j before i. Lower disorder = more FCFS.
disorder = 0
total_pairs = 0
for i in range(len(rows)):
    for j in range(i + 1, len(rows)):
        a_i = rows[i]["arrive_ms"]; a_j = rows[j]["arrive_ms"]
        d_i = rows[i]["done_ms"];   d_j = rows[j]["done_ms"]
        if a_i == a_j:
            continue
        total_pairs += 1
        arrived_before = a_i < a_j
        done_before    = d_i < d_j
        if arrived_before != done_before:
            disorder += 1

fcfs_score = 100.0 * (1 - disorder / total_pairs) if total_pairs else 100.0

codes = {}
for r in rows:
    codes[r["code"]] = codes.get(r["code"], 0) + 1

def pct(p, values):
    if not values:
        return 0
    s = sorted(values)
    k = int(round((p/100.0) * (len(s)-1)))
    return s[k]

lat_success = [r["latency_ms"] for r in rows if r["code"] == 200]
wait_all    = [r["done_ms"] - r["arrive_ms"] for r in rows]

print(f"  total requests : {len(rows)}")
for c in sorted(codes):
    label = {200: "success", 503: "queue timeout", 504: "gateway timeout",
             500: "server error", 502: "bad gateway", 0: "curl failure"}.get(c, f"HTTP {c}")
    print(f"    {c} {label:20s}: {codes[c]}")

if lat_success:
    print(f"  success latency ms (curl time_total):")
    print(f"    p50 : {pct(50, lat_success):.0f}")
    print(f"    p95 : {pct(95, lat_success):.0f}")
    print(f"    max : {max(lat_success):.0f}")

print(f"  wall-clock wait ms (arrival → completion, all responses):")
print(f"    p50 : {pct(50, wait_all)}")
print(f"    p95 : {pct(95, wait_all)}")
print(f"    max : {max(wait_all)}")

print(f"  FCFS order score : {fcfs_score:.1f}%  "
      f"(100% = strict arrival order, {disorder}/{total_pairs} pairs out of order)")
print("  NOTE: FCFS score above uses client-side arrival timestamps which include")
print("  network jitter. For authoritative server-side ordering, inspect orchestrator")
print("  logs: look for 'queue_wait_ms' on completed requests. Lower queue_wait_ms")
print("  = earlier arrival. Strict FCFS = monotonically non-decreasing queue_wait_ms")
print("  when sorted by the order the queue dequeued them.")
print()
print("  arrival order  :", arrivals[:20], "..." if len(arrivals) > 20 else "")
print("  completion ord :", completions[:20], "..." if len(completions) > 20 else "")
PY

cat <<HINT

${CYAN}server-side FCFS verification${NC} — the orchestrator emits queue_wait_ms on
every completed request. Sorted by queue_wait_ms, the sequence should match the
true arrival order the ZSET saw (strictly monotonic = strict FCFS):

  kubectl logs -n turiyam -l app.kubernetes.io/name=turiyam-orchestrator \\
    --since=15m 2>&1 | grep 'fcfs-${MODEL}-' | grep 'request completed' \\
    | jq -r '.request_id + " queue_wait_ms=" + (.queue_wait_ms|tostring) + \\
             " inference_ms=" + (.inference_ms|tostring)' | sort -t= -k2 -n

HINT
