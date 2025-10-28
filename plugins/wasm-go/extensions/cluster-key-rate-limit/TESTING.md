# Cluster Key Rate Limit 插件测试指南

## 插件功能

该插件基于 Redis 实现**集群级限流**，适用于需要跨多个 Higress Gateway 实例进行**全局一致速率限制**的场景。

**核心特性:**
- 基于 Redis 的分布式限流计数器
- 支持固定时间窗口算法（Fixed Window）
- 支持多种限流维度（URL 参数、请求头、Cookie、客户端 IP、Consumer）
- 支持规则级全局限流和 Key 级动态限流
- 支持正则表达式匹配和通配符
- 在响应头中返回限流状态信息（可选）

## 环境要求

- **Go**: 1.24.1 或更高版本（用于编译 WASM）
- **Docker**: 用于运行 Redis、Envoy 和 httpbin
- **Docker Compose**: 用于编排容器

## 快速开始

### 1. 一键编译并启动（推荐）

```bash
cd /Users/zhongyuan/github/masquee/higress/plugins/wasm-go/extensions/cluster-key-rate-limit

# 编译 WASM 插件并启动所有服务
make run
```

该命令会：
1. 编译 WASM 插件（plugin.wasm）
2. 启动 Redis 服务器（端口 6379）
3. 启动 httpbin 测试服务（端口 8080）
4. 启动 Envoy 网关（端口 10000 和 9901）

### 2. 分步操作（可选）

```bash
# 只编译 WASM 插件
make build

# 启动 Docker Compose 服务（后台运行）
docker-compose up -d

# 停止所有服务
make clean
# 或
docker-compose down
```

### 3. 查看服务日志

```bash
# 查看所有服务日志
docker-compose logs -f

# 只查看 Redis 日志
docker-compose logs -f redis

# 只查看 Envoy 日志（包含 WASM 调试信息）
docker-compose logs -f envoy

# 只查看 httpbin 日志
docker-compose logs -f httpbin
```

## 编译说明

Makefile 使用以下配置编译 WASM 插件：

```bash
env GOPROXY=https://goproxy.cn,direct GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared -o plugin.wasm ./main.go
```

**编译参数说明:**
- `GOPROXY=https://goproxy.cn,direct` - 使用国内代理加速依赖下载
- `GOOS=wasip1` - 目标操作系统为 WASI Preview 1
- `GOARCH=wasm` - 目标架构为 WebAssembly
- `-buildmode=c-shared` - 生成共享库格式
- 输出文件: `plugin.wasm`

## 测试步骤

### 1. 验证服务运行

```bash
# 检查容器状态
docker-compose ps

# 检查 Redis 连接
docker exec redis-server redis-cli ping
# 应该返回: PONG

# 检查 Envoy Admin 接口
curl http://localhost:9901/ready
# 应该返回: LIVE

# 查看 Envoy 集群状态
curl http://localhost:9901/clusters | grep redis
# 应该看到 redis 集群的健康状态
```

### 2. 使用自动化测试脚本（推荐）

我们提供了一个自动化测试脚本，可以快速验证插件的各项功能：

```bash
# 运行自动化测试
./test-ratelimit.sh
```

该脚本会测试：
- ✅ 基于 URL 参数 apikey 的限流
- ✅ 基于请求头 x-api-key 的限流
- ✅ 基于 per_param 的动态限流（每个参数值独立计数）
- ✅ 不同 API Key 的独立限流验证

### 3. 手动测试各种限流场景

#### 测试 1: 基于 URL 参数的限流

配置已设置 `test-key-1` 每分钟最多 5 次请求：

