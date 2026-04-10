# Image Model Simulator

A lightweight Go server that mimics vLLM model pods for testing the Turiyam orchestrator. Simulates realistic inference latency (4-8s) and supports runtime failure injection to test circuit breakers, retries, queuing, and multi-pod routing.

## Quick Start

### Run Locally

```bash
# Build
go build -o simulator ./cmd/simulator

# Run with defaults (port 8000, 4-8s latency)
./simulator

# Run with custom settings
./simulator \
  --model "Qwen-Image-Edit-2511-Multiple-Images" \
  --port 8000 \
  --admin-port 9000 \
  --min-latency-ms 4000 \
  --max-latency-ms 8000 \
  --startup-delay-s 30
```

### Run with Docker

```bash
docker build -t image-model-simulator:latest .

docker run -p 8000:8000 -p 9000:9000 \
  -e MODEL_NAME="Qwen-Image-Edit-2511-Multiple-Images" \
  -e MIN_LATENCY_MS=4000 \
  -e MAX_LATENCY_MS=8000 \
  image-model-simulator:latest
```

### Run Multiple Instances Locally

```bash
# Terminal 1 — pod A
PORT=8000 ADMIN_PORT=9000 ./simulator

# Terminal 2 — pod B
PORT=8001 ADMIN_PORT=9001 ./simulator

# Terminal 3 — pod C (different model)
PORT=8002 ADMIN_PORT=9002 MODEL_NAME="Qwen-Image-Gen-2511" ./simulator
```

Then point the orchestrator at them using static discovery:

```bash
./orchestrator \
  --service-discovery static \
  --static-backends "http://localhost:8000,http://localhost:8001,http://localhost:8002" \
  --static-models "Qwen-Image-Edit-2511-Multiple-Images,Qwen-Image-Edit-2511-Multiple-Images,Qwen-Image-Gen-2511"
```

## Deploy to Kubernetes

Each pod serves exactly **one** model. To stand up many models at once, declare them in [deploy/k8s/models.txt](deploy/k8s/models.txt) and run the generator — it produces one Deployment per model in [deploy/k8s/generated/all-models.yaml](deploy/k8s/generated/). All pods carry the `foundry.workload: vllm` label so the orchestrator's k8s discovery picks them up automatically and learns each pod's model name from `/v1/models`.

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

### 2. Build and load the image

```bash
docker build -t image-model-simulator:latest .

# k3s example — import directly:
docker save image-model-simulator:latest | ssh <worker-node> sudo k3s ctr images import -
```

### 3. Generate and apply manifests

```bash
./scripts/generate-manifests.sh
kubectl apply -f deploy/k8s/generated/all-models.yaml

# Verify
kubectl get deploy -n foundry -l foundry.simulator=true
kubectl get pods  -n foundry -l foundry.simulator=true
```

The generator names each Deployment `sim-<slugified-model-name>` and tags it with `foundry.simulator=true` and `foundry.model=<original-name>` so you can target a single model later:

```bash
# Scale a single model
kubectl scale deploy/sim-flux-schnell --replicas=10 -n foundry

# Tear down everything
kubectl delete -f deploy/k8s/generated/all-models.yaml
```

### Generator overrides

Environment variables let you override generator defaults without editing the script:

| Var | Default | Purpose |
|---|---|---|
| `MODELS_FILE` | `deploy/k8s/models.txt` | Source catalog |
| `OUTPUT_DIR` | `deploy/k8s/generated` | Where manifests are written |
| `NAMESPACE` | `foundry` | Target namespace |
| `IMAGE` | `image-model-simulator:latest` | Container image |
| `IMAGE_PULL_POLICY` | `IfNotPresent` | Pull policy |

> **Note:** Before deploying simulators, scale down or delete any real model pods that share names, or use distinct names for the simulators to avoid conflicts.

## Configuration

All settings can be passed as CLI flags or environment variables.

| Flag | Env Var | Default | Description |
|---|---|---|---|
| `--port` | `PORT` | `8000` | Model API port |
| `--admin-port` | `ADMIN_PORT` | `9000` | Admin API port |
| `--model` | `MODEL_NAME` | `Qwen-Image-Edit-2511-Multiple-Images` | Model name returned by `/v1/models` |
| `--min-latency-ms` | `MIN_LATENCY_MS` | `4000` | Minimum inference latency (ms) |
| `--max-latency-ms` | `MAX_LATENCY_MS` | `8000` | Maximum inference latency (ms) |
| `--startup-delay-s` | `STARTUP_DELAY_S` | `0` | Seconds before becoming healthy (simulates model loading) |
| `--log-level` | `LOG_LEVEL` | `info` | Log level: debug, info, warn, error |

