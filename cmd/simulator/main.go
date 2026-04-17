package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"log/slog"
	"math/rand"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// FailureConfig controls runtime failure injection.
type FailureConfig struct {
	mu sync.RWMutex

	// ErrorRate is the probability [0.0, 1.0] of returning a 5xx error on inference.
	ErrorRate float64 `json:"error_rate"`

	// SlowRate is the probability [0.0, 1.0] of adding extra latency.
	SlowRate float64 `json:"slow_rate"`

	// SlowExtraMs is extra milliseconds added when slow mode triggers.
	SlowExtraMs int `json:"slow_extra_ms"`

	// DropRate is the probability [0.0, 1.0] of dropping the connection mid-response.
	DropRate float64 `json:"drop_rate"`

	// HealthDown forces /health to return 503.
	HealthDown bool `json:"health_down"`

	// ErrorCode is the HTTP status code returned on simulated errors (default 500).
	ErrorCode int `json:"error_code"`

	// TimeoutRate is the probability [0.0, 1.0] of never responding (hang until client timeout).
	TimeoutRate float64 `json:"timeout_rate"`
}

func (f *FailureConfig) Get() FailureConfig {
	f.mu.RLock()
	defer f.mu.RUnlock()
	return FailureConfig{
		ErrorRate:   f.ErrorRate,
		SlowRate:    f.SlowRate,
		SlowExtraMs: f.SlowExtraMs,
		DropRate:     f.DropRate,
		HealthDown:  f.HealthDown,
		ErrorCode:   f.ErrorCode,
		TimeoutRate: f.TimeoutRate,
	}
}

func (f *FailureConfig) Update(patch FailureConfig) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.ErrorRate = patch.ErrorRate
	f.SlowRate = patch.SlowRate
	f.SlowExtraMs = patch.SlowExtraMs
	f.DropRate = patch.DropRate
	f.HealthDown = patch.HealthDown
	f.ErrorCode = patch.ErrorCode
	f.TimeoutRate = patch.TimeoutRate
}

// Metrics tracks basic request counters.
type Metrics struct {
	TotalRequests    atomic.Int64
	SuccessRequests  atomic.Int64
	ErrorRequests    atomic.Int64
	DroppedRequests  atomic.Int64
	TimeoutRequests  atomic.Int64
	ActiveRequests   atomic.Int64
	HealthChecks     atomic.Int64
}