```bash
# 第 1 次请求 - 应该成功
curl -i "http://localhost:10000/get?apikey=test-key-1"

# 观察响应头：
# HTTP/1.1 200 OK
# x-ratelimit-limit: 5              <- 总限制
# x-ratelimit-remaining: 4          <- 剩余次数

# 继续发送 4 次请求（总共 5 次）
for i in {2..5}; do
  echo "请求 $i:"
  curl -s -i "http://localhost:10000/get?apikey=test-key-1" | grep -E "HTTP|x-ratelimit"
  sleep 1
done

# 第 6 次请求 - 应该被限流
curl -i "http://localhost:10000/get?apikey=test-key-1"

# 观察响应：
# HTTP/1.1 429 Too Many Requests
# x-ratelimit-reset: 58             <- 剩余重置时间（秒）
# Content: Too many requests. Please try again later.
```

#### 测试 2: 基于请求头的限流

配置已设置 `header-key-1` 每秒最多 2 次请求：

```bash
# 前两次请求应该成功
curl -i -H "x-api-key: header-key-1" http://localhost:10000/get
curl -i -H "x-api-key: header-key-1" http://localhost:10000/get

# 第三次请求应该被限流
curl -i -H "x-api-key: header-key-1" http://localhost:10000/get

# 等待 1 秒后限流应该重置
sleep 1
curl -i -H "x-api-key: header-key-1" http://localhost:10000/get
```

#### 测试 3: 基于 per_param 的动态限流

配置已设置任意 `user` 参数值每分钟最多 20 次请求（每个用户独立计数）：

```bash
# 用户 alice 的请求
for i in {1..3}; do
  echo "Alice 请求 $i:"
  curl -s -i "http://localhost:10000/get?user=alice" | grep -E "HTTP|x-ratelimit"
done

# 用户 bob 的请求（独立计数，不影响 alice）
for i in {1..3}; do
  echo "Bob 请求 $i:"
  curl -s -i "http://localhost:10000/get?user=bob" | grep -E "HTTP|x-ratelimit"
done

# 两个用户的剩余次数应该都是从 20 开始独立递减
```

#### 测试 4: 查看 Redis 中的限流数据

```bash
# 进入 Redis 容器
docker exec -it redis-server redis-cli

# 查看所有限流相关的 key
KEYS higress-cluster-key-rate-limit:*

# 示例输出:
# 1) "higress-cluster-key-rate-limit:test-rate-limit-rule:limit_by_param:60:apikey:test-key-1"
# 2) "higress-cluster-key-rate-limit:test-rate-limit-rule:limit_by_header:1:x-api-key:header-key-1"
# 3) "higress-cluster-key-rate-limit:test-rate-limit-rule:limit_by_per_param:60:user:alice"
# 4) "higress-cluster-key-rate-limit:test-rate-limit-rule:limit_by_per_param:60:user:bob"

# 查看具体的计数值
GET "higress-cluster-key-rate-limit:test-rate-limit-rule:limit_by_param:60:apikey:test-key-1"
# 返回当前请求次数

# 查看 key 的过期时间
TTL "higress-cluster-key-rate-limit:test-rate-limit-rule:limit_by_param:60:apikey:test-key-1"
# 返回剩余秒数

# 手动删除某个计数器（重置限流）
DEL "higress-cluster-key-rate-limit:test-rate-limit-rule:limit_by_param:60:apikey:test-key-1"

# 退出 Redis CLI
exit
```

## 预期结果

### 正常响应示例（未触发限流）

```bash
$ curl -i "http://localhost:10000/get?apikey=test-key-1"

HTTP/1.1 200 OK
content-type: application/json
content-length: 420
server: envoy
date: Mon, 28 Oct 2024 10:00:00 GMT
x-ratelimit-limit: 5        # <-- 限流阈值
x-ratelimit-remaining: 4    # <-- 剩余可用次数
x-envoy-upstream-service-time: 5

{
  "args": {
    "apikey": "test-key-1"
  },
  "headers": {
    "Accept": "*/*",
    "Host": "localhost:10000",
    ...
  },
  "url": "http://localhost:10000/get?apikey=test-key-1"
}
```

### 触发限流响应示例

