# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is the **Cluster Key Rate Limit** plugin for Higress, a WASM-based distributed rate limiting solution using Redis. The plugin implements cluster-wide rate limiting across multiple Higress Gateway instances with support for various limiting dimensions (URL parameters, headers, cookies, client IPs, consumers).

**Key characteristics:**
- Language: Go (compiled to WebAssembly)
- Target: WASI Preview 1 (GOOS=wasip1, GOARCH=wasm)
- Go version: 1.24.1+
- Runtime: Envoy Proxy with Proxy-Wasm SDK
- Storage: Redis (for distributed counters)

## Build and Development Commands

### Building the Plugin

```bash
# Build WASM plugin
make build

# Full command (used in Makefile):
env GOPROXY=https://goproxy.cn,direct GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared -o plugin.wasm ./main.go
```

**Important build notes:**
- Must use `-buildmode=c-shared` to generate shared library format
- Output file is `plugin.wasm` (not the module name)
- Use GOPROXY=https://goproxy.cn,direct for faster dependency downloads in China

### Local Testing

```bash
# Build and start all services (Redis, Envoy, httpbin)
make run

# Start services only (assumes plugin.wasm already built)
docker-compose up -d

# View logs
docker-compose logs -f envoy    # WASM debug logs
docker-compose logs -f redis    # Redis operations

# Stop and cleanup
make clean
# or
docker-compose down
```

### Running Tests

```bash
# Run Go unit tests
go test -v ./...

# Run integration test script (requires services running)
./test-ratelimit.sh
```

## Architecture

### Core Components

1. **main.go** - Plugin entry point
   - `init()`: Registers plugin with wrapper.SetCtx()
   - `onHttpRequestHeaders()`: Rate limit check phase
   - `onHttpResponseHeaders()`: Add rate limit headers to response
   - `FixedWindowScript`: Redis Lua script for atomic rate limiting

2. **config/config.go** - Configuration parsing
   - `ClusterKeyRateLimitConfig`: Main config structure
   - `InitRedisClusterClient()`: Redis client initialization
   - `ParseClusterKeyRateLimitConfig()`: Parse plugin configuration from JSON