func main() {
	var (
		port              int
		adminPort         int
		modelName         string
		minLatency        int
		maxLatency        int
		startupDelay      int
		logLevel          string
		responseSizeKB    int
		responseJitterKB  int
	)

	flag.IntVar(&port, "port", envInt("PORT", 8000), "main server port")
	flag.IntVar(&adminPort, "admin-port", envInt("ADMIN_PORT", 9000), "admin API port")
	flag.StringVar(&modelName, "model", envStr("MODEL_NAME", "Qwen-Image-Edit-2511-Multiple-Images"), "served model name")
	flag.IntVar(&minLatency, "min-latency-ms", envInt("MIN_LATENCY_MS", 4000), "minimum inference latency (ms)")
	flag.IntVar(&maxLatency, "max-latency-ms", envInt("MAX_LATENCY_MS", 8000), "maximum inference latency (ms)")
	flag.IntVar(&startupDelay, "startup-delay-s", envInt("STARTUP_DELAY_S", 0), "seconds to wait before becoming healthy (simulates model loading)")
	flag.IntVar(&responseSizeKB, "response-size-kb", envInt("RESPONSE_SIZE_KB", 0), "size of the base64 image payload in each response (KB). 0 = tiny 64x64 PNG (default)")
	flag.IntVar(&responseJitterKB, "response-size-jitter-kb", envInt("RESPONSE_JITTER_KB", 0), "per-request size jitter (KB). actual size = response-size-kb + rand(0, response-size-jitter-kb)")
	flag.StringVar(&logLevel, "log-level", envStr("LOG_LEVEL", "info"), "log level: debug, info, warn, error")
	flag.Parse()

	// Setup structured logging.
	var level slog.Level
	switch strings.ToLower(logLevel) {
	case "debug":
		level = slog.LevelDebug
	case "warn":
		level = slog.LevelWarn
	case "error":
		level = slog.LevelError
	default:
		level = slog.LevelInfo
	}
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: level}))
	slog.SetDefault(logger)

	// Failure config (runtime-mutable via admin API).
	failures := &FailureConfig{ErrorCode: 500}
	metrics := &Metrics{}

	// Startup delay simulates model loading time.
	ready := make(chan struct{})
	if startupDelay > 0 {
		slog.Info("simulating model loading", "delay_seconds", startupDelay)
		go func() {
			time.Sleep(time.Duration(startupDelay) * time.Second)
			close(ready)
			slog.Info("model loaded, ready to serve")
		}()
	} else {
		close(ready)
	}

	// Pre-generate the base64 image payload once at startup.
	//
	// Defaults to a tiny 64x64 PNG (~300 bytes base64) — fast for functional tests.
	// With --response-size-kb set, we generate a pool of valid-base64 characters of
	// (size + jitter) KB up front and slice it per request. This lets us reproduce
	// the realistic response-body I/O load a real vLLM pod imposes on the
	// orchestrator's proxy (production generates ~4.4 MB base64 per image).
	var fakeImageB64 string
	var fakeImageBaseBytes int
	var fakeImageJitterBytes int
	if responseSizeKB <= 0 {
		fakeImageB64 = generateFakeImageB64()
	} else {
		fakeImageBaseBytes = responseSizeKB * 1024
		fakeImageJitterBytes = responseJitterKB * 1024
		fakeImageB64 = generateFakeBase64Blob(fakeImageBaseBytes + fakeImageJitterBytes)
		slog.Info("generated large response payload",
			"base_kb", responseSizeKB,
			"jitter_kb", responseJitterKB,
			"total_bytes", len(fakeImageB64),
		)
	}

	// --- Main server (model API, port 8000) ---
	mux := http.NewServeMux()

	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		metrics.HealthChecks.Add(1)

		// Not ready yet (startup delay).
		select {
		case <-ready:
		default:
			w.WriteHeader(http.StatusServiceUnavailable)
			fmt.Fprintf(w, `{"status":"loading"}`)
			return
		}

		cfg := failures.Get()
		if cfg.HealthDown {
			w.WriteHeader(http.StatusServiceUnavailable)
			fmt.Fprintf(w, `{"status":"unhealthy"}`)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"status":"ok"}`)
	})

	mux.HandleFunc("GET /v1/models", func(w http.ResponseWriter, r *http.Request) {
		// Not ready yet.
		select {
		case <-ready:
		default:
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		resp := map[string]interface{}{
			"object": "list",
			"data": []map[string]interface{}{
				{
					"id":       modelName,
					"object":   "model",
					"created":  time.Now().Unix(),
					"owned_by": "turiyam",
				},
			},
		}
		json.NewEncoder(w).Encode(resp)
	})

	mux.HandleFunc("POST /v1/images/edits", func(w http.ResponseWriter, r *http.Request) {
		reqID := r.Header.Get("X-Request-ID")
		if reqID == "" {
			reqID = fmt.Sprintf("sim-%d", time.Now().UnixNano())
		}

		metrics.TotalRequests.Add(1)
		metrics.ActiveRequests.Add(1)
		defer metrics.ActiveRequests.Add(-1)

		log := slog.With("request_id", reqID, "endpoint", r.URL.Path)

		// Not ready yet.
		select {
		case <-ready:
		default:
			w.WriteHeader(http.StatusServiceUnavailable)
			fmt.Fprintf(w, `{"error":{"message":"model still loading","type":"server_error"}}`)
			return
		}

		// Parse multipart to extract fields (for logging).
		var reqModel, prompt, responseFormat string
		if err := r.ParseMultipartForm(32 << 20); err != nil {
			log.Warn("failed to parse multipart form", "error", err)
		} else {
			reqModel = r.FormValue("model")
			prompt = r.FormValue("prompt")
			responseFormat = r.FormValue("response_format")
		}

		log.Info("inference request received",
			"model", reqModel,
			"prompt", prompt,
			"response_format", responseFormat,
			"content_length", r.ContentLength,
		)

		cfg := failures.Get()

		// Check timeout simulation (hang forever).
		if cfg.TimeoutRate > 0 && rand.Float64() < cfg.TimeoutRate {
			log.Warn("simulating timeout (hanging)")
			metrics.TimeoutRequests.Add(1)
			<-r.Context().Done()
			return
		}

		// Check connection drop simulation.
		if cfg.DropRate > 0 && rand.Float64() < cfg.DropRate {
			log.Warn("simulating connection drop")
			metrics.DroppedRequests.Add(1)
			// Hijack connection and close it abruptly.
			hj, ok := w.(http.Hijacker)
			if ok {
				conn, _, err := hj.Hijack()
				if err == nil {
					conn.Close()
				}
			}
			return
		}

		// Check error simulation.
		if cfg.ErrorRate > 0 && rand.Float64() < cfg.ErrorRate {
			code := cfg.ErrorCode
			if code == 0 {
				code = 500
			}
			log.Warn("simulating error response", "status", code)
			metrics.ErrorRequests.Add(1)
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(code)
			fmt.Fprintf(w, `{"error":{"message":"simulated error","type":"server_error","code":%d}}`, code)
			return
		}

		// Simulate inference latency.
		latency := minLatency + rand.Intn(maxLatency-minLatency+1)

		// Extra slow if triggered.
		if cfg.SlowRate > 0 && rand.Float64() < cfg.SlowRate {
			latency += cfg.SlowExtraMs
			log.Info("simulating slow response", "extra_ms", cfg.SlowExtraMs)
		}

		log.Info("simulating inference", "latency_ms", latency)

		select {
		case <-time.After(time.Duration(latency) * time.Millisecond):
		case <-r.Context().Done():
			log.Warn("client disconnected during inference")
			return
		}

		// Return OpenAI-compatible response.
		metrics.SuccessRequests.Add(1)

		// Select the per-request response payload. When size is not configured,
		// always return the tiny 64x64 PNG. Otherwise slice the pre-generated
		// pool to base + rand(0, jitter) bytes so each request varies a bit
		// (matches the natural size variance real image generators produce).
		b64 := fakeImageB64
		if fakeImageBaseBytes > 0 {
			size := fakeImageBaseBytes
			if fakeImageJitterBytes > 0 {
				size += rand.Intn(fakeImageJitterBytes + 1)
			}
			if size > len(fakeImageB64) {
				size = len(fakeImageB64)
			}
			b64 = fakeImageB64[:size]
		}

		resp := map[string]interface{}{
			"created": time.Now().Unix(),
			"data": []map[string]interface{}{
				{
					"b64_json":       b64,
					"revised_prompt": prompt,
				},
			},
		}

		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Request-ID", reqID)
		if err := json.NewEncoder(w).Encode(resp); err != nil {
			log.Error("failed to write response", "error", err)
		}

		log.Info("inference completed", "latency_ms", latency)
	})

	mainServer := &http.Server{
		Addr:    fmt.Sprintf(":%d", port),
		Handler: mux,
	}

	// --- Admin server (failure injection + metrics, port 9000) ---
	adminMux := http.NewServeMux()

	adminMux.HandleFunc("GET /admin/config", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(failures.Get())
	})

	// Both PUT and POST accept a JSON body. POST is registered because BusyBox
	// wget (used via kubectl exec) supports --post-data but not arbitrary methods.
	setConfig := func(w http.ResponseWriter, r *http.Request) {
		var patch FailureConfig
		if err := json.NewDecoder(r.Body).Decode(&patch); err != nil {
			http.Error(w, `{"error":"invalid JSON"}`, http.StatusBadRequest)
			return
		}
		failures.Update(patch)
		slog.Info("failure config updated",
			"error_rate", patch.ErrorRate,
			"slow_rate", patch.SlowRate,
			"drop_rate", patch.DropRate,
			"health_down", patch.HealthDown,
			"timeout_rate", patch.TimeoutRate,
		)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(failures.Get())
	}
	adminMux.HandleFunc("PUT /admin/config", setConfig)
	adminMux.HandleFunc("POST /admin/config", setConfig)

	adminMux.HandleFunc("POST /admin/reset", func(w http.ResponseWriter, r *http.Request) {
		failures.Update(FailureConfig{ErrorCode: 500})
		slog.Info("failure config reset to defaults")
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(failures.Get())
	})

	adminMux.HandleFunc("GET /admin/metrics", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{
			"total_requests":   metrics.TotalRequests.Load(),
			"success_requests": metrics.SuccessRequests.Load(),
			"error_requests":   metrics.ErrorRequests.Load(),
			"dropped_requests": metrics.DroppedRequests.Load(),
			"timeout_requests": metrics.TimeoutRequests.Load(),
			"active_requests":  metrics.ActiveRequests.Load(),
			"health_checks":    metrics.HealthChecks.Load(),
		})
	})

	// Preset failure scenarios for convenience.
	adminMux.HandleFunc("POST /admin/presets/{preset}", func(w http.ResponseWriter, r *http.Request) {
		preset := r.PathValue("preset")
		var cfg FailureConfig
		cfg.ErrorCode = 500

		switch preset {
		case "healthy":
			// All defaults (no failures).
		case "flaky":
			cfg.ErrorRate = 0.3
			cfg.ErrorCode = 500
		case "degraded":
			cfg.SlowRate = 0.5
			cfg.SlowExtraMs = 10000
		case "down":
			cfg.HealthDown = true
			cfg.ErrorRate = 1.0
			cfg.ErrorCode = 503
		case "intermittent-drops":
			cfg.DropRate = 0.2
		case "overloaded":
			cfg.SlowRate = 0.8
			cfg.SlowExtraMs = 20000
			cfg.ErrorRate = 0.1
			cfg.ErrorCode = 503
		case "circuit-breaker-trip":
			// High error rate to trip the circuit breaker (needs 5 consecutive failures).
			cfg.ErrorRate = 1.0
			cfg.ErrorCode = 500
		case "slow":
			// Deterministic 100% slow. Useful for FCFS queue tests — holds workers
			// busy for a known duration without injecting errors. Duration via ?ms=N.
			cfg.SlowRate = 1.0
			extraMs := 15000
			if v := r.URL.Query().Get("ms"); v != "" {
				if n, err := strconv.Atoi(v); err == nil && n > 0 {
					extraMs = n
				}
			}
			cfg.SlowExtraMs = extraMs
		default:
			http.Error(w, fmt.Sprintf(`{"error":"unknown preset: %s","available":["healthy","flaky","degraded","down","intermittent-drops","overloaded","circuit-breaker-trip","slow"]}`, preset), http.StatusBadRequest)
			return
		}

		failures.Update(cfg)
		slog.Info("preset applied", "preset", preset)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{
			"preset": preset,
			"config": failures.Get(),
		})
	})

	adminServer := &http.Server{
		Addr:    fmt.Sprintf(":%d", adminPort),
		Handler: adminMux,
	}

	// --- Start servers ---
	slog.Info("starting image model simulator",
		"model", modelName,
		"port", port,
		"admin_port", adminPort,
		"min_latency_ms", minLatency,
		"max_latency_ms", maxLatency,
		"startup_delay_s", startupDelay,
	)

	go func() {
		if err := mainServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("main server failed", "error", err)
			os.Exit(1)
		}
	}()

	go func() {
		if err := adminServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("admin server failed", "error", err)
			os.Exit(1)
		}
	}()

	// Wait for interrupt.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	sig := <-sigCh
	slog.Info("shutting down", "signal", sig)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	mainServer.Shutdown(ctx)
	adminServer.Shutdown(ctx)

	slog.Info("simulator stopped")
}

// generateFakeImageB64 creates a small 64x64 solid-color PNG and returns its base64 encoding.
func generateFakeImageB64() string {
	img := image.NewRGBA(image.Rect(0, 0, 64, 64))
	c := color.RGBA{R: 200, G: 200, B: 200, A: 255}
	for y := 0; y < 64; y++ {
		for x := 0; x < 64; x++ {
			img.Set(x, y, c)
		}
	}

	var buf strings.Builder
	encoder := base64.NewEncoder(base64.StdEncoding, &buf)
	png.Encode(encoder, img)
	encoder.Close()
	return buf.String()
}

// generateFakeBase64Blob returns a string of exactly n valid base64 characters.
// We write base64 characters directly (skipping the actual encode step) because
// this is consumed by the orchestrator's proxy purely for I/O load — there's
// no client that needs to decode it back into a real image.
func generateFakeBase64Blob(n int) string {
	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	buf := make([]byte, n)
	for i := range buf {
		buf[i] = alphabet[rand.Intn(len(alphabet))]
	}
	return string(buf)
}

func envStr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envInt(key string, fallback int) int {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	var n int
	if _, err := fmt.Sscanf(v, "%d", &n); err != nil {
		return fallback
	}
	return n
}

// Ensure net is used (for connection hijacking context).
var _ net.Conn
