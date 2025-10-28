# AI Token RateLimit 本地测试指南

本指南介绍如何在本地使用 Docker Compose 测试 ai-token-ratelimit 插件。

## 快速开始

### 1. 准备工作

**重要**：本插件需要配合 ai-proxy 插件使用。请先构建 ai-proxy 插件：

```bash
# 构建 ai-proxy 插件
cd ../ai-proxy
make build
cd ../ai-token-ratelimit
```

**配置 Qwen API Token**：

编辑 `envoy.yaml` 文件，找到 ai-proxy 配置部分，将 `<YOUR_QWEN_API_TOKEN>` 替换为你的实际 Qwen API Token：

```yaml
"apiTokens": [
  "sk-your-actual-token-here"
]
```

获取 Qwen API Token：访问 [通义千问控制台](https://dashscope.console.aliyun.com/)

### 2. 构建并启动测试环境

```bash
# 构建 WASM 插件并启动所有服务
make run
```

这将启动三个服务：
- **Envoy Gateway** (端口 10000, 9901) - 网关服务，代理请求到 Qwen AI 服务
- **Redis** (端口 6379) - 用于存储 token 计数
- **Httpbin** (端口 12345) - HTTP 测试服务

### 3. 测试 Token 限流功能

使用 Qwen AI 服务测试真实的 token 限流：

```bash
# 测试 test-key-1 (每分钟限制 50 tokens)
curl -X POST "http://localhost:10000/v1/chat/completions?apikey=test-key-1" \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen-turbo", "messages": [{"role": "user", "content": "你好"}]}'

# 测试 test-key-2 (每分钟限制 100 tokens)
curl -X POST "http://localhost:10000/v1/chat/completions?apikey=test-key-2" \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen-turbo", "messages": [{"role": "user", "content": "你好"}]}'

# 测试未配置的 key（不会限流）
curl -X POST "http://localhost:10000/v1/chat/completions?apikey=unknown-key" \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen-turbo", "messages": [{"role": "user", "content": "你好"}]}'
```

当触发限流时，你会看到 429 响应：

```json
{
  "error": "Too many tokens consumed. Please try again later."
}
```

并包含 `X-TokenRateLimit-Reset` 响应头，指示限流重置时间。

**便捷测试脚本**：

我们提供了一个自动化测试脚本，可以快速验证限流功能（使用真实的 Qwen AI 服务）：

```bash
# 测试 test-key-1（默认发送 5 次请求）
./test-ratelimit.sh

# 测试 test-key-2（发送 5 次请求）
./test-ratelimit.sh test-key-2

# 测试 test-key-1（发送 10 次请求）
./test-ratelimit.sh test-key-1 10
```

脚本会自动显示每次请求的结果、从 Qwen 返回的实际 token 消耗量，以及触发限流后的 Redis 状态。

### 4. 查看日志和调试

```bash
# 查看 Envoy 日志（包含 WASM debug 日志）
docker-compose logs -f envoy

# 查看 Redis 数据
docker-compose exec redis redis-cli
> KEYS higress-token-ratelimit:*
> GET higress-token-ratelimit:test_limit_by_param_apikey:limit_by_param:60:apikey:test-key-1
> TTL higress-token-ratelimit:test_limit_by_param_apikey:limit_by_param:60:apikey:test-key-1
```

### 5. 访问 Envoy 管理界面

```bash
# 在浏览器中打开
open http://localhost:9901
```

可以查看：
- `/stats` - 统计信息
- `/config_dump` - 配置信息
- `/clusters` - 集群状态

### 6. 停止测试环境

```bash
make clean
```

## 架构说明

本测试环境使用两个 WASM 插件：

1. **ai-proxy 插件**：处理与 Qwen API 的交互
   - 认证管理（API Token）
   - 协议转换（OpenAI 格式 → Qwen 格式）
   - 模型映射（将 gpt-3 等模型映射到 qwen-turbo）

2. **ai-token-ratelimit 插件**：限流控制
   - 从 AI 响应中提取 token usage 信息
   - 基于 Redis 进行 token 计数
   - 触发限流并返回 429 错误

数据流向：
```
Client → Envoy → ai-proxy → Qwen API
              ↓
       ai-token-ratelimit
              ↓
            Redis
```

## 核心算法：双阶段 Lua 脚本详解

AI Token 限流的核心挑战是：**请求时无法预知实际 token 消耗量**，只有在 AI 服务响应后才能获取真实的 token usage。因此，插件采用**双阶段固定窗口算法**，通过两个 Lua 脚本分别处理请求和响应阶段。

### 脚本 1: RequestPhaseFixedWindowScript（请求阶段）

**位置**: `main.go:52-70`

#### 完整脚本

```lua
local current = redis.call('get', KEYS[1])
local ttl = redis.call('ttl', KEYS[1])
local threshold = tonumber(ARGV[1])
local window = tonumber(ARGV[2])

-- 键不存在时，返回初始状态（计数0，窗口时间为过期时间）
if not current then
    return {threshold, 0, window}
end

-- 修复异常过期时间（确保窗口有效）
if ttl < 0 then
    ttl = window
end

-- 返回窗口状态：阈值、当前计数、剩余时间
return {threshold, tonumber(current), ttl}
```

#### 参数说明

**输入参数：**
- `KEYS[1]`: Redis key，格式为 `higress-token-ratelimit:{rule_name}:{limit_type}:{window}:{key_name}:{key_value}`
- `ARGV[1]`: Token 限流阈值（threshold），例如 50 表示每分钟最多消耗 50 tokens
- `ARGV[2]`: 时间窗口（window），单位为秒，例如 60 表示 1 分钟

**返回值：**
```
{threshold, current, ttl}
```
- `threshold`: Token 限流阈值
- `current`: 当前已消耗的 token 数量
- `ttl`: key 的剩余过期时间（秒），如果 key 不存在则返回时间窗口大小

#### 执行逻辑详解

**步骤 1: 获取当前计数和 TTL**
```lua
local current = redis.call('get', KEYS[1])
local ttl = redis.call('ttl', KEYS[1])
```
- 获取当前累计的 token 消耗量
- 获取 key 的剩余过期时间

**步骤 2: 处理 key 不存在的情况**
```lua
if not current then
    return {threshold, 0, window}
end
```
- 如果 key 不存在（首次请求或时间窗口已过期），返回初始状态
- `current = 0` 表示尚未消耗任何 token
- `ttl = window` 表示剩余时间等于完整窗口时间

**步骤 3: 修复异常 TTL**
```lua
if ttl < 0 then
    ttl = window
end
```
- Redis TTL 返回值说明：
  - `ttl >= 0`: 正常，key 存在且有过期时间
  - `ttl = -1`: key 存在但没有设置过期时间（异常情况）
  - `ttl = -2`: key 不存在（但此时已在步骤 2 返回）
- 如果发现异常（ttl < 0），重置为完整窗口时间，避免限流逻辑错误

**步骤 4: 返回当前状态**
```lua
return {threshold, tonumber(current), ttl}
```
- 返回当前限流状态，供插件判断是否已超限
- 注意：**此脚本只读取，不修改计数器**

#### 关键设计：只读不写

**为什么请求阶段不累加计数？**

1. **无法预知消耗量**：此时还不知道 AI 服务会消耗多少 token
2. **避免预扣款问题**：如果预扣 token，当请求失败时需要退款，逻辑复杂且容易出错
3. **先检查后累加**：先检查是否接近限额，响应返回后再根据实际消耗累加

**插件的判断逻辑（main.go:164-186）：**
```go
if current > threshold {
    // 已超限，拒绝请求
    rejected(cfg, context)
} else {
    // 未超限，允许请求继续
    proxywasm.ResumeHttpRequest()
}
```

### 脚本 2: ResponsePhaseFixedWindowScript（响应阶段）

**位置**: `main.go:71-96`

#### 完整脚本

```lua
local key = KEYS[1]
local threshold = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local added = tonumber(ARGV[3])  -- 需要累加的token数量

local current = tonumber(redis.call('get', key) or "0")

-- 只有当前计数未超过阈值时才执行累加
if current <= threshold then
    current = redis.call('incrby', key, added)
    -- 第一次设置值时初始化过期时间
    if current == added then
        redis.call('expire', key, window)
    else
        -- 非首次设置时检查过期时间，确保窗口有效性
        local ttl = redis.call('ttl', key)
        if ttl < 0 then
            redis.call('expire', key, window)
        end
    end
end

-- 返回当前窗口状态：阈值、当前计数、剩余时间
return {threshold, current, redis.call('ttl', key)}
```

#### 参数说明

**输入参数：**
- `KEYS[1]`: Redis key（同脚本 1）
- `ARGV[1]`: Token 限流阈值
- `ARGV[2]`: 时间窗口（秒）
- `ARGV[3]`: **实际消耗的 token 数量**（从 AI 响应的 usage 字段提取）

**返回值：**
```
{threshold, current, ttl}
```
- `threshold`: Token 限流阈值
- `current`: 累加后的 token 总消耗量
- `ttl`: key 的剩余过期时间

#### 执行逻辑详解

**步骤 1: 获取当前计数**
```lua
local current = tonumber(redis.call('get', key) or "0")
```
- 获取当前已累计的 token 消耗量
- 如果 key 不存在，默认为 0

**步骤 2: 条件性累加 token**
```lua
if current <= threshold then
    current = redis.call('incrby', key, added)
    ...
end
```
- **关键判断**：使用 `current <= threshold`（注意是 `<=`，不是 `<`）
- **为什么允许超限累加？**
  - 请求已经通过了请求阶段的检查
  - AI 服务已经消耗了 token，必须如实记录
  - 即使累加后超限，也要记录真实消耗，以便下次请求时正确限流

**步骤 3: 设置过期时间**
```lua
if current == added then
    redis.call('expire', key, window)
else
    local ttl = redis.call('ttl', key)
    if ttl < 0 then
        redis.call('expire', key, window)
    end
end
```

- **首次累加** (`current == added`)：
  - 说明这是时间窗口内的第一个请求
  - 初始化过期时间，启动时间窗口计时

- **非首次累加** (`current != added`)：
  - 检查 TTL 是否异常（< 0）
  - 如果异常，重新设置过期时间，确保窗口有效

**步骤 4: 返回最新状态**
```lua
return {threshold, current, redis.call('ttl', key)}
```
- 返回累加后的状态
- 插件可以据此更新日志或 metrics

#### 关键设计：允许超限累加

**为什么不检查 `current + added > threshold` 就拒绝累加？**

```
假设阈值 threshold = 50
时间线：
10:00:00 - 请求 A，检查通过（current=0 < 50）
10:00:05 - 请求 B，检查通过（current=0 < 50，因为 A 还未完成）
10:00:10 - A 完成，消耗 40 tokens，累加后 current=40
10:00:15 - B 完成，消耗 30 tokens，累加后 current=70（超限！）
```

- 并发请求可能导致最终累加值超过阈值
- 但我们**必须如实记录**，因为 token 已经被消耗
- 下一个请求（在 10:00:20）检查时会发现 current=70 > threshold=50，会被拒绝

### 双阶段协同工作流程

#### 完整请求生命周期

**1. 请求到达（10:00:00）**
```
onHttpRequestHeaders() 调用
  ↓
执行 RequestPhaseFixedWindowScript
  ↓
返回 {50, 35, 45}  // threshold=50, current=35, ttl=45s
  ↓
判断: 35 < 50，允许请求继续
  ↓
保存上下文: LimitRedisContext{key, count=50, window=60}
```

**2. 转发到 AI 服务（10:00:01）**
```
Envoy → ai-proxy → Qwen API
```

**3. AI 响应返回（10:00:05）**
```json
{
  "choices": [...],
  "usage": {
    "prompt_tokens": 8,
    "completion_tokens": 12,
    "total_tokens": 20
  }
}
```

**4. 响应处理（10:00:05）**
```
onHttpStreamingBody() 调用
  ↓
从响应中提取: total_tokens = 20
  ↓
执行 ResponsePhaseFixedWindowScript
  KEYS[1] = "higress-token-ratelimit:..."
  ARGV[1] = 50    // threshold
  ARGV[2] = 60    // window
  ARGV[3] = 20    // added tokens
  ↓
Redis 执行:
  current = 35 (读取)
  35 <= 50，允许累加
  current = incrby(key, 20) = 55
  检查 ttl，正常，不重置
  ↓
返回 {50, 55, 40}  // threshold=50, current=55, ttl=40s
```

**5. 下一个请求到达（10:00:10）**
```
onHttpRequestHeaders() 调用
  ↓
执行 RequestPhaseFixedWindowScript
  ↓
返回 {50, 55, 35}  // threshold=50, current=55, ttl=35s
  ↓
判断: 55 > 50，超限！
  ↓
返回 429 Too Many Requests
响应头: X-TokenRateLimit-Reset: 35
```

### 与普通限流算法的对比

| 特性 | AI Token 限流 | 普通请求限流 |
|------|-------------|------------|
| 限流单位 | Token 数量（动态） | 请求次数（固定） |
| 计数时机 | 响应返回后 | 请求到达时 |
| 阶段数 | 两阶段（检查 + 累加） | 单阶段（检查并累加） |
| Lua 脚本 | 2 个（读 + 写） | 1 个（读写合一） |
| 并发问题 | 可能短暂超限 | 严格限制 |
| 典型场景 | AI API 调用 | HTTP 接口限流 |

### 边缘情况处理

#### 情况 1: 并发请求导致超限

```
时刻 T0:  current = 40, threshold = 50
时刻 T1:  请求 A 检查通过（40 < 50）
时刻 T2:  请求 B 检查通过（40 < 50）
时刻 T3:  A 完成，消耗 8 tokens，current = 48
时刻 T4:  B 完成，消耗 15 tokens，current = 63（超限！）
时刻 T5:  请求 C 检查，63 > 50，被拒绝 ✓
```

**设计理念**：允许短暂超限，但下一个请求会被正确拒绝。

#### 情况 2: Key 不存在但 TTL 异常

```lua
-- 理论上不会发生，但防御性编程
if not current then
    return {threshold, 0, window}
end
-- 此时 current 存在，但 ttl < 0（Redis 异常或时钟问题）
if ttl < 0 then
    ttl = window  -- 修复
end
```

#### 情况 3: 响应阶段 Key 已过期

```lua
-- ResponsePhaseFixedWindowScript
local current = tonumber(redis.call('get', key) or "0")  -- current = 0
if current <= threshold then  -- 0 <= 50，允许
    current = redis.call('incrby', key, 20)  -- current = 20
    if current == 20 then  -- 首次累加
        redis.call('expire', key, window)  -- 启动新窗口
    end
end
```

**场景**：请求检查时窗口未过期，但处理耗时较长，响应返回时窗口已过期。
**处理**：视为新窗口的第一个请求，重新计时。

### 调试技巧

#### 1. 查看脚本执行过程

```bash
# 启动 Redis MONITOR
docker-compose exec redis redis-cli MONITOR

# 在另一个终端发送请求
curl -X POST "http://localhost:10000/v1/chat/completions?apikey=test-key-1" \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen-turbo", "messages": [{"role": "user", "content": "测试"}]}'

# 观察 MONITOR 输出，应该看到：
# 请求阶段:
# "EVAL" "local current = redis.call('get', KEYS[1])..." "1" "higress-token-ratelimit:..." "50" "60"
# "GET" "higress-token-ratelimit:..."
# "TTL" "higress-token-ratelimit:..."

# 响应阶段:
# "EVAL" "local key = KEYS[1]..." "1" "higress-token-ratelimit:..." "50" "60" "20"
# "GET" "higress-token-ratelimit:..."
# "INCRBY" "higress-token-ratelimit:..." "20"
# "TTL" "higress-token-ratelimit:..."
```

#### 2. 手动执行 Lua 脚本

**测试请求阶段脚本：**
```bash
docker exec -it redis redis-cli

# 模拟首次请求
EVAL "local current = redis.call('get', KEYS[1]); local ttl = redis.call('ttl', KEYS[1]); local threshold = tonumber(ARGV[1]); local window = tonumber(ARGV[2]); if not current then return {threshold, 0, window} end; if ttl < 0 then ttl = window end; return {threshold, tonumber(current), ttl}" 1 "test-key" 50 60

# 输出: 1) (integer) 50  2) (integer) 0  3) (integer) 60

# 模拟有历史数据的请求
SET "test-key" 35
EXPIRE "test-key" 45
EVAL "..." 1 "test-key" 50 60

# 输出: 1) (integer) 50  2) (integer) 35  3) (integer) 45
```

**测试响应阶段脚本：**
```bash
# 模拟累加 20 tokens
EVAL "local key = KEYS[1]; local threshold = tonumber(ARGV[1]); local window = tonumber(ARGV[2]); local added = tonumber(ARGV[3]); local current = tonumber(redis.call('get', key) or '0'); if current <= threshold then current = redis.call('incrby', key, added); if current == added then redis.call('expire', key, window) else local ttl = redis.call('ttl', key); if ttl < 0 then redis.call('expire', key, window) end end end; return {threshold, current, redis.call('ttl', key)}" 1 "test-key" 50 60 20

# 输出: 1) (integer) 50  2) (integer) 55  3) (integer) 45
# (从 35 累加 20 得到 55)
```

#### 3. 验证并发超限场景

```bash
# 清空 Redis
docker exec redis redis-cli FLUSHDB

# 设置接近阈值的初始值
docker exec redis redis-cli SET "higress-token-ratelimit:test_limit_by_param_apikey:limit_by_param:60:apikey:test-key-1" 45
docker exec redis redis-cli EXPIRE "higress-token-ratelimit:test_limit_by_param_apikey:limit_by_param:60:apikey:test-key-1" 60

# 并发发送多个请求（每个请求消耗约 10-20 tokens）
for i in {1..3}; do
  curl -X POST "http://localhost:10000/v1/chat/completions?apikey=test-key-1" \
    -H "Content-Type: application/json" \
    -d '{"model": "qwen-turbo", "messages": [{"role": "user", "content": "hi"}]}' &
done
wait

# 检查最终计数（可能超过 50）
docker exec redis redis-cli GET "higress-token-ratelimit:test_limit_by_param_apikey:limit_by_param:60:apikey:test-key-1"

# 再发送一个请求，应该被限流
curl -i -X POST "http://localhost:10000/v1/chat/completions?apikey=test-key-1" \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen-turbo", "messages": [{"role": "user", "content": "test"}]}'
# 应该返回 429
```

### 性能优化考量

1. **原子性保证**：两个 Lua 脚本都在 Redis 单线程中原子执行，无需额外锁
2. **网络往返**：请求阶段 1 次 Redis 调用，响应阶段 1 次，总共 2 次（已是最优）
3. **内存占用**：每个 key 只存储一个整数计数器（~8 bytes）+ TTL 元数据
4. **时间复杂度**：GET + TTL = O(1)，INCRBY = O(1)，总体 O(1)

## 配置说明

### 当前限流规则

在 `envoy.yaml` 中配置了基于 URL 参数 `apikey` 的限流：

- `test-key-1`: 每分钟 50 tokens（方便测试限流）
- `test-key-2`: 每分钟 100 tokens（方便测试限流）

Qwen AI 服务会根据实际请求和响应返回真实的 token 消耗量。根据消耗的 token 数量，会在一定次数的请求后触发限流。

### Redis Key 格式

插件使用以下格式存储限流计数：

```
higress-token-ratelimit:<rule_name>:<limit_type>:<window>:<key_name>:<key_value>
```

示例：
```
higress-token-ratelimit:test_limit_by_param_apikey:limit_by_param:60:apikey:test-key-1
```

### 修改配置

你可以修改 `envoy.yaml` 中的插件配置来测试不同的限流策略：

```yaml
{
  "rule_name": "my_custom_rule",
  "rule_items": [
    {
      "limit_by_param": "apikey",
      "limit_keys": [
        {
          "key": "my-key",
          "token_per_second": 10    # 每秒 10 tokens
        }
      ]
    }
  ],
  "redis": {
    "service_name": "redis",
    "service_port": 6379
  },
  "rejected_code": 429,
  "rejected_msg": "Rate limit exceeded"
}
```

修改后重启服务：
```bash
make clean
make run
```

## 故障排查

### Envoy 无法启动

- 检查 `plugin.wasm` 是否存在且已构建
- 查看日志：`docker-compose logs envoy`

### 限流不生效

- 确认所有服务正常运行：`docker-compose ps`
- 检查 Redis 连接：`docker-compose exec redis redis-cli ping`
- 确认使用正确的 endpoint：必须是 `/v1/chat/completions`
- 确认 Qwen API Token 配置正确
- 检查 Envoy 到 Qwen 的 TLS 连接：`docker-compose logs envoy | grep -i "tls\|qwen"`
- 查看 WASM debug 日志：`docker-compose logs -f envoy | grep wasm`
- 检查 Redis 中是否有计数：`docker-compose exec redis redis-cli KEYS "higress-token-ratelimit:*"`

### 端口冲突

如果端口被占用，可以修改 `docker-compose.yaml` 中的端口映射：

```yaml
ports:
  - "11000:10000"  # 改用其他端口
```

## 参考资料

- [AI Token 限流插件文档](./README.md)
- [Higress 官方文档](https://higress.io/)
- [Envoy Proxy 文档](https://www.envoyproxy.io/docs)