```bash
$ curl -i "http://localhost:10000/get?apikey=test-key-1"

HTTP/1.1 429 Too Many Requests
content-length: 46
content-type: text/plain
x-ratelimit-reset: 55       # <-- 限流重置时间（秒）
date: Mon, 28 Oct 2024 10:00:30 GMT
server: envoy

Too many requests. Please try again later.
```

## 故障排查

### 问题 1: 限流没有生效

**可能原因:**
- Redis 连接失败
- WASM 插件未正确加载
- 请求参数不匹配配置的限流规则

**排查步骤:**
```bash
# 1. 检查 Redis 是否正常运行
docker exec redis-server redis-cli ping
# 应该返回: PONG

# 2. 检查 Envoy 日志中的 Redis 连接错误
docker-compose logs envoy | grep -i "redis\|error"

# 3. 检查 WASM 插件是否加载成功
docker-compose logs envoy | grep -i "wasm\|plugin"

# 4. 测试请求是否包含正确的参数
curl -v "http://localhost:10000/get?apikey=test-key-1"
# 确保 URL 中包含 apikey 参数

# 5. 查看 Envoy stats
curl http://localhost:9901/stats | grep wasm
```

### 问题 2: Redis 连接超时

**可能原因:**
- Redis 容器未启动或未就绪
- 网络配置问题
- envoy.yaml 中的 Redis cluster 配置错误

**排查步骤:**
```bash
# 1. 检查 Redis 容器状态
docker-compose ps redis
# 应该显示 "Up" 状态

# 2. 测试从 Envoy 容器访问 Redis
docker exec envoy-gateway ping -c 2 redis
# 应该能够 ping 通

# 3. 检查 Redis 端口
docker exec redis-server redis-cli -p 6379 ping
# 应该返回: PONG

# 4. 查看 Envoy 的 Redis cluster 状态
curl http://localhost:9901/clusters | grep redis
# 查看健康状态和连接数

# 5. 查看详细日志
docker-compose logs envoy | grep -A 5 -B 5 redis
```

### 问题 3: 限流计数不准确

**可能原因:**
- 时钟不同步
- Redis 数据未正确清理
- 多个限流规则冲突

**排查步骤:**
```bash
# 1. 清空 Redis 数据库
docker exec redis-server redis-cli FLUSHDB

# 2. 检查 Redis 中的所有 key
docker exec redis-server redis-cli KEYS "*"

# 3. 查看具体的限流计数和 TTL
docker exec redis-server redis-cli --scan --pattern "higress-cluster-key-rate-limit:*" | while read key; do
  echo "Key: $key"
  echo "  Value: $(docker exec redis-server redis-cli GET $key)"
  echo "  TTL: $(docker exec redis-server redis-cli TTL $key)s"
done

# 4. 启用 Redis MONITOR 实时查看命令
docker exec -it redis-server redis-cli MONITOR
# 然后在另一个终端发送请求，观察 Redis 命令执行情况

# 5. 检查是否有多个限流规则匹配
# 查看 envoy.yaml 中的 rule_items 配置
# 规则按顺序匹配，只会命中第一个匹配的规则
```

### 问题 4: WASM 编译失败

**可能原因:**
- Go 版本不匹配（需要 1.24.1+）
- 依赖包下载失败
- 编译参数错误

**解决方法:**
```bash
# 1. 检查 Go 版本
go version
# 应该是 go1.24.1 或更高版本

# 2. 清理并更新依赖
go clean -cache
go mod tidy

# 3. 使用 Makefile 重新编译
make build

# 4. 检查编译后的文件
ls -lh plugin.wasm
file plugin.wasm
# 应该显示: WebAssembly (wasm) binary module

# 5. 如果代理下载失败，尝试直接访问
GOPROXY=https://proxy.golang.org,direct make build
```

## 高级测试

### 测试不同时间窗口的限流

