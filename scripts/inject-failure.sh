#!/usr/bin/env bash
# Inject failure scenarios into simulator pods via their admin API.
#
# Targets pods by label in the foundry-simulator namespace. Supports targeting
# all simulator pods, a specific model's pods, or a single named pod.
#
# ────────────────────────────────────────────────────────────────────────
# BASIC COMMANDS
# ────────────────────────────────────────────────────────────────────────
#
#   # Apply a preset to ALL simulator pods:
#   ./inject-failure.sh preset flaky
#
#   # Apply a preset to one model's pods only:
#   ./inject-failure.sh preset down --model Flux-Dev
#
#   # Apply a preset to a single pod:
#   ./inject-failure.sh preset down --pod sim-flux-dev-764dbd78c5-crpcr
#
#   # Custom config (all pods or with --model / --pod):
#   ./inject-failure.sh config '{"error_rate":0.5,"error_code":502}'
#   ./inject-failure.sh config '{"slow_rate":1.0,"slow_extra_ms":30000}' --model SDXL-Turbo
#
#   # Status / metrics / reset:
#   ./inject-failure.sh status
#   ./inject-failure.sh status --model Flux-Dev
#   ./inject-failure.sh metrics
#   ./inject-failure.sh reset
#
# ────────────────────────────────────────────────────────────────────────
# ORCHESTRATOR TEST SCENARIOS
# ────────────────────────────────────────────────────────────────────────
#
#   ./inject-failure.sh scenario circuit-breaker-trip --model Flux-Dev
#   ./inject-failure.sh scenario retry-logic --model SDXL-Turbo
#   ./inject-failure.sh scenario queue-saturation --model Flux-Schnell
#   ./inject-failure.sh scenario multi-pod-failover --model Qwen-Image-Gen-2511
#   ./inject-failure.sh scenario overload --model Kandinsky-3
#   ./inject-failure.sh scenario rolling-recovery --model Flux-Dev
#
# ────────────────────────────────────────────────────────────────────────
# PRESETS: healthy, flaky, degraded, down, intermittent-drops, overloaded, circuit-breaker-trip
# ────────────────────────────────────────────────────────────────────────

set -euo pipefail

NAMESPACE="${NAMESPACE:-foundry-simulator}"
KUBECONFIG="${KUBECONFIG:-$HOME/projects/turiyam_ai/turiyam-kubeconfig}"
ADMIN_PORT=9000

export KUBECONFIG

# ── Colours ────────────────────────────────────────────────────────────
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'

# ── Argument parsing ──────────────────────────────────────────────────
# Splits positional args from --model / --pod flags.
parse_args() {
    POSITIONAL=()
    TARGET_MODEL=""
    TARGET_POD=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --model)  TARGET_MODEL="${2:?--model requires a value}"; shift 2 ;;
            --pod)    TARGET_POD="${2:?--pod requires a value}"; shift 2 ;;
            *)        POSITIONAL+=("$1"); shift ;;
        esac
    done
}

# ── Pod selection ─────────────────────────────────────────────────────
get_pods() {
    if [[ -n "$TARGET_POD" ]]; then
        echo "$TARGET_POD"
    elif [[ -n "$TARGET_MODEL" ]]; then
        kubectl get pods -n "$NAMESPACE" \
            -l "foundry.simulator=true,foundry.model=$TARGET_MODEL" \
            -o jsonpath='{.items[*].metadata.name}' --field-selector=status.phase=Running
    else
        kubectl get pods -n "$NAMESPACE" \
            -l foundry.simulator=true \
            -o jsonpath='{.items[*].metadata.name}' --field-selector=status.phase=Running
    fi
}

# ── Admin API helpers (use kubectl exec + wget, no port-forward) ──────
admin_get() {
    local pod="$1" path="$2"
    kubectl exec -n "$NAMESPACE" "$pod" -- \
        wget -qO- "http://localhost:$ADMIN_PORT$path" 2>/dev/null
}

admin_post() {
    local pod="$1" path="$2"
    kubectl exec -n "$NAMESPACE" "$pod" -- \
        wget -qO- --post-data="" "http://localhost:$ADMIN_PORT$path" 2>/dev/null
}

admin_put() {
    local pod="$1" path="$2" body="$3"
    kubectl exec -n "$NAMESPACE" "$pod" -- \
        wget -qO- --method=PUT --body-data="$body" "http://localhost:$ADMIN_PORT$path" 2>/dev/null
}

