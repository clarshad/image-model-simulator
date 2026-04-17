# Image Model Simulator

A lightweight Go server that mimics vLLM model pods for testing the Turiyam orchestrator. Serves one model per process, simulates realistic inference latency (4-8s by default), and exposes an admin API for runtime failure injection. Used to verify orchestrator behavior under conditions that are hard to reproduce with real GPU pods — circuit breaker trips, retries, FCFS global wait queue, multi-pod failover, queue saturation, rolling recovery.

## Contents

- [Quick start](#quick-start)
- [Deploy to Kubernetes](#deploy-to-kubernetes)
- [Scripts](#scripts)
- [Testing matrix](#testing-matrix) — all presets, scenarios, and FCFS burst
- [Configuration](#configuration)
- [API reference](#api-reference)
- [Project structure](#project-structure)

---

## Quick start

### Run locally

```bash
go build -o simulator ./cmd/simulator
./simulator \
  --model "Qwen-Image-Edit-2511-Multiple-Images" \
  --port 8000 --admin-port 9000 \
  --min-latency-ms 4000 --max-latency-ms 8000 \
  --startup-delay-s 10
```

### Run with Docker

```bash
docker build -t ini8labs/image-model-simulator:latest .

docker run -p 8000:8000 -p 9000:9000 \
  -e MODEL_NAME="Qwen-Image-Edit-2511-Multiple-Images" \
  -e MIN_LATENCY_MS=4000 -e MAX_LATENCY_MS=8000 \
  ini8labs/image-model-simulator:latest
```

### Run multiple instances (different models)

```bash
PORT=8000 ADMIN_PORT=9000 MODEL_NAME=Flux-Dev      ./simulator &
PORT=8001 ADMIN_PORT=9001 MODEL_NAME=SDXL-Turbo    ./simulator &
PORT=8002 ADMIN_PORT=9002 MODEL_NAME=Kandinsky-3   ./simulator &
```

Point the orchestrator at them via static discovery:

```bash
./orchestrator \
  --service-discovery static \
  --static-backends "http://localhost:8000,http://localhost:8001,http://localhost:8002" \
  --static-models "Flux-Dev,SDXL-Turbo,Kandinsky-3"
```

---

## Deploy to Kubernetes

Each pod serves exactly **one** model. To stand up many models at once, declare them in [deploy/k8s/models.txt](deploy/k8s/models.txt) and run the generator — it produces one Deployment per model in [deploy/k8s/generated/all-models.yaml](deploy/k8s/generated/). All pods carry `foundry.workload: vllm` so the orchestrator's k8s discovery picks them up, and each pod's `/v1/models` endpoint advertises its single configured model.

### 1. Edit the model catalog

`deploy/k8s/models.txt` is whitespace-delimited:

```
# <model-name>  [replicas]  [min_latency_ms]  [max_latency_ms]  [startup_delay_s]
Qwen-Image-Edit-2511-Multiple-Images   5  4000  8000  10
Qwen-Image-Gen-2511                    3  3000  6000  10
Flux-Schnell                           5  1500  3000  10
SDXL-Turbo                             6  1000  2500  10
```

Only the model name is required. Defaults: `replicas=3`, `min=4000`, `max=8000`, `startup=10`. Comment lines (`#`) and blank lines are ignored.

### 2. Build and push the image

```bash
# Build and push a linux/amd64 image to Docker Hub
docker buildx build --platform linux/amd64 \
  -t ini8labs/image-model-simulator:latest --push .
```

### 3. Generate and apply manifests

```bash
./scripts/generate-manifests.sh
kubectl apply -f deploy/k8s/generated/all-models.yaml

# Verify
kubectl get deploy -n foundry-simulator -l foundry.simulator=true
kubectl get pods  -n foundry-simulator -l foundry.simulator=true
```

Each Deployment is named `sim-<slugified-model-name>` and tagged with `foundry.simulator=true` and `foundry.model=<original-name>`:

```bash
# Scale a single model
kubectl scale deploy/sim-flux-schnell -n foundry-simulator --replicas=10

# Tear down everything
kubectl delete -f deploy/k8s/generated/all-models.yaml
```

### Point the orchestrator at the simulator namespace

If the cluster also has real model pods in the `foundry` namespace, pass `--k8s-namespace=foundry-simulator` to the orchestrator so it only discovers simulator pods:

```yaml
# orchestrator deployment args
- --service-discovery=k8s
- --k8s-selector=foundry.workload=vllm
- --k8s-port=8000
- --k8s-namespace=foundry-simulator
```

### Generator overrides

| Env var | Default | Purpose |
|---|---|---|
| `MODELS_FILE` | `deploy/k8s/models.txt` | Source catalog |
| `OUTPUT_DIR` | `deploy/k8s/generated` | Output directory |
| `NAMESPACE` | `foundry-simulator` | Target namespace |
| `IMAGE` | `ini8labs/image-model-simulator:latest` | Container image |
| `IMAGE_PULL_POLICY` | `Always` | Pull policy (Always recommended for the mutable `:latest` tag) |

---

## Scripts

All live under [`scripts/`](scripts/). Every script assumes `KUBECONFIG` is set (override via the `KUBECONFIG` env var; the injection scripts default to `~/projects/turiyam_ai/turiyam-kubeconfig`).

| Script | Purpose |
|---|---|
| [generate-manifests.sh](scripts/generate-manifests.sh) | Reads `deploy/k8s/models.txt`, emits one Deployment per model into `deploy/k8s/generated/all-models.yaml`. |
| [inject-failure.sh](scripts/inject-failure.sh) | Apply failure presets / JSON config / named scenarios to simulator pods via their admin API. Supports targeting all pods, one model, or a single pod. |
| [load-test.sh](scripts/load-test.sh) | Continuous multi-model load against the orchestrator ingress. Sequential + parallel bursts across all 10 models; stop with `Ctrl+C`. |
| [fcfs-burst.sh](scripts/fcfs-burst.sh) | Fires N concurrent requests at one model to exercise the orchestrator's FCFS global wait queue. Prints per-request status, p50/p95 latency, and an FCFS-order score. Pair with `inject-failure.sh scenario fcfs-queue`. |

### inject-failure.sh — targeting

| Flag | Scope |
|---|---|
| (none) | All simulator pods across all models |
| `--model <name>` | Only pods serving this model (matches label `foundry.model=<name>`) |
| `--pod <name>` | Only this specific pod |

---

## Testing matrix

All tests assume the simulators are deployed and the orchestrator is pointed at `foundry-simulator`. Start a baseline with `./scripts/inject-failure.sh reset` to make sure every pod is healthy before running a scenario.

### Failure presets

Use `./scripts/inject-failure.sh preset <name> [--model M | --pod P]`.

| Preset | Injection | What it's for |
|---|---|---|
| `healthy` | No failures (defaults) | Baseline |
| `flaky` | 30% chance of 500 errors | Verify orchestrator retries on a different worker |
| `degraded` | 50% chance of +10s extra latency | Timeout handling and queue pressure |
| `down` | `/health` returns 503 + 100% errors | Pod marked unhealthy; circuit breaker opens |
| `intermittent-drops` | 20% connection drops mid-response | Proxy-level error handling + retry |
| `overloaded` | 80% slow (+20s) + 10% 503 | Combined queue + retry + circuit-breaker pressure |
| `circuit-breaker-trip` | 100% 500 errors | Fast-path trip — 5 consecutive failures opens circuit |
| `slow` | 100% slow with `?ms=<duration>` (default 15000) | Deterministic slowness, no errors — ideal for FCFS queue saturation |

Custom config for fine-grained control:

```bash
./scripts/inject-failure.sh config \
  '{"error_rate":0.5,"error_code":502,"slow_rate":0.3,"slow_extra_ms":5000}' \
  --model Flux-Dev
```

### Named scenarios

Each scenario wraps a preset with orchestrator-specific context, prints what to expect, and points at the relevant log signals. All require `--model <M>`.

```bash
./scripts/inject-failure.sh scenario <name> --model <M>
```

| Scenario | What it tests | Orchestrator behavior to verify |
|---|---|---|
| `circuit-breaker-trip` | Trip CB on one model, then recover it | 5 consecutive failures → `unhealthy_workers:{model}`; after `CB_RECOVERY_INTERVAL` (30s) → `worker transitioned to half-open`; 3 probe successes → `circuit breaker closed, worker recovered` |
| `retry-logic` | 30% flaky errors across all pods of a model | Logs: `backend returned server error, retrying` → `retrying request attempt=1/2`. Most requests still 200 thanks to retries on different workers. |
| `queue-saturation` | All workers slow (+30s) | Logs: `queue_wait_ms` rises; overflow requests hit `WORKER_QUEUE_TIMEOUT` (60s) and return 503 |
| `multi-pod-failover` | One pod down, rest healthy | CB opens on the downed pod; remaining pods keep serving 200s |
| `overload` | 80% slow + 10% 503 | Mix of retries, slow responses, and queue pressure — exercises all three paths together |
| `rolling-recovery` | All pods down, then brought back one at a time | Health checker probes every 10s, re-registers recovered pods one by one |
| `fcfs-queue` | Deterministic slow on all pods; burst more requests than pods | See the FCFS section below |

Always clean up with `./scripts/inject-failure.sh reset` (or `reset --model M`) when done.

### FCFS global wait queue

The `fcfs-queue` scenario verifies the orchestrator's cross-instance FCFS queue. The flow:

1. All workers for the model are pinned slow (so they stay busy).
2. A burst of concurrent requests arrives — the first N (pod count) take the fast path via `SPOP free_workers:{model}`; the rest `ZADD` to `wait_queue:{model}` and park on a Go channel.
3. As workers release (on any orchestrator replica), the Lua release script `ZPOPMIN`s the oldest waiter globally and publishes to `notify:{orchestrator-id}`. The owning replica's subscriber wakes the parked request.
4. Excess requests beyond `capacity × queue_timeout / inference_latency` get 503 at `WORKER_QUEUE_TIMEOUT` (60s default).

**Run it:**

```bash
# Terminal 1 — pin all pods of the target model to 15s inference
./scripts/inject-failure.sh scenario fcfs-queue --model Flux-Dev

# Terminal 2 — fire 9 concurrent requests (3 pods × 3 = forces 2 batches of queueing)
./scripts/fcfs-burst.sh Flux-Dev 9 90

# Terminal 3 — watch the orchestrator dequeue
kubectl logs -n turiyam -l app.kubernetes.io/name=turiyam-orchestrator \
  --tail=200 -f | grep -i "queue\|waiter\|acquired"
```

**What success looks like:**

Client-side (`fcfs-burst.sh` output):
- First N requests: `status=200`, low `time_total` (≈ inference latency)
- Next batches: `status=200`, longer `time_total` (waited in queue)
- Excess beyond capacity: `status=503` at ≈60s, or client-side timeout if `max-wait` is shorter than queue-timeout

Server-side (orchestrator logs — authoritative, no network jitter):
```
"msg":"request dequeued, worker assigned","request_id":"fcfs-Flux-Dev-006-...","wait_ms":27149
"msg":"request completed","queue_wait_ms":27150,"inference_ms":12480,"total_ms":37439
```

Sorted by `queue_wait_ms`, the request order must be strictly non-decreasing — that's the FCFS guarantee. The burst script prints a ready-to-run `kubectl | jq | sort` one-liner at the end for this.

### Continuous multi-model load

Use `load-test.sh` for a steady-state soak that keeps all 10 models busy. Run it in the background while injecting failures to observe isolation (failing one model should not affect the others).

```bash
# Terminal 1 — continuous load (3 sequential + 4 parallel + 10 all-at-once per round)
./scripts/load-test.sh

# Terminal 2 — inject a fault on one model
./scripts/inject-failure.sh preset circuit-breaker-trip --model SDXL-Turbo

# Expect: SDXL-Turbo requests return 500 from the load test; other 9 models stay at 200.
# When done:
./scripts/inject-failure.sh reset --model SDXL-Turbo
```

### Startup / rolling restart

```bash
# Deployments set STARTUP_DELAY_S=10 by default — during startup the pod returns
# 503 on /health, simulating vLLM model loading. The orchestrator's discovery
# only registers a pod after its startup probe passes.
kubectl rollout restart deploy -n foundry-simulator -l foundry.simulator=true

# Watch the orchestrator discover/deregister pods:
kubectl logs -n turiyam -l app.kubernetes.io/name=turiyam-orchestrator -f \
  | grep -i "register\|deregister\|seeded"
```

### Stale worker cleanup after a config change

If you change the orchestrator's `--k8s-namespace` or `--k8s-selector`, any worker IDs registered by the previous instance stay in Redis even though the pod is no longer in scope. The orchestrator's discovery code now seeds its `known` map from Redis on first sync (see `GetAllWorkerIDs` in `internal/pool/pool.go`) so those stale workers are deregistered on the next sync cycle. To verify after a config change, check that only current-namespace pods show up in the orchestrator's free-worker sets.

---

## Configuration

All settings can be passed as CLI flags or environment variables.

| Flag | Env var | Default | Description |
|---|---|---|---|
| `--port` | `PORT` | `8000` | Model API port |
| `--admin-port` | `ADMIN_PORT` | `9000` | Admin API port |
| `--model` | `MODEL_NAME` | `Qwen-Image-Edit-2511-Multiple-Images` | Model name returned by `/v1/models` |
| `--min-latency-ms` | `MIN_LATENCY_MS` | `4000` | Minimum inference latency (ms) |
| `--max-latency-ms` | `MAX_LATENCY_MS` | `8000` | Maximum inference latency (ms) |
| `--startup-delay-s` | `STARTUP_DELAY_S` | `0` | Seconds before `/health` returns 200 (simulates model loading) |
| `--log-level` | `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |

---

## API reference

### Model API (port 8000)

Matches what the orchestrator expects from a real vLLM pod.

#### `GET /health`

- `200 {"status":"ok"}` — healthy
- `503 {"status":"loading"}` — during startup delay
- `503 {"status":"unhealthy"}` — when `health_down` is true via admin API

#### `GET /v1/models`

OpenAI-compatible listing; returns the single configured model.

```json
{
  "object": "list",
  "data": [
    {
      "id": "Qwen-Image-Edit-2511-Multiple-Images",
      "object": "model",
      "created": 1775742949,
      "owned_by": "turiyam"
    }
  ]
}
```

#### `POST /v1/images/edits`

```bash
curl -X POST http://localhost:8000/v1/images/edits \
  -F "model=Qwen-Image-Edit-2511-Multiple-Images" \
  -F "prompt=change to plain background" \
  -F "image[]=@test.jpg" \
  -F "response_format=b64_json"
```

Response (after simulated latency):

```json
{
  "created": 1775742950,
  "data": [
    { "b64_json": "<base64 64x64 PNG>", "revised_prompt": "change to plain background" }
  ]
}
```

### Admin API (port 9000)

Runtime control for failure injection. Does not affect routing on the model port.

#### `GET /admin/config`

Returns current failure configuration.

#### `PUT /admin/config` or `POST /admin/config`

Set custom failure parameters. Both methods accept the same JSON body — POST exists because BusyBox `wget` (inside the Alpine container) only supports `--post-data`.

```bash
curl -X POST http://localhost:9000/admin/config -d '{
  "error_rate": 0.3,
  "error_code": 500,
  "slow_rate": 0.5,
  "slow_extra_ms": 10000,
  "drop_rate": 0.1,
  "health_down": false,
  "timeout_rate": 0.0
}'
```

| Field | Type | Description |
|---|---|---|
| `error_rate` | float 0.0-1.0 | Probability of returning an error response |
| `error_code` | int | HTTP status code for errors (default 500) |
| `slow_rate` | float 0.0-1.0 | Probability of adding extra latency |
| `slow_extra_ms` | int | Extra milliseconds added on slow responses |
| `drop_rate` | float 0.0-1.0 | Probability of dropping connection mid-response |
| `health_down` | bool | Force `/health` to return 503 |
| `timeout_rate` | float 0.0-1.0 | Probability of hanging forever (until client timeout) |

#### `POST /admin/presets/{name}`

Apply a named preset (see the [failure presets table](#failure-presets)).

The `slow` preset accepts a duration query parameter:

```bash
curl -X POST "http://localhost:9000/admin/presets/slow?ms=8000"
```

#### `POST /admin/reset`

Reset all failure settings to defaults (fully healthy).

#### `GET /admin/metrics`

Returns request counters:

```json
{
  "total_requests": 42,
  "success_requests": 35,
  "error_requests": 5,
  "dropped_requests": 2,
  "timeout_requests": 0,
  "active_requests": 1,
  "health_checks": 120
}
```

---

## Project structure

```
image-model-simulator/
├── cmd/simulator/main.go              # Single-model server (model API + admin API)
├── deploy/k8s/
│   ├── models.txt                     # Model catalog — edit this to declare models
│   └── generated/                     # Generated manifests (gitignored)
│       └── all-models.yaml
├── scripts/
│   ├── generate-manifests.sh          # models.txt → one Deployment per model
│   ├── inject-failure.sh              # Admin-API control: presets, config, scenarios
│   ├── load-test.sh                   # Continuous multi-model load via orchestrator ingress
│   └── fcfs-burst.sh                  # N concurrent requests + FCFS-order analysis
├── Dockerfile
├── go.mod
└── README.md
```
