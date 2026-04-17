#!/usr/bin/env bash
# Continuous load test against orchestrator via ingress.
# Sends a mix of sequential and parallel requests across all simulator models.
# Stop with Ctrl+C.

set -euo pipefail

API_KEY="sk-turiyam-609c4774285022039b35a778903c6dfa82d36d31f69a1b60"
BASE_URL="https://orchestrator.turiyam.dev"

MODELS=(
  "Flux-Schnell"
  "Flux-Dev"
  "SDXL-Turbo"
  "SDXL-Base-1.0"
  "Kandinsky-3"
  "Playground-v2.5"
  "Qwen-Image-Gen-2511"
  "Qwen-Image-Edit-2511-Single-Image"
  "Qwen-Image-Edit-2511-Multiple-Images"
  "Stable-Diffusion-3-Medium"
)

ROUND=0

req() {
  local model=$1 tag=$2
  local status elapsed
  elapsed=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" --max-time 30 \
    -X POST "${BASE_URL}/v1/images/edits" \
    -H "Authorization: Bearer ${API_KEY}" \
    -F "model=${model}" \
    -F "prompt=load test round ${ROUND}" \
    -F "response_format=b64_json")
  status=${elapsed%% *}
  local secs=${elapsed#* }
  local ms=$(printf '%.0f' "$(echo "${secs} * 1000" | bc)")
  printf "  [%s] %-35s %s  %5dms\n" "$tag" "$model" "$status" "$ms"
}

echo "Starting continuous load test against ${BASE_URL}"
echo "Models: ${MODELS[*]}"
echo "Press Ctrl+C to stop"
echo "---"

trap 'echo ""; echo "Stopped after ${ROUND} rounds."; exit 0' INT

while true; do
  ROUND=$((ROUND + 1))
  echo ""
  echo "=== Round ${ROUND} ==="

  # --- Sequential: one request per random model ---
  echo "[sequential]"
  for _ in 1 2 3; do
    model=${MODELS[$((RANDOM % ${#MODELS[@]}))]}
    req "$model" "seq"
  done

  # --- Parallel: burst 4 models at once ---
  echo "[parallel burst]"
  shuffled=($(printf '%s\n' "${MODELS[@]}" | sort -R | head -4))
  for model in "${shuffled[@]}"; do
    req "$model" "par" &
  done
  wait

  # --- Parallel: all models at once ---
  echo "[parallel all]"
  for model in "${MODELS[@]}"; do
    req "$model" "all" &
  done
  wait
done