# ── Apply to pods (parallel where possible) ───────────────────────────
apply_preset() {
    local preset="$1"
    local pods
    pods=$(get_pods)
    if [[ -z "$pods" ]]; then
        echo -e "${RED}no pods found${NC}" >&2; return 1
    fi
    local scope="${TARGET_MODEL:-all models}"
    echo -e "${CYAN}applying preset '${preset}' to ${scope}${NC}"
    for pod in $pods; do
        local result
        result=$(admin_post "$pod" "/admin/presets/$preset" 2>&1) && \
            echo -e "  ${GREEN}✓${NC} $pod" || \
            echo -e "  ${RED}✗${NC} $pod: $result"
    done
}

apply_config() {
    local config="$1"
    local pods
    pods=$(get_pods)
    if [[ -z "$pods" ]]; then
        echo -e "${RED}no pods found${NC}" >&2; return 1
    fi
    local scope="${TARGET_MODEL:-all models}"
    echo -e "${CYAN}applying config to ${scope}${NC}"
    for pod in $pods; do
        local result
        result=$(admin_put "$pod" "/admin/config" "$config" 2>&1) && \
            echo -e "  ${GREEN}✓${NC} $pod" || \
            echo -e "  ${RED}✗${NC} $pod: $result"
    done
}

show_status() {
    local pods
    pods=$(get_pods)
    if [[ -z "$pods" ]]; then
        echo -e "${RED}no pods found${NC}" >&2; return 1
    fi
    for pod in $pods; do
        local model
        model=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.metadata.labels.foundry\.model}' 2>/dev/null)
        echo -e "${CYAN}── $pod (${model:-unknown}) ──${NC}"
        admin_get "$pod" "/admin/config" 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "(unreachable)"
    done
}

show_metrics() {
    local pods
    pods=$(get_pods)
    if [[ -z "$pods" ]]; then
        echo -e "${RED}no pods found${NC}" >&2; return 1
    fi
    for pod in $pods; do
        local model
        model=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.metadata.labels.foundry\.model}' 2>/dev/null)
        echo -e "${CYAN}── $pod (${model:-unknown}) ──${NC}"
        admin_get "$pod" "/admin/metrics" 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "(unreachable)"
    done
}

reset_all() {
    local pods
    pods=$(get_pods)
    if [[ -z "$pods" ]]; then
        echo -e "${RED}no pods found${NC}" >&2; return 1
    fi
    local scope="${TARGET_MODEL:-all models}"
    echo -e "${CYAN}resetting ${scope} to healthy${NC}"
    for pod in $pods; do
        local result
        result=$(admin_post "$pod" "/admin/reset" 2>&1) && \
            echo -e "  ${GREEN}✓${NC} $pod" || \
            echo -e "  ${RED}✗${NC} $pod: $result"
    done
}

# ── Orchestrator test scenarios ───────────────────────────────────────

scenario_circuit_breaker_trip() {
    local model="${TARGET_MODEL:?scenario requires --model}"
    local pods
    pods=$(get_pods)
    local pod_count
    pod_count=$(echo "$pods" | wc -w | tr -d ' ')

    cat <<MSG

${CYAN}━━━ SCENARIO: Circuit Breaker Trip & Recovery ━━━${NC}
${YELLOW}Model:${NC}  $model ($pod_count pods)

${YELLOW}What this tests:${NC}
  The orchestrator trips its circuit breaker after 5 consecutive 500 errors
  from a worker (CB_FAILURE_THRESHOLD=5). The worker moves to unhealthy_workers
  in Redis. After 30s (CB_RECOVERY_INTERVAL), the health checker probes the pod.
  On 3 consecutive probe successes (CB_SUCCESS_THRESHOLD=3), the worker recovers.

${YELLOW}Steps:${NC}
  1. Set all ${model} pods to 100% errors (circuit-breaker-trip preset)
  2. Send 6+ requests through orchestrator → observe circuit opens
  3. Wait, then reset pods to healthy → observe circuit recovers

MSG

    echo -e "${GREEN}[step 1]${NC} Setting all $model pods to 100% 500 errors..."
    apply_preset "circuit-breaker-trip"

    cat <<MSG

${GREEN}[step 2]${NC} Circuit breaker is now armed. Send requests through the orchestrator:

  for i in \$(seq 1 8); do
    curl -s -o /dev/null -w "req \$i: %{http_code}\\n" \\
      -X POST http://<orchestrator>/v1/images/edits \\
      -F "model=$model" -F "prompt=test" -F "image[]=@test.jpg"
  done

  Watch orchestrator logs for "circuit opened":
    kubectl logs -n turiyam -l app=turiyam-orchestrator --tail=50 | grep -i "circuit\|unhealthy\|failure"

${GREEN}[step 3]${NC} When ready to recover, run:
  ./scripts/inject-failure.sh preset healthy --model $model

  Then watch for probe success and recovery (~30-60s):
    kubectl logs -n turiyam -l app=turiyam-orchestrator --tail=50 | grep -i "probe\|recover\|half.open"

MSG
}

