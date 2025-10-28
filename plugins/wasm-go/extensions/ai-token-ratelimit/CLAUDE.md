# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is the `ai-token-ratelimit` plugin for Higress, a WebAssembly (WASM) plugin that implements AI token-based rate limiting using Redis. It operates at execution priority 600 and is designed to work in conjunction with the `ai-proxy` plugin to track and limit AI API token consumption.

## Build and Test Commands

### Building the Plugin

```bash
# Build the WASM plugin (requires Go 1.19+ with WASI support)
make build

# Or manually:
env GOPROXY=https://goproxy.cn,direct GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared -o plugin.wasm ./main.go
```

### Local Testing with Docker

**Prerequisites**: This plugin requires the ai-proxy plugin to work with real AI services.

```bash
# 1. Build ai-proxy plugin first
cd ../ai-proxy
make build
cd ../ai-token-ratelimit

# 2. Configure Qwen API Token in envoy.yaml
#    Edit the ai-proxy configuration and replace <YOUR_QWEN_API_TOKEN>

# 3. Build and start local test environment (Envoy + Redis + Qwen AI)
make run

# 4. Test with the provided script
./test-ratelimit.sh test-key-1 5

# Stop and clean up
make clean
```

### Running Tests

```bash
# Run all tests
go test ./...

# Run specific test file
go test -v ./main_test.go

# Run tests in a specific package
go test -v ./config/...
```

## Architecture

### Plugin Lifecycle

The plugin follows the Higress WASM plugin architecture using the `proxy-wasm-go-sdk`:

1. **Initialization** (`init()`): Registers the plugin with wrapper.SetCtx, defining:
   - Config parser: `parseConfig`
   - Request phase handler: `onHttpRequestHeaders`
   - Response streaming handler: `onHttpStreamingBody`

2. **Request Phase** (`onHttpRequestHeaders`):
   - Matches incoming requests against configured rate limit rules
   - Queries Redis using Lua scripts to check current token usage
   - Either allows request to proceed or rejects with 429 status
   - Stores rate limit context for later use

3. **Response Phase** (`onHttpStreamingBody`):
   - Extracts actual token usage from AI response (using `tokenusage` package)
   - Updates Redis counters with consumed tokens
   - Works with streaming responses to handle both `input_tokens` and `output_tokens`

### Rate Limiting Modes

The plugin supports two distinct modes (mutually exclusive):

1. **Global Threshold**: Simple global limit per rule name
   - Redis key format: `higress-token-ratelimit:<rule_name>:global_threshold:<time_window>`

2. **Rule-based Limiting**: Dynamic limits based on request attributes
   - Redis key format: `higress-token-ratelimit:<rule_name>:<limit_type>:<time_window>:<key_name>:<key_value>`
   - Supports 9 limit types (see config/config.go constants)

### Redis Lua Scripts

Two Lua scripts implement the fixed-window rate limiting algorithm:

- **RequestPhaseFixedWindowScript**: Checks if request can proceed (reads current count)
- **ResponsePhaseFixedWindowScript**: Updates token count after response (increments by actual usage)

Both scripts return: `{threshold, current_count, ttl}` to maintain consistency.

### Code Structure

```
ai-token-ratelimit/
├── main.go                 # Entry point, request/response handlers
├── config/
│   ├── config.go          # Configuration parsing and validation
│   └── config_test.go     # Config unit tests
├── util/
│   └── utils.go           # Helper functions (IP parsing, cookie extraction, metrics)
├── main_test.go           # Integration tests with mock proxywasm
├── envoy.yaml             # Local Envoy config with ai-proxy + Qwen integration
├── docker-compose.yaml    # Local test environment (Envoy + Redis)
├── test-ratelimit.sh      # Automated testing script for rate limiting
└── README_TEST.md         # Comprehensive local testing guide
```

## Key Design Patterns

### Configuration Parsing

The config package validates mutual exclusivity between `global_threshold` and `rule_items`, ensuring only one rate limiting mode is active. Rule items are processed in order, with first-match-wins semantics.

### Limit Type Detection

The `hitRateRuleItem` function in main.go uses a switch statement on `LimitRuleItemType` to extract the rate limit key from different sources (headers, params, cookies, IP, consumer). Each type has specific extraction logic.

### Per-Key vs Direct Matching

- **Direct types** (e.g., `limit_by_param`): Match exact key values
- **Per types** (e.g., `limit_by_per_param`): Support regex patterns (`regexp:^pattern`) or wildcard (`*`) matching

### Context Passing

The plugin uses `ctx.SetContext()` to pass data between request and response phases:
- `LimitRedisContextKey`: Stores Redis key and rate limit parameters
- `tokenusage.CtxKeyInputToken` / `tokenusage.CtxKeyOutputToken`: Token counts from AI response

## Integration Requirements

### Dependency on ai-proxy Plugin

This plugin requires the `ai-proxy` plugin to:
1. Process AI requests and responses
2. Calculate token usage via the `github.com/higress-group/wasm-go/pkg/tokenusage` package
3. Make token counts available during response streaming

The execution order matters: `ai-proxy` (priority 100) runs before `ai-token-ratelimit` (priority 600).

### Redis Setup

Redis must be accessible via Higress service discovery. The plugin supports:
- Static services: `service_name.static` (default port 80)
- DNS services: `service_name.dns` (default port 6379)
- Kubernetes services: `service_name.namespace.svc.cluster.local`

## Testing Strategy

The plugin uses `github.com/higress-group/wasm-go/pkg/test` framework for unit tests, which provides:
- Mock proxywasm host functions
- Simulated HTTP context
- Redis client mocking

Test files demonstrate both global and rule-based rate limiting scenarios with various limit types.

## Common Development Scenarios

### Adding a New Limit Type

1. Add constant to `LimitRuleItemType` in config/config.go
2. Update `parseLimitRuleItem()` to parse the new field
3. Add case in `hitRateRuleItem()` switch statement in main.go
4. Add tests in main_test.go

### Modifying Rate Limit Algorithm

The algorithm is defined in the two Lua scripts at the top of main.go. Changes must maintain the return format: `{threshold, current_count, ttl}`.

### Debugging Local Test Environment

- Envoy admin interface: http://localhost:9901
- WASM logs appear in `docker-compose logs -f envoy` (debug level enabled)
- Redis inspection: `docker-compose exec redis redis-cli`
- Check Redis keys: `KEYS higress-token-ratelimit:*`
- Qwen API connection: Check TLS and API token configuration in envoy.yaml
- Test script: Use `./test-ratelimit.sh` for automated testing

## Important Constraints

- The plugin uses `ctx.DisableReroute()` in request phase to prevent infinite loops
- Metrics are generated per route/cluster/model/consumer combination
- Rate limit headers (X-TokenRateLimit-Reset) are only added on rejection
- User attributes are written to logs on rate limit events for observability