修改 `envoy.yaml` 中的配置，测试不同的时间窗口：

```yaml
value: |
  {
    "rule_name": "test-window-rule",
    "rule_items": [
      {
        "limit_by_param": "apikey",
        "limit_keys": [
          {
            "key": "test-second",
            "query_per_second": 2     # 每秒 2 次
          },
          {
            "key": "test-minute",
            "query_per_minute": 10    # 每分钟 10 次
          },
          {
            "key": "test-hour",
            "query_per_hour": 100     # 每小时 100 次
          }
        ]
      }
    ],
    "redis": {
      "service_name": "redis",
      "service_port": 6379
    },
    "show_limit_quota_header": true
  }
```

重启服务后测试：

```bash
docker-compose restart envoy

# 测试每秒限流
for i in {1..3}; do
  curl -s -i "http://localhost:10000/get?apikey=test-second" | grep HTTP
  sleep 0.1
done
# 第 3 次应该被限流

# 等待 1 秒后重置
sleep 1
curl -i "http://localhost:10000/get?apikey=test-second"
# 应该成功
```

### 测试正则表达式匹配

```yaml
value: |
  {
    "rule_name": "test-regexp-rule",
    "rule_items": [
      {
        "limit_by_per_param": "user_id",
        "limit_keys": [
          {
            "key": "regexp:^admin.*",    # 匹配 admin 开头的用户
            "query_per_minute": 100
          },
          {
            "key": "regexp:^vip.*",      # 匹配 vip 开头的用户
            "query_per_minute": 50
          },
          {
            "key": "*",                   # 其他所有用户
            "query_per_minute": 10
          }
        ]
      }
    ],
    "redis": {
      "service_name": "redis",
      "service_port": 6379
    },
    "show_limit_quota_header": true
  }
```

测试：

```bash
# admin 用户（100 次/分钟）
curl -i "http://localhost:10000/get?user_id=admin123"
# 应该看到 x-ratelimit-limit: 100

# vip 用户（50 次/分钟）
curl -i "http://localhost:10000/get?user_id=vip456"
# 应该看到 x-ratelimit-limit: 50

# 普通用户（10 次/分钟）
curl -i "http://localhost:10000/get?user_id=user789"
# 应该看到 x-ratelimit-limit: 10
```

### 测试基于 IP 的限流

```yaml
value: |
  {
    "rule_name": "test-ip-rule",
    "rule_items": [
      {
        "limit_by_per_ip": "from-remote-addr",
        "limit_keys": [
          {
            "key": "127.0.0.0/24",       # 本地 IP 段
            "query_per_minute": 100
          },
          {
            "key": "0.0.0.0/0",          # 所有其他 IP
            "query_per_minute": 10
          }
        ]
      }
    ],
    "redis": {
      "service_name": "redis",
      "service_port": 6379
    },
    "show_limit_quota_header": true
  }
```

### 测试全局限流模式

```yaml
value: |
  {
    "rule_name": "global-limit-rule",
    "global_threshold": {
      "query_per_minute": 50    # 全局每分钟 50 次请求
    },
    "redis": {
      "service_name": "redis",
      "service_port": 6379
    },
    "show_limit_quota_header": true
  }
```

测试：

```bash
# 所有请求共享同一个限流配额
for i in {1..10}; do
  echo "请求 $i:"
  curl -s -i "http://localhost:10000/get?user=user$i" | grep -E "HTTP|x-ratelimit"
done

# 查看 Redis 中的全局计数器
docker exec redis-server redis-cli KEYS "higress-cluster-key-rate-limit:*global*"
```

### 性能压力测试

使用 Apache Bench 进行压力测试：