scenario_retry_logic() {
    local model="${TARGET_MODEL:?scenario requires --model}"
    local pods
    pods=$(get_pods)
    local pod_count
    pod_count=$(echo "$pods" | wc -w | tr -d ' ')

    cat <<MSG

${CYAN}━━━ SCENARIO: Retry Logic Verification ━━━${NC}
${YELLOW}Model:${NC}  $model ($pod_count pods)

${YELLOW}What this tests:${NC}
  The orchestrator retries up to 2 times (MAX_RETRIES=2) on a different worker
  when it gets a 5xx. With 30% error rate and multiple pods, most requests
  should succeed on retry even though individual attempts fail.

${YELLOW}Steps:${NC}
  1. Set all $model pods to 30% error rate (flaky preset)
  2. Send 20 requests → most should succeed (retried on different worker)

MSG

    echo -e "${GREEN}[step 1]${NC} Setting all $model pods to 30% 500 errors (flaky)..."
    apply_preset "flaky"

    cat <<MSG

${GREEN}[step 2]${NC} Send requests and observe retry behavior:

  for i in \$(seq 1 20); do
    curl -s -o /dev/null -w "req \$i: %{http_code}\\n" \\
      -X POST http://<orchestrator>/v1/images/edits \\
      -F "model=$model" -F "prompt=test" -F "image[]=@test.jpg"
  done

  Expected: most return 200 despite 30% per-pod error rate (retries save them).
  Watch orchestrator logs for "retrying on different worker":
    kubectl logs -n turiyam -l app=turiyam-orchestrator --tail=50 | grep -i "retry\|attempt"

  When done:
    ./scripts/inject-failure.sh reset --model $model

MSG
}

scenario_queue_saturation() {
    local model="${TARGET_MODEL:?scenario requires --model}"
    local pods
    pods=$(get_pods)
    local pod_count
    pod_count=$(echo "$pods" | wc -w | tr -d ' ')

    cat <<MSG

${CYAN}━━━ SCENARIO: Queue Saturation & Timeout ━━━${NC}
${YELLOW}Model:${NC}  $model ($pod_count pods)

${YELLOW}What this tests:${NC}
  With all workers stuck in 30s+ latency, the orchestrator's per-model queue
  fills up. New requests wait in the queue. After QUEUE_TIMEOUT (60s), queued
  requests get 503. This tests backpressure handling.

${YELLOW}Steps:${NC}
  1. Set all $model pods to 100% slow (30s extra latency)
  2. Send $((pod_count + 5)) concurrent requests → first batch occupies workers,
     overflow enters queue, some timeout with 503

MSG

    echo -e "${GREEN}[step 1]${NC} Setting all $model pods to 100% slow (+30s latency)..."
    apply_config '{"slow_rate":1.0,"slow_extra_ms":30000}'

    local overflow=$((pod_count + 5))
    cat <<MSG

${GREEN}[step 2]${NC} Send $overflow concurrent requests to saturate $pod_count workers:

  for i in \$(seq 1 $overflow); do
    curl -s -o /dev/null -w "req \$i: %{http_code}\\n" \\
      -X POST http://<orchestrator>/v1/images/edits \\
      -F "model=$model" -F "prompt=test" -F "image[]=@test.jpg" &
  done
  wait

  Expected: first $pod_count return 200 (slowly), rest queue then 503 on timeout.
  Watch: kubectl logs -n turiyam -l app=turiyam-orchestrator --tail=50 | grep -i "queue\|timeout\|503"

  When done:
    ./scripts/inject-failure.sh reset --model $model

MSG
}

