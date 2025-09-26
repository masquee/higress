# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **Higress WASM plugin** written in Go that implements a Redis-based request counter. The plugin runs in Envoy proxy as a WebAssembly module, intercepts HTTP requests, increments a counter in Redis, and adds the count to the response headers.

**Key components:**
- `main.go`: Single-file plugin implementation using Higress wrapper APIs
- `envoy.yaml`: Envoy configuration with WASM filter setup
- `docker-compose.yaml`: Local test environment with Redis, httpbin, and Envoy

## Build Commands

### Build the WASM plugin
```bash
make build
```
This compiles `main.go` to `plugin.wasm` using:
- Target: `GOOS=wasip1 GOARCH=wasm`
- Build mode: `-buildmode=c-shared`
- Go proxy: `GOPROXY=https://goproxy.cn,direct`

**Important:** The output file MUST be named `plugin.wasm` (not `redis-rq-counter.wasm`) as referenced in `docker-compose.yaml`.

### Build and run test environment
```bash
make run
```
Builds the plugin and starts Docker Compose with Redis, httpbin, and Envoy.

### Clean up
```bash
make clean
```
Stops all Docker Compose services.

## Architecture

### Plugin Lifecycle

The plugin uses the Higress wrapper pattern initialized in `init()`:

```go
wrapper.SetCtx(
    "redis-rq-counter",
    wrapper.ParseConfig(parseConfig),
    wrapper.ProcessRequestHeaders(onHttpRequestHeaders),
    wrapper.ProcessResponseHeaders(onHttpResponseHeaders),
)
```

### Request Flow

1. **Configuration Phase** (`parseConfig`):
   - Parses JSON config from Envoy
   - Initializes Redis client with `wrapper.NewRedisClusterClient`
   - Extracts `counter_key` (defaults to "global")

2. **Request Phase** (`onHttpRequestHeaders`):
   - Calls `ctx.DisableReroute()` to prevent re-routing
   - Executes Redis INCR command asynchronously
   - Returns `HeaderStopAllIterationAndWatermark` to pause request processing
   - In callback: stores count in context via `ctx.SetContext()` and calls `proxywasm.ResumeHttpRequest()`

3. **Response Phase** (`onHttpResponseHeaders`):
   - Retrieves count from context via `ctx.GetContext()`
   - Adds `X-Request-Count` header with the count value

### Async Non-Blocking Pattern

**Critical implementation detail:** The plugin uses async callbacks to avoid blocking Envoy's worker threads:

```go
cfg.RedisClient.Incr(redisKey, func(response resp.Value) {
    currentCount := response.Integer()
    ctx.SetContext(CounterContextKey, currentCount)
    proxywasm.ResumeHttpRequest()
})
return types.HeaderStopAllIterationAndWatermark
```

- The function returns immediately with `HeaderStopAllIterationAndWatermark` to pause request processing
- Redis operation happens asynchronously
- Callback resumes request with `ResumeHttpRequest()`
- Data flows between phases via context (`SetContext`/`GetContext`)

### Redis Configuration

The plugin expects Envoy configuration in this format:

```json
{
  "redis": {
    "service_name": "redis",      // Must match Envoy cluster name
    "service_port": 6379,
    "username": "",                // Optional
    "password": "",                // Optional
    "timeout": 2000,               // Milliseconds, default 1000
    "database": 0                  // Redis DB number
  },
  "counter_key": "test-counter"   // Counter name, default "global"
}
```

**Important:** The `service_name` must match an Envoy cluster definition. In the test environment, it references the cluster named `redis` (not `redis.static` or `outbound|6379||redis`).

### Redis Key Format

Keys in Redis follow this pattern:
```
higress-redis-rq-counter:{counter_key}
```

Example: With `counter_key: "test-counter"`, the Redis key is `higress-redis-rq-counter:test-counter`.

## Testing

### Test the plugin locally
```bash
# Start environment
make run

# Send test requests
curl -i http://localhost:10000/get

# Check Redis counter
docker exec redis-server redis-cli GET higress-redis-rq-counter:test-counter

# View logs
docker-compose logs -f envoy
```

### Key ports
- **10000**: Envoy HTTP proxy (test requests here)
- **9901**: Envoy admin interface
- **6379**: Redis
- **8080**: httpbin (upstream service)

### Debugging

View WASM debug logs (enabled in docker-compose.yaml):
```bash
docker-compose logs envoy | grep -i "wasm\|redis-rq-counter"
docker-compose logs envoy | grep "current request count"
```

Check Envoy stats:
```bash
curl http://localhost:9901/stats | grep -E "redis|wasm"
curl http://localhost:9901/clusters | grep redis
```

## Configuration Changes

When modifying plugin behavior:

1. **Change counter name**: Edit `counter_key` in `envoy.yaml` configuration
2. **Change Redis connection**: Edit `redis` section in `envoy.yaml`
3. **Change response header name**: Modify `ResponseHeaderName` constant in `main.go`

After changes to `main.go`:
```bash
make build
docker-compose restart envoy
```

After changes to `envoy.yaml`:
```bash
docker-compose restart envoy
```

## Important Constraints

### WASM Environment Limitations

- **No filesystem access**: WASM runtime is sandboxed
- **No direct network calls**: All network operations go through Envoy host calls
- **Limited stdlib**: Not all Go stdlib works in WASM
- **No goroutines**: Concurrency is handled by Envoy's event loop

### Redis Client Notes

- Uses `wrapper.RedisClient` from Higress SDK, not standard Redis client
- All Redis calls are async with callbacks
- Client is initialized once during config parsing
- Connection pooling is managed by Envoy's cluster manager

### Envoy Cluster Naming

The Envoy cluster name in `envoy.yaml` must exactly match the `service_name` in plugin configuration. The test environment uses:
- Cluster name: `outbound|6379||redis` (actual cluster definition)
- Service name in config: `redis` (resolved by Higress wrapper to match cluster)

## Dependencies

Main dependencies (see go.mod):
- `github.com/higress-group/proxy-wasm-go-sdk`: Proxy-Wasm Go SDK for host call APIs
- `github.com/higress-group/wasm-go`: Higress wrapper utilities (Redis client, HTTP context, etc.)
- `github.com/tidwall/gjson`: JSON parsing for configuration
- `github.com/tidwall/resp`: RESP protocol parsing for Redis responses

**Note:** Dependencies are vendored for reproducible builds.

## Common Patterns

### Adding a new Redis command

Follow the async callback pattern:
```go
err := cfg.RedisClient.SomeCommand(key, func(response resp.Value) {
    // Handle response
    // Store result in context if needed for later phases
    ctx.SetContext("key", value)
    proxywasm.ResumeHttpRequest()
})
if err != nil {
    log.Errorf("redis call failed: %v", err)
    return types.ActionContinue
}
return types.HeaderStopAllIterationAndWatermark
```

### Accessing configuration in handlers

Configuration is passed as a parameter to handler functions:
```go
func onHttpRequestHeaders(ctx wrapper.HttpContext, cfg RedisRqCounterConfig) types.Action {
    // Use cfg.CounterKey, cfg.RedisClient, etc.
}
```

### Logging

Use the Higress log package (not standard log):
```go
log.Infof("message: %v", value)
log.Warnf("warning: %v", err)
log.Errorf("error: %v", err)
```

Logs appear in Envoy output at the configured level (debug for WASM in docker-compose).