```bash
# 安装 ab（如果未安装）
# macOS: brew install httpd
# Ubuntu: sudo apt-get install apache2-utils

# 发送 1000 个请求，并发 50
ab -n 1000 -c 50 "http://localhost:10000/get?apikey=test-key-1"

# 查看最终的 Redis 计数
docker exec redis-server redis-cli GET "higress-cluster-key-rate-limit:test-rate-limit-rule:limit_by_param:60:apikey:test-key-1"

# 观察 Envoy 统计信息
curl http://localhost:9901/stats | grep -E "redis|cluster.*rate.*limit"
```

## 清理环境

```bash
# 使用 Makefile 清理（推荐）
make clean

# 或手动清理
docker-compose down

# 删除数据卷（会清空 Redis 数据）
docker-compose down -v

# 删除 WASM 文件
rm plugin.wasm
```

## 配置说明

### 插件配置参数 (envoy.yaml)

插件在 `envoy.yaml` 中的完整配置示例：

```yaml
configuration:
  "@type": "type.googleapis.com/google.protobuf.StringValue"
  value: |
    {
      "rule_name": "my-rate-limit-rule",        # 限流规则名称
      "rule_items": [                            # 限流规则列表
        {
          "limit_by_param": "apikey",            # 限流维度：URL 参数
          "limit_keys": [                        # 限流配置列表
            {
              "key": "key-1",                    # 匹配的 key 值
              "query_per_minute": 10             # 限流阈值
            }
          ]
        }
      ],
      "redis": {                                 # Redis 配置
        "service_name": "redis",                 # Redis 服务名称
        "service_port": 6379,                    # Redis 端口
        "timeout": 2000                          # 超时时间（毫秒）
      },
      "show_limit_quota_header": true,          # 显示限流状态头
      "rejected_code": 429,                      # 限流时的 HTTP 状态码
      "rejected_msg": "Too many requests"        # 限流时的响应消息
    }
```

### Redis Key 格式

插件在 Redis 中使用以下 key 格式：

**规则限流模式:**
```
higress-cluster-key-rate-limit:{rule_name}:{limit_type}:{time_window}:{key_name}:{key_value}
```

示例:
```
higress-cluster-key-rate-limit:test-rate-limit-rule:limit_by_param:60:apikey:test-key-1
```

**全局限流模式:**
```
higress-cluster-key-rate-limit:{rule_name}:global_threshold:{time_window}
```

### 时间窗口映射

| 配置字段 | 时间窗口（秒） | 说明 |
|---------|--------------|------|
| `query_per_second` | 1 | 每秒请求次数 |
| `query_per_minute` | 60 | 每分钟请求次数 |
| `query_per_hour` | 3600 | 每小时请求次数 |
| `query_per_day` | 86400 | 每天请求次数 |

## 代码实现说明

### 核心常量（main.go:46-82）

```go
const (
    RedisKeyPrefix = "higress-cluster-key-rate-limit"
    ClusterGlobalRateLimitFormat = RedisKeyPrefix + ":%s:global_threshold:%d"
    ClusterRateLimitFormat = RedisKeyPrefix + ":%s:%s:%d:%s:%s"
    FixedWindowScript = `...`  // Lua 脚本实现固定窗口算法
)
```

### 工作流程

**1. 请求阶段（onHttpRequestHeaders）**
- 匹配限流规则（按顺序，命中第一个）
- 构造 Redis key
- 调用 Lua 脚本执行原子性限流检查和递增
- 判断是否超过阈值
- 超过则返回 429，未超过则继续

**2. 响应阶段（onHttpResponseHeaders）**
- 如果配置了 `show_limit_quota_header`
- 在响应头中添加限流状态信息

### 固定窗口算法（Lua 脚本详解）

插件的核心限流逻辑通过 Redis Lua 脚本实现，位于 `main.go:53-73` 的 `FixedWindowScript` 常量。使用 Lua 脚本的优势在于保证限流操作的**原子性**，避免并发条件下的竞态问题。

#### 完整 Lua 脚本