3. **util/** - Utility functions
   - Helper functions for cookie parsing, IP extraction, JSON serialization

### Rate Limiting Algorithm

The plugin uses **Fixed Window** algorithm implemented via Redis Lua script:

**Lua Script Logic (main.go:53-73):**
```lua
-- Get current count
local current = tonumber(redis.call('get', key) or "0")

-- Check if exceeded threshold (note: >, not >=)
if current > threshold then
    return {threshold, current, redis.call('ttl', key)}
end

-- Increment counter atomically
current = redis.call('incr', key)

-- Set expiration on first request
if current == 1 then
    redis.call('expire', key, window)
end

return {threshold, current, redis.call('ttl', key)}
```

**Key design decisions:**
- Uses `current > threshold` (not `>=`) so when current==threshold, request is still allowed
- Example: threshold=5 allows requests 1,2,3,4,5; request 6 is rejected
- Atomic operations via Lua script prevent race conditions
- TTL set only on first request to avoid resetting the window

### Redis Key Format

**Rule-based rate limiting:**
```
higress-cluster-key-rate-limit:{rule_name}:{limit_type}:{time_window}:{key_name}:{key_value}
```

**Global rate limiting:**
```
higress-cluster-key-rate-limit:{rule_name}:global_threshold:{time_window}
```

### Request Processing Flow

1. **Request Phase** (`onHttpRequestHeaders`):
   - Match rate limit rule (first match wins)
   - Construct Redis key based on rule type and request attributes
   - Execute Lua script: `RedisClient.Eval(FixedWindowScript, ...)`
   - If count > threshold: return 429 with `X-RateLimit-Reset` header
   - Else: save limit context and continue

2. **Response Phase** (`onHttpResponseHeaders`):
   - If `show_limit_quota_header` enabled:
     - Add `X-RateLimit-Limit` (total limit)
     - Add `X-RateLimit-Remaining` (remaining requests)

### Supported Rate Limit Dimensions

| Limit Type | Description | Key Source |
|-----------|-------------|------------|
| `limit_by_param` | URL parameter exact match | Query parameter value |
| `limit_by_header` | Request header exact match | Header value |
| `limit_by_cookie` | Cookie key exact match | Cookie value |
| `limit_by_consumer` | Consumer name exact match | Consumer header |
| `limit_by_per_param` | Per-parameter dynamic limiting (regex/wildcard) | Each unique param value |
| `limit_by_per_header` | Per-header dynamic limiting (regex/wildcard) | Each unique header value |
| `limit_by_per_cookie` | Per-cookie dynamic limiting (regex/wildcard) | Each unique cookie value |
| `limit_by_per_consumer` | Per-consumer dynamic limiting (regex/wildcard) | Each consumer name |
| `limit_by_per_ip` | Per-IP limiting (IP/CIDR) | Client IP address |

**Pattern matching for "per_*" types:**
- `"*"`: Match all (catch-all)
- `"regexp:^prefix.*"`: Regular expression matching
- Specific value: Exact match

### Configuration Structure

```yaml
rule_name: "my-rate-limit-rule"
rule_items:
  - limit_by_param: "apikey"          # Match by URL param 'apikey'
    limit_keys:
      - key: "key-1"                  # Exact match
        query_per_minute: 10
      - key: "regexp:^vip.*"          # Regex match
        query_per_minute: 100
      - key: "*"                       # Catch-all
        query_per_minute: 5

redis:
  service_name: "redis"                # Kubernetes service name or DNS
  service_port: 6379
  timeout: 2000                        # Milliseconds

show_limit_quota_header: true
rejected_code: 429
rejected_msg: "Too many requests"
```

**Time window options:**
- `query_per_second`: 1 second window
- `query_per_minute`: 60 seconds window
- `query_per_hour`: 3600 seconds window
- `query_per_day`: 86400 seconds window

## Testing Strategy

### Local Development Testing

1. **Start test environment:**
   ```bash
   make run
   ```

2. **Manual testing:**
   ```bash
   # Test URL parameter rate limiting
   curl "http://localhost:10000/get?apikey=test-key-1"

   # Check rate limit headers
   curl -i "http://localhost:10000/get?apikey=test-key-1"
   # Look for: X-RateLimit-Limit, X-RateLimit-Remaining

   # Test rate limit trigger
   for i in {1..6}; do curl "http://localhost:10000/get?apikey=test-key-1"; done
   ```

3. **Automated test script:**
   ```bash
   ./test-ratelimit.sh
   ```
   Tests: param limiting, header limiting, per_param dynamic limiting, multi-key independence

4. **Redis inspection:**
   ```bash
   # View all rate limit keys
   docker exec redis-server redis-cli KEYS "higress-cluster-key-rate-limit:*"

   # Check specific counter
   docker exec redis-server redis-cli GET "higress-cluster-key-rate-limit:..."

   # Monitor Redis commands in real-time
   docker exec -it redis-server redis-cli MONITOR
   ```

### Debugging

**Envoy logs with WASM debug:**
```bash
docker-compose logs envoy | grep -i "wasm\|redis\|rate.*limit"
```

**Check Envoy stats:**
```bash
curl http://localhost:9901/stats | grep redis
```

**Redis TTL inspection:**
```bash
docker exec redis-server redis-cli TTL "higress-cluster-key-rate-limit:..."
```

## Common Pitfalls

1. **WASM Compilation Issues:**
   - Must use Go 1.24.1+ for WASI support
   - Always use `GOOS=wasip1 GOARCH=wasm`
   - Use `-buildmode=c-shared`, not default mode

2. **Fixed Window Boundary Burst:**
   - At window boundaries, requests can "burst" beyond limit
   - Example: 5 requests at 59s, 5 more at 61s = 10 requests in 2 seconds
   - This is inherent to fixed window algorithm, not a bug

3. **Redis Key Not Expiring:**
   - TTL only set on first request (current==1 check in Lua)
   - If Redis restarts without persistence, counters reset

4. **Rate Limit Not Matching:**
   - Rules match in order; first match wins
   - Check rule ordering in `rule_items` array
   - Use `log.Infof()` in code to debug matched rules

5. **Envoy-Redis Connectivity:**
   - Ensure Redis cluster name matches service_name in config
   - Check Docker networking: services must be in same network
   - Verify `depends_on` in docker-compose.yaml

## Dependencies

**Core libraries:**
- `github.com/higress-group/proxy-wasm-go-sdk`: Proxy-Wasm SDK for Envoy integration
- `github.com/higress-group/wasm-go/pkg/wrapper`: Higress wrapper utilities
- `github.com/tidwall/gjson`: Fast JSON parsing
- `github.com/tidwall/resp`: Redis RESP protocol

**Testing stack:**
- Redis 7 Alpine: Distributed counter storage
- Envoy (Higress Gateway v2.1.5): WASM runtime
- httpbin: Test backend service

## File Structure

```
cluster-key-rate-limit/
├── main.go              # Plugin entry point, Lua script, request handlers
├── config/
│   └── config.go       # Configuration parsing and Redis client setup
├── util/
│   └── util.go         # Helper utilities (cookie, IP, JSON)
├── Makefile            # Build commands
├── docker-compose.yaml # Local test environment
├── envoy.yaml          # Envoy + plugin configuration
├── test-ratelimit.sh   # Automated integration tests
├── TESTING.md          # Comprehensive testing guide (includes Lua script deep dive)
└── README.md           # User-facing documentation
```

## Performance Considerations

- Lua script executes atomically in Redis (O(1) complexity)
- Each request triggers one Redis EVAL call
- Memory: ~100 bytes per unique rate limit key
- Recommended: Use Redis with AOF persistence for counter durability
- High traffic: Consider Redis Cluster for horizontal scaling