## API Reference

### Model API (port 8000)

These endpoints match what the orchestrator expects from a real vLLM model pod.

#### `GET /health`

Returns `200 {"status":"ok"}` when healthy.
Returns `503 {"status":"loading"}` during startup delay.
Returns `503 {"status":"unhealthy"}` when `health_down` is enabled via admin API.

#### `GET /v1/models`

OpenAI-compatible model listing. The orchestrator's k8s discovery calls this to learn which model a pod serves.

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

Accepts the same multipart form as the real model pod:

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
    {
      "b64_json": "<base64-encoded 64x64 PNG>",
      "revised_prompt": "change to plain background"
    }
  ]
}
```

### Admin API (port 9000)

Runtime control for failure injection. Does not affect the model API port's routing — only controls behavior of inference requests.

#### `GET /admin/config`

Returns current failure configuration.

#### `PUT /admin/config`

Set custom failure parameters:

```bash
curl -X PUT http://localhost:9000/admin/config -d '{
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
| `drop_rate` | float 0.0-1.0 | Probability of dropping connection mid-request |
| `health_down` | bool | Force `/health` to return 503 |
| `timeout_rate` | float 0.0-1.0 | Probability of hanging forever (until client timeout) |

#### `POST /admin/reset`

Reset all failure settings to defaults (fully healthy).

#### `POST /admin/presets/{name}`

Apply a named failure preset:

```bash
curl -X POST http://localhost:9000/admin/presets/flaky
```

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

## Failure Presets

| Preset | What it does | Use case |
|---|---|---|
| `healthy` | No failures | Baseline testing |
| `flaky` | 30% chance of 500 errors | Test retry logic |
| `degraded` | 50% chance of +10s extra latency | Test timeout handling and queue behavior |
| `down` | Health returns 503 + 100% errors | Test circuit breaker opening |
| `intermittent-drops` | 20% connection drops | Test proxy error handling and retries |
| `overloaded` | 80% slow + 10% 503s | Test queue depth limits and backpressure |
| `circuit-breaker-trip` | 100% 500 errors | Trip the circuit breaker (needs 5 consecutive failures) |

## Testing Scenarios

### 1. Circuit Breaker Trip and Recovery

```bash
# Start healthy, send some requests to establish baseline
curl -X POST http://localhost:9000/admin/presets/healthy

# Trip the circuit breaker (100% errors)
curl -X POST http://localhost:9000/admin/presets/circuit-breaker-trip

# Send 5+ requests through orchestrator to trigger circuit open
# Watch orchestrator logs for "circuit opened" messages

# Restore health — orchestrator will probe and recover in ~56s
curl -X POST http://localhost:9000/admin/presets/healthy
```

### 2. Multi-Pod Failover

```bash
# Run 3 pods, make one go down
# Pod A: healthy
# Pod B: apply "down" preset
# Pod C: healthy
# Orchestrator should route around Pod B after circuit opens
```

### 3. Queue Saturation

```bash
# Set high latency on all pods to fill the queue
curl -X PUT http://localhost:9000/admin/config -d '{
  "slow_rate": 1.0,
  "slow_extra_ms": 30000
}'

# Send concurrent requests — they should queue and eventually timeout (60s default)
```

### 4. Startup/Rolling Restart

```bash
# Deploy with STARTUP_DELAY_S=30
# Pods return 503 on /health for 30s, simulating model loading
# Orchestrator discovery should not register pods until they pass health checks
```

## Helper Script

The `scripts/inject-failure.sh` script automates failure injection across k8s pods:

```bash
# Apply preset to all simulator pods
./scripts/inject-failure.sh preset flaky

# Apply to a specific pod
./scripts/inject-failure.sh preset down <pod-name>

# Custom config
./scripts/inject-failure.sh config '{"error_rate":0.5,"error_code":502}'

# View status and metrics
./scripts/inject-failure.sh status
./scripts/inject-failure.sh metrics

# Reset everything
./scripts/inject-failure.sh reset
```

## Project Structure

```
image-model-simulator/
├── cmd/simulator/main.go              # Application entry point (single-model server)
├── deploy/k8s/
│   ├── models.txt                     # Model catalog — edit this to declare models
│   └── generated/                     # Generated manifests (gitignored)
│       └── all-models.yaml
├── scripts/
│   ├── generate-manifests.sh          # Reads models.txt, emits one Deployment per model
│   └── inject-failure.sh              # K8s failure injection helper
├── Dockerfile
├── go.mod
└── README.md
```