```lua
local key = KEYS[1]
local threshold = tonumber(ARGV[1])
local window = tonumber(ARGV[2])

local current = tonumber(redis.call('get', key) or "0")

-- 只有超过阈值时才停止累加，达到阈值时仍允许（此时是最后一次允许）
if current > threshold then
    return {threshold, current, redis.call('ttl', key)}
end

-- 计数未超过阈值，执行累加
current = redis.call('incr', key)
-- 第一次累加时设置过期时间
if current == 1 then
    redis.call('expire', key, window)
end

return {threshold, current, redis.call('ttl', key)}
```

#### 参数说明

**输入参数：**
- `KEYS[1]`: Redis key，格式为 `higress-cluster-key-rate-limit:{rule_name}:{limit_type}:{window}:{key_name}:{key_value}`
- `ARGV[1]`: 限流阈值 (threshold)，例如每分钟 5 次请求则为 5
- `ARGV[2]`: 时间窗口 (window)，单位为秒，例如 1 分钟为 60

**返回值：**
返回一个包含 3 个元素的数组：
```
{threshold, current, ttl}
```
- `threshold`: 限流阈值
- `current`: 当前计数值
- `ttl`: key 的剩余过期时间（秒）

#### 执行逻辑详解

**步骤 1: 获取当前计数**
```lua
local current = tonumber(redis.call('get', key) or "0")
```
- 从 Redis 中获取当前计数器的值
- 如果 key 不存在，默认为 "0"
- 转换为数字类型方便计算

**步骤 2: 检查是否超过阈值**
```lua
if current > threshold then
    return {threshold, current, redis.call('ttl', key)}
end
```
- **关键判断**: 使用 `current > threshold` 而不是 `>=`
- 这意味着当 `current == threshold` 时，**仍然允许请求通过**
- 例如：threshold=5 时，允许通过的请求序号为 1,2,3,4,5，第 6 个请求才被拒绝
- 如果已超限，直接返回当前状态，**不进行计数累加**

**步骤 3: 执行原子性递增**
```lua
current = redis.call('incr', key)
```
- 使用 Redis 的 `INCR` 命令进行原子性递增
- `INCR` 是线程安全的，多个并发请求不会导致计数错误
- 如果 key 不存在，`INCR` 会先将其初始化为 0，再递增为 1

**步骤 4: 设置过期时间**
```lua
if current == 1 then
    redis.call('expire', key, window)
end
```
- **只在第一次请求时**（current == 1）设置过期时间
- 这样可以避免每次请求都重置过期时间
- 过期时间就是时间窗口大小，例如 60 秒

**步骤 5: 返回限流状态**
```lua
return {threshold, current, redis.call('ttl', key)}
```
- 返回限流阈值、当前计数和剩余时间
- 插件根据这些信息计算 `X-RateLimit-Remaining` 响应头

#### 固定窗口算法特性

**优点：**
1. **实现简单**: 逻辑清晰，易于理解和维护
2. **性能高效**: 只需要一次 Redis 操作（Lua 脚本原子执行）
3. **内存占用小**: 每个限流 key 只需要存储一个计数器

**局限性：**
1. **边界突刺问题**: 在时间窗口交界处可能出现短时间内的流量突刺

   ```
   时间窗口：[0-60s]          [60-120s]
   请求分布：                 |
            [............5个] [5个............]
                    ↑边界
   ```
   在第 59 秒发送 5 个请求，在第 61 秒又发送 5 个请求，2 秒内实际通过了 10 个请求。

2. **时间窗口固定**: 从第一个请求开始计时，无法实现真正的滑动窗口

#### 实际运行示例

假设配置为 `query_per_minute: 5`（每分钟 5 次请求）：

**第 1 次请求（10:00:00）：**
```lua
-- Redis 中不存在 key
current = tonumber(redis.call('get', key) or "0")  -- current = 0
if 0 > 5 then ... end  -- 不满足，继续
current = redis.call('incr', key)  -- current = 1
if current == 1 then redis.call('expire', key, 60) end  -- 设置 60 秒过期
return {5, 1, 60}  -- threshold=5, current=1, ttl=60
```
- **插件计算**: remaining = 5 - 1 = 4
- **响应头**: `X-RateLimit-Remaining: 4`

