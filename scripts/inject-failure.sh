#!/usr/bin/env bash
# Inject failure scenarios into simulator pods via their admin API.
#
# Usage:
#   # Apply a preset to all simulator pods:
#   ./inject-failure.sh preset flaky
#   ./inject-failure.sh preset healthy
#
#   # Apply preset to a specific pod:
#   ./inject-failure.sh preset down image-model-simulator-abc123
#
#   # Custom config to all pods:
#   ./inject-failure.sh config '{"error_rate":0.5,"error_code":502}'
#
#   # Get current config from all pods:
#   ./inject-failure.sh status
#
#   # Get metrics from all pods:
#   ./inject-failure.sh metrics
#
#   # Reset all pods to healthy:
#   ./inject-failure.sh reset
#
# Available presets: healthy, flaky, degraded, down, intermittent-drops, overloaded, circuit-breaker-trip

set -euo pipefail

NAMESPACE="${NAMESPACE:-foundry}"
KUBECONFIG="${KUBECONFIG:-$HOME/projects/turiyam_ai/turiyam-kubeconfig}"
ADMIN_PORT=9000

export KUBECONFIG

get_pods() {
    local target_pod="${1:-}"
    if [[ -n "$target_pod" ]]; then
        echo "$target_pod"
    else
        # Selects all simulator pods regardless of which model they serve.
        # The foundry.simulator=true label is set by scripts/generate-manifests.sh.
        kubectl get pods -n "$NAMESPACE" -l foundry.simulator=true -o jsonpath='{.items[*].metadata.name}'
    fi
}

case "${1:-help}" in
    preset)
        PRESET="${2:?preset name required}"
        TARGET_POD="${3:-}"
        for pod in $(get_pods "$TARGET_POD"); do
            echo ">>> $pod: applying preset '$PRESET'"
            kubectl exec -n "$NAMESPACE" "$pod" -- wget -qO- --post-data="" "http://localhost:$ADMIN_PORT/admin/presets/$PRESET" 2>/dev/null || \
            kubectl port-forward -n "$NAMESPACE" "$pod" 19000:$ADMIN_PORT &
            PF_PID=$!
            sleep 1
            curl -s -X POST "http://localhost:19000/admin/presets/$PRESET" | python3 -m json.tool 2>/dev/null || true
            kill $PF_PID 2>/dev/null || true
            wait $PF_PID 2>/dev/null || true
        done
        ;;
    config)
        CONFIG="${2:?JSON config required}"
        TARGET_POD="${3:-}"
        for pod in $(get_pods "$TARGET_POD"); do
            echo ">>> $pod: applying config"
            kubectl port-forward -n "$NAMESPACE" "$pod" 19000:$ADMIN_PORT &
            PF_PID=$!
            sleep 1
            curl -s -X PUT -d "$CONFIG" "http://localhost:19000/admin/config" | python3 -m json.tool 2>/dev/null || true
            kill $PF_PID 2>/dev/null || true
            wait $PF_PID 2>/dev/null || true
        done
        ;;
    status)
        TARGET_POD="${2:-}"
        for pod in $(get_pods "$TARGET_POD"); do
            echo ">>> $pod:"
            kubectl port-forward -n "$NAMESPACE" "$pod" 19000:$ADMIN_PORT &
            PF_PID=$!
            sleep 1
            curl -s "http://localhost:19000/admin/config" | python3 -m json.tool 2>/dev/null || true
            kill $PF_PID 2>/dev/null || true
            wait $PF_PID 2>/dev/null || true
        done
        ;;
    metrics)
        TARGET_POD="${2:-}"
        for pod in $(get_pods "$TARGET_POD"); do
            echo ">>> $pod:"
            kubectl port-forward -n "$NAMESPACE" "$pod" 19000:$ADMIN_PORT &
            PF_PID=$!
            sleep 1
            curl -s "http://localhost:19000/admin/metrics" | python3 -m json.tool 2>/dev/null || true
            kill $PF_PID 2>/dev/null || true
            wait $PF_PID 2>/dev/null || true
        done
        ;;
    reset)
        TARGET_POD="${2:-}"
        for pod in $(get_pods "$TARGET_POD"); do
            echo ">>> $pod: resetting to healthy"
            kubectl port-forward -n "$NAMESPACE" "$pod" 19000:$ADMIN_PORT &
            PF_PID=$!
            sleep 1
            curl -s -X POST "http://localhost:19000/admin/reset" | python3 -m json.tool 2>/dev/null || true
            kill $PF_PID 2>/dev/null || true
            wait $PF_PID 2>/dev/null || true
        done
        ;;
    help|*)
        echo "Usage: $0 {preset|config|status|metrics|reset} [args...]"
        echo ""
        echo "Commands:"
        echo "  preset <name> [pod]    Apply a failure preset (healthy, flaky, degraded, down, intermittent-drops, overloaded, circuit-breaker-trip)"
        echo "  config <json> [pod]    Apply custom failure config JSON"
        echo "  status [pod]           Show current failure config"
        echo "  metrics [pod]          Show request metrics"
        echo "  reset [pod]            Reset to healthy defaults"
        ;;
esac