scenario_multi_pod_failover() {
    local model="${TARGET_MODEL:?scenario requires --model}"
    local pods
    pods=$(get_pods)
    local pod_list=($pods)
    local pod_count=${#pod_list[@]}

    if [[ $pod_count -lt 2 ]]; then
        echo -e "${RED}error: model '$model' has only $pod_count pod(s), need at least 2 for failover test${NC}" >&2
        return 1
    fi

    local down_pod="${pod_list[0]}"
    local healthy_count=$((pod_count - 1))

    cat <<MSG

${CYAN}━━━ SCENARIO: Multi-Pod Failover ━━━${NC}
${YELLOW}Model:${NC}  $model ($pod_count pods)

${YELLOW}What this tests:${NC}
  One pod goes fully down (health=503 + 100% errors). The orchestrator's circuit
  breaker trips on that pod and routes traffic to the remaining $healthy_count healthy
  pods. Tests that the orchestrator routes around a failed worker.

${YELLOW}Steps:${NC}
  1. Mark one pod as down: $down_pod
  2. Leave the other $healthy_count pod(s) healthy
  3. Send requests → should succeed via healthy pods after circuit opens on the down pod

MSG

    echo -e "${GREEN}[step 1]${NC} Taking down pod: $down_pod"
    local saved_target_model="$TARGET_MODEL"
    local saved_target_pod="$TARGET_POD"
    TARGET_MODEL=""
    TARGET_POD="$down_pod"
    apply_preset "down"
    TARGET_MODEL="$saved_target_model"
    TARGET_POD="$saved_target_pod"

    cat <<MSG

${GREEN}[step 2]${NC} Pod $down_pod is now returning 503 on /health and 100% errors.
  The other $healthy_count pod(s) are still healthy.

  Send requests — first few may hit the downed pod and fail, then circuit opens
  and all traffic routes to healthy pods:

  for i in \$(seq 1 15); do
    curl -s -o /dev/null -w "req \$i: %{http_code}\\n" \\
      -X POST http://<orchestrator>/v1/images/edits \\
      -F "model=$model" -F "prompt=test" -F "image[]=@test.jpg"
  done

  Watch circuit breaker open:
    kubectl logs -n turiyam -l app=turiyam-orchestrator --tail=50 | grep -i "circuit\|failover\|unhealthy"

  When done:
    ./scripts/inject-failure.sh reset --model $model

MSG
}

scenario_overload() {
    local model="${TARGET_MODEL:?scenario requires --model}"
    local pods
    pods=$(get_pods)
    local pod_count
    pod_count=$(echo "$pods" | wc -w | tr -d ' ')

    cat <<MSG

${CYAN}━━━ SCENARIO: Overload (Slow + Errors) ━━━${NC}
${YELLOW}Model:${NC}  $model ($pod_count pods)

${YELLOW}What this tests:${NC}
  80% of requests get +20s extra latency, 10% get 503 errors. Combines
  queue pressure with intermittent failures. The orchestrator must balance
  retries, queue depth, and circuit breaker thresholds simultaneously.

MSG

    echo -e "${GREEN}[step 1]${NC} Applying overloaded preset to all $model pods..."
    apply_preset "overloaded"

    cat <<MSG

${GREEN}[step 2]${NC} Send a burst of concurrent requests:

  for i in \$(seq 1 $((pod_count * 3))); do
    curl -s -o /dev/null -w "req \$i: %{http_code}\\n" \\
      -X POST http://<orchestrator>/v1/images/edits \\
      -F "model=$model" -F "prompt=test" -F "image[]=@test.jpg" &
  done
  wait

  Watch: kubectl logs -n turiyam -l app=turiyam-orchestrator --tail=50 | grep -i "retry\|queue\|timeout\|circuit"

  When done:
    ./scripts/inject-failure.sh reset --model $model

MSG
}

scenario_rolling_recovery() {
    local model="${TARGET_MODEL:?scenario requires --model}"
    local pods
    pods=$(get_pods)
    local pod_list=($pods)
    local pod_count=${#pod_list[@]}

    if [[ $pod_count -lt 2 ]]; then
        echo -e "${RED}error: model '$model' has only $pod_count pod(s), need at least 2 for this test${NC}" >&2
        return 1
    fi

    cat <<MSG

${CYAN}━━━ SCENARIO: Rolling Recovery ━━━${NC}
${YELLOW}Model:${NC}  $model ($pod_count pods)

${YELLOW}What this tests:${NC}
  All pods go down, then recover one at a time. Validates the orchestrator's
  health checker (probes every 10s) detects recovered pods and adds them back
  to the free pool. Tests graceful ramp-up after a full outage.

${YELLOW}Steps:${NC}
  1. Take all $model pods down
  2. Wait, then recover them one by one with a gap between each

MSG

    echo -e "${GREEN}[step 1]${NC} Taking all $model pods down..."
    apply_preset "down"

    echo
    echo -e "${YELLOW}All $model pods are now down. Send a few requests to confirm 503s:${NC}"
    echo "  curl -s -o /dev/null -w '%{http_code}\\n' -X POST http://<orchestrator>/v1/images/edits -F 'model=$model' -F 'prompt=test' -F 'image[]=@test.jpg'"
    echo
    echo -e "${GREEN}[step 2]${NC} Recover pods one by one (run these manually with ~30s gap between):"
    echo

    for i in "${!pod_list[@]}"; do
        echo "  # Recover pod $((i+1))/$pod_count:"
        echo "  ./scripts/inject-failure.sh preset healthy --pod ${pod_list[$i]}"
        echo "  # Wait ~30s for orchestrator to probe and recover, then send traffic"
        echo
    done

    echo "  Watch recovery:"
    echo "    kubectl logs -n turiyam -l app=turiyam-orchestrator --tail=50 | grep -i 'probe\|recover\|half.open\|register'"
}

# ── Main dispatch ─────────────────────────────────────────────────────
parse_args "$@"
COMMAND="${POSITIONAL[0]:-help}"

case "$COMMAND" in
    preset)
        PRESET="${POSITIONAL[1]:?preset name required}"
        apply_preset "$PRESET"
        ;;
    config)
        CONFIG="${POSITIONAL[1]:?JSON config required}"
        apply_config "$CONFIG"
        ;;
    status)
        show_status
        ;;
    metrics)
        show_metrics
        ;;
    reset)
        reset_all
        ;;
    scenario)
        SCENARIO="${POSITIONAL[1]:?scenario name required}"
        case "$SCENARIO" in
            circuit-breaker-trip) scenario_circuit_breaker_trip ;;
            retry-logic)         scenario_retry_logic ;;
            queue-saturation)    scenario_queue_saturation ;;
            multi-pod-failover)  scenario_multi_pod_failover ;;
            overload)            scenario_overload ;;
            rolling-recovery)    scenario_rolling_recovery ;;
            *)
                echo -e "${RED}unknown scenario: $SCENARIO${NC}" >&2
                echo "Available scenarios:"
                echo "  circuit-breaker-trip  — trip and recover the circuit breaker (needs --model)"
                echo "  retry-logic           — verify retries on flaky pods (needs --model)"
                echo "  queue-saturation      — fill the queue with slow requests (needs --model)"
                echo "  multi-pod-failover    — one pod down, others route around it (needs --model)"
                echo "  overload              — slow + errors combined pressure (needs --model)"
                echo "  rolling-recovery      — full outage then pod-by-pod recovery (needs --model)"
                exit 1
                ;;
        esac
        ;;
    help|*)
        cat <<HELP