**第 5 次请求（10:00:20）：**
```lua
current = tonumber(redis.call('get', key) or "0")  -- current = 4
if 4 > 5 then ... end  -- 不满足，继续
current = redis.call('incr', key)  -- current = 5
if current == 1 then ... end  -- 不满足，不重置过期时间
return {5, 5, 40}  -- threshold=5, current=5, ttl=40
```
- **插件计算**: remaining = 5 - 5 = 0
- **响应头**: `X-RateLimit-Remaining: 0`
- **状态**: 200 OK（仍然允许）

**第 6 次请求（10:00:25）：**
```lua
current = tonumber(redis.call('get', key) or "0")  -- current = 5
if 5 > 5 then ... end  -- 不满足（注意是 >，不是 >=）
current = redis.call('incr', key)  -- current = 6
return {5, 6, 35}  -- threshold=5, current=6, ttl=35
```
- **插件判断**: current (6) > threshold (5)，触发限流！
- **响应**: 429 Too Many Requests
- **响应头**: `X-RateLimit-Reset: 35`

**时间窗口重置后（10:01:01）：**
```lua
-- Redis key 已过期自动删除
current = tonumber(redis.call('get', key) or "0")  -- current = 0
-- 重新开始计数...
```

#### 与滑动窗口算法对比

| 特性 | 固定窗口 | 滑动窗口 |
|------|---------|---------|
| 实现复杂度 | 简单 | 复杂 |
| 内存占用 | 小（1 个计数器） | 大（需存储每个请求时间戳） |
| 边界突刺 | 有 | 无 |
| 限流精度 | 中等 | 高 |
| 性能 | 高（O(1)） | 中等（O(n)，n 为窗口内请求数） |

#### 调试技巧

**查看 Lua 脚本执行过程：**
```bash
# 启用 Redis MONITOR 实时查看命令
docker exec -it redis-server redis-cli MONITOR

# 在另一个终端发送请求
curl "http://localhost:10000/get?apikey=test-key-1"

# 观察 MONITOR 输出，应该看到类似：
# "EVAL" "local key = KEYS[1]..." "1"
#   "higress-cluster-key-rate-limit:test-rate-limit-rule:limit_by_param:60:apikey:test-key-1"
#   "5" "60"
# "GET" "higress-cluster-key-rate-limit:..."
# "INCR" "higress-cluster-key-rate-limit:..."
# "EXPIRE" "higress-cluster-key-rate-limit:..." "60"
```

**手动执行 Lua 脚本：**
```bash
# 进入 Redis CLI
docker exec -it redis-server redis-cli

# 手动执行 Lua 脚本
EVAL "local key = KEYS[1]; local threshold = tonumber(ARGV[1]); local window = tonumber(ARGV[2]); local current = tonumber(redis.call('get', key) or '0'); if current > threshold then return {threshold, current, redis.call('ttl', key)} end; current = redis.call('incr', key); if current == 1 then redis.call('expire', key, window) end; return {threshold, current, redis.call('ttl', key)}" 1 "test-key" 5 60

# 观察返回值：
# 1) (integer) 5     -- threshold
# 2) (integer) 1     -- current
# 3) (integer) 60    -- ttl
```

## 参考资料

- [Higress 文档](https://higress.io/docs/)
- [Cluster Key Rate Limit 插件文档](./README.md)
- [Envoy Proxy 文档](https://www.envoyproxy.io/docs/envoy/latest/)
- [Redis 命令参考](https://redis.io/commands/)
- [Proxy-Wasm 规范](https://github.com/proxy-wasm/spec)
- [固定窗口算法介绍](https://en.wikipedia.org/wiki/Rate_limiting#Fixed_window)