Usage: $0 <command> [args] [--model <name>] [--pod <name>]

Commands:
  preset <name>         Apply a failure preset
  config <json>         Apply custom failure config JSON
  status                Show current failure config per pod
  metrics               Show request counters per pod
  reset                 Reset all failure settings to defaults
  scenario <name>       Run an orchestrator test scenario (requires --model)

Presets:
  healthy               No failures (baseline)
  flaky                 30% chance of 500 errors
  degraded              50% chance of +10s extra latency
  down                  Health returns 503 + 100% errors
  intermittent-drops    20% connection drops
  overloaded            80% slow + 10% 503s
  circuit-breaker-trip  100% 500 errors

Scenarios:
  circuit-breaker-trip  Trip the circuit breaker, then recover
  retry-logic           Verify orchestrator retries on different workers
  queue-saturation      Fill the queue until requests timeout
  multi-pod-failover    Take one pod down, verify traffic routes around it
  overload              Combined slow + errors pressure test
  rolling-recovery      Full outage, then pod-by-pod recovery

Targeting:
  --model <name>        Target only pods serving this model (e.g., --model Flux-Dev)
  --pod <name>          Target a single pod by name

Examples:
  $0 preset flaky --model Flux-Dev
  $0 scenario circuit-breaker-trip --model SDXL-Turbo
  $0 metrics --model Qwen-Image-Gen-2511
  $0 reset
HELP
        ;;
esac
