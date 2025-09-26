# Redis Request Counter 插件测试指南

## 插件功能

该插件使用 Redis 统计请求数量，每次请求通过时会自动递增计数器，并在响应头中返回当前计数值。

**核心特性：**
- 使用 Redis INCR 命令实现原子性计数
- 支持自定义计数器名称（counter_key）
- 在响应头 `X-Request-Count` 中返回计数值
- 支持 Redis 认证和多数据库
- 异步非阻塞处理，性能优异

## 环境要求

- **Go**: 1.24.1 或更高版本（用于编译 WASM）
- **Docker**: 用于运行 Redis、Envoy 和 httpbin
- **Docker Compose**: 用于编排容器

## 快速开始

### 1. 一键编译并启动（推荐）

```bash
cd /Users/zhongyuan/github/masquee/higress/plugins/wasm-go/extensions/redis-rq-counter

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
```

## 编译说明

Makefile 使用以下配置编译 WASM 插件：

```bash
env GOPROXY=https://goproxy.cn,direct GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared -o plugin.wasm ./main.go
```

**编译参数说明：**
- `GOPROXY=https://goproxy.cn,direct` - 使用国内代理加速依赖下载
- `GOOS=wasip1` - 目标操作系统为 WASI Preview 1
- `GOARCH=wasm` - 目标架构为 WebAssembly
- `-buildmode=c-shared` - 生成共享库格式
- 输出文件：`plugin.wasm`

## 测试步骤

### 1. 验证服务运行

```bash
# 检查容器状态
docker-compose ps

# 检查 Redis 连接（需要进入 Redis 容器）
docker exec redis-server redis-cli ping
# 应该返回: PONG

# 检查 Envoy Admin 接口
curl http://localhost:9901/ready
# 应该返回: LIVE

# 查看 Envoy 集群状态
curl http://localhost:9901/clusters | grep redis
# 应该看到 redis 集群的健康状态
```

### 2. 发送测试请求

```bash
# 发送第一个请求
curl -i http://localhost:10000/get

# 观察响应头，应该包含：
# x-request-count: 1

# 发送更多请求并观察计数递增
for i in {1..5}; do
  echo "Request $i:"
  curl -s -i http://localhost:10000/get 2>&1 | grep -i "x-request-count"
  sleep 0.5
done
```

### 3. 直接查看 Redis 中的数据

```bash
# 方式一：进入 Redis 容器
docker exec -it redis-server redis-cli

# 方式二：直接执行命令
docker exec redis-server redis-cli GET higress-redis-rq-counter:test-counter

# 查看计数器值
GET higress-redis-rq-counter:test-counter

# 查看所有相关的 key
KEYS higress-redis-rq-counter:*

# 查看 key 的类型
TYPE higress-redis-rq-counter:test-counter

# 删除计数器（重置）
DEL higress-redis-rq-counter:test-counter
```

## 预期结果

### 正常响应示例

```bash
$ curl -i http://localhost:10000/get

HTTP/1.1 200 OK
content-type: application/json
content-length: 314
server: envoy
date: Sun, 27 Oct 2024 03:27:00 GMT
x-request-count: 1  # <-- 这是我们的插件添加的响应头
access-control-allow-origin: *
access-control-allow-credentials: true
x-envoy-upstream-service-time: 156

{
  "args": {},
  "headers": {
    "Accept": "*/*",
    "Host": "httpbin.org",
    ...
  },
  ...
}
```

### 多次请求测试

```bash
$ for i in {1..5}; do curl -s -i http://localhost:10000/get | grep -i x-request-count; done

x-request-count: 1
x-request-count: 2
x-request-count: 3
x-request-count: 4
x-request-count: 5
```

## 故障排查

### 问题 1: 没有看到 X-Request-Count 响应头

**可能原因：**
- WASM 插件没有正确加载
- Redis 连接失败

**排查步骤：**
```bash
# 1. 检查 Envoy 日志
docker-compose logs envoy | grep -i "redis\|wasm\|error"

# 2. 检查 WASM 文件是否存在
ls -lh redis-rq-counter.wasm

# 3. 查看 Envoy stats
curl http://localhost:9901/stats | grep wasm
```

### 问题 2: Redis 连接失败

**可能原因：**
- Redis 容器未启动或未就绪
- 网络配置问题
- `envoy.yaml` 中的 Redis cluster 配置错误

**排查步骤：**
```bash
# 1. 检查 Redis 容器状态
docker-compose ps redis
# 应该显示 "Up" 状态

# 2. 测试 Redis 连接
docker exec redis-server redis-cli ping
# 应该返回: PONG

# 3. 查看 Envoy 的 Redis cluster 状态
curl http://localhost:9901/clusters | grep redis
# 查看 cluster 健康状态和连接数

# 4. 查看 Envoy 日志中的 Redis 错误
docker-compose logs envoy | grep -i redis
docker-compose logs envoy | grep -i error

# 5. 检查网络连通性
docker exec envoy ping -c 2 redis
```

**常见问题：**
- cluster name 不匹配：确保 `envoy.yaml` 中的 `service_name` 与 cluster 定义一致
- 端口错误：确认 Redis 使用的是 6379 端口
- 依赖启动顺序：确保 Redis 在 Envoy 之前启动（使用 `depends_on`）

### 问题 3: WASM 编译失败

**可能原因：**
- Go 版本不匹配（需要 1.24.1+）
- 依赖包下载失败
- 编译参数错误

**解决方法：**
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

# 5. 如果使用代理下载失败，尝试直接访问
GOPROXY=https://proxy.golang.org,direct make build
```

**注意：**
- 本项目使用 Go 原生编译（不是 TinyGo）
- 编译目标是 `GOOS=wasip1 GOARCH=wasm`
- 输出文件名是 `plugin.wasm`（不是 `redis-rq-counter.wasm`）

## 高级测试

### 测试不同的计数器

修改 `envoy.yaml` 中的配置：

```yaml
value: |
  {
    "redis": {
      "service_name": "redis",
      "service_port": 6379,
      "timeout": 2000
    },
    "counter_key": "api-v1"  # 修改这里使用不同的计数器
  }
```

重启服务后，计数器将使用不同的 Redis key：`higress-redis-rq-counter:api-v1`

```bash
# 修改配置后重启
docker-compose restart envoy

# 测试新计数器
curl -i http://localhost:10000/get

# 查看 Redis 中的多个计数器
docker exec redis-server redis-cli KEYS "higress-redis-rq-counter:*"
```

### 并发测试

测试插件在高并发场景下的正确性：

```bash
# 先重置计数器
docker exec redis-server redis-cli DEL higress-redis-rq-counter:test-counter

# 使用 Apache Bench 测试（如果已安装）
ab -n 1000 -c 50 http://localhost:10000/get

# 查看最终计数，应该正好是 1000
docker exec redis-server redis-cli GET higress-redis-rq-counter:test-counter

# 或使用 curl 循环测试
for i in {1..100}; do
  curl -s http://localhost:10000/get > /dev/null &
done
wait

# 检查计数是否正确
docker exec redis-server redis-cli GET higress-redis-rq-counter:test-counter
# 应该是 100
```

### 性能测试

使用 wrk 进行压力测试（如果已安装）：

```bash
# 安装 wrk (macOS)
brew install wrk

# 运行性能测试
wrk -t4 -c100 -d30s --latency http://localhost:10000/get

# 测试期间观察 Envoy 统计信息
watch -n 1 'curl -s http://localhost:9901/stats | grep -E "redis|wasm"'

# 查看 Envoy Admin 的统计数据
curl http://localhost:9901/stats | grep -E "redis.*incr"
```

### Redis 认证测试

如果需要测试 Redis 认证功能：

```bash
# 1. 修改 docker-compose.yaml 中的 Redis 配置
# 添加密码参数：
#   command: redis-server --requirepass mypassword --appendonly yes

# 2. 修改 envoy.yaml 中的配置
# 添加密码：
#   "redis": {
#     "service_name": "redis",
#     "service_port": 6379,
#     "password": "mypassword",
#     "timeout": 2000
#   }

# 3. 重启服务
docker-compose down
make run

# 4. 测试
curl -i http://localhost:10000/get
```

### 监控和调试

查看详细的 WASM 调试日志：

```bash
# 查看 WASM 日志
docker-compose logs envoy | grep -i "wasm\|redis-rq-counter"

# 查看具体的计数信息
docker-compose logs envoy | grep "current request count"

# 实时监控日志
docker-compose logs -f envoy
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

### 插件配置参数（envoy.yaml）

插件在 `envoy.yaml` 中的配置示例：

```yaml
configuration:
  "@type": type.googleapis.com/google.protobuf.StringValue
  value: |
    {
      "redis": {
        "service_name": "redis",            # Redis 服务名称（对应 cluster 名称）
        "service_port": 6379,               # Redis 端口
        "username": "",                     # 可选：Redis 用户名（ACL 认证）
        "password": "",                     # 可选：Redis 密码
        "timeout": 2000,                    # 超时时间（毫秒），默认 1000
        "database": 0                       # Redis 数据库编号，默认 0
      },
      "counter_key": "test-counter"         # 计数器名称，默认 "global"
    }
```

**配置参数详解：**

| 参数 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| `redis.service_name` | string | 是 | - | Redis 服务的 cluster 名称 |
| `redis.service_port` | int | 否 | 6379 | Redis 服务端口 |
| `redis.username` | string | 否 | "" | Redis ACL 用户名 |
| `redis.password` | string | 否 | "" | Redis 密码 |
| `redis.timeout` | int | 否 | 1000 | Redis 操作超时时间（毫秒） |
| `redis.database` | int | 否 | 0 | Redis 数据库编号（0-15） |
| `counter_key` | string | 否 | "global" | 计数器名称，支持多个计数器 |

### Envoy Cluster 配置

Redis 服务需要在 `clusters` 中定义：

```yaml
clusters:
  - name: redis                         # 必须与 service_name 匹配
    connect_timeout: 5s
    type: STRICT_DNS                    # 使用 DNS 解析
    dns_lookup_family: V4_ONLY          # 仅使用 IPv4
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: redis
      endpoints:
        - lb_endpoints:
            - endpoint:
                address:
                  socket_address:
                    address: redis      # Docker Compose 中的服务名
                    port_value: 6379
```

**注意事项：**
- `cluster.name` 必须与配置中的 `service_name` 匹配
- 在 Docker Compose 环境中，使用服务名（如 `redis`）作为地址
- 如果使用静态 IP，将 `type` 改为 `STATIC` 并使用 IP 地址

### Docker Compose 配置

当前的 `docker-compose.yaml` 配置了三个服务：

```yaml
services:
  redis:
    image: redis:7-alpine
    ports: ["6379:6379"]
    command: redis-server --appendonly yes  # 启用持久化

  httpbin:
    image: kennethreitz/httpbin
    ports: ["8080:80"]

  envoy:
    image: higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/gateway:v2.1.5
    command: -c /etc/envoy/envoy.yaml --component-log-level wasm:debug -l info
    ports: ["10000:10000", "9901:9901"]
    volumes:
      - ./envoy.yaml:/etc/envoy/envoy.yaml
      - ./plugin.wasm:/etc/envoy/plugin.wasm
```

**端口说明：**
- **6379**: Redis 服务端口
- **8080**: httpbin 测试服务端口
- **10000**: Envoy HTTP 代理端口（对外服务）
- **9901**: Envoy Admin 管理端口（用于监控和调试）

## 代码实现说明

### 核心常量（main.go:28-39）

```go
const (
    RedisKeyPrefix     = "higress-redis-rq-counter"  // Redis key 前缀
    CounterKeyFormat   = RedisKeyPrefix + ":%s"      // key 格式模板
    CounterContextKey  = "CounterValue"              // 上下文键名
    DefaultCounterKey  = "global"                    // 默认计数器名
    ResponseHeaderName = "X-Request-Count"           // 响应头名称
)
```

### 工作流程

插件的工作流程分为两个阶段：

**1. 请求阶段（onHttpRequestHeaders, main.go:98-131）**
- 禁用路由重定向（`DisableReroute`）
- 构造 Redis key：`higress-redis-rq-counter:{counter_key}`
- 调用 Redis INCR 命令原子性递增计数器
- 将计数值保存到上下文中
- 返回 `HeaderStopAllIterationAndWatermark` 等待 Redis 响应
- 收到 Redis 响应后调用 `ResumeHttpRequest()` 继续处理

**2. 响应阶段（onHttpResponseHeaders, main.go:133-148）**
- 从上下文中获取计数值
- 在响应头中添加 `X-Request-Count: {count}`
- 返回 `ActionContinue` 继续处理

### Redis 客户端初始化（main.go:63-96）

使用 `wrapper.NewRedisClusterClient` 创建 Redis 客户端：
- 支持服务名解析（FQDN）
- 支持用户名/密码认证
- 支持超时配置（默认 1000ms）
- 支持多数据库选择（默认 db0）

### 异步非阻塞处理

插件使用异步回调处理 Redis 响应：
```go
cfg.RedisClient.Incr(redisKey, func(response resp.Value) {
    // 处理 Redis 响应
    currentCount := response.Integer()
    ctx.SetContext(CounterContextKey, currentCount)
    proxywasm.ResumeHttpRequest()
})
return types.HeaderStopAllIterationAndWatermark  // 暂停请求处理
```

这种设计避免阻塞 Envoy 的工作线程，提供更好的性能。

### 依赖库

主要依赖库（go.mod）：
- `github.com/higress-group/proxy-wasm-go-sdk` - Proxy-Wasm Go SDK
- `github.com/higress-group/wasm-go` - Higress WASM 工具包
- `github.com/tidwall/gjson` - JSON 解析
- `github.com/tidwall/resp` - Redis 协议解析

## 参考资料

- [Higress 文档](https://higress.io/docs/)
- [Envoy Proxy 文档](https://www.envoyproxy.io/docs/envoy/latest/)
- [Proxy-Wasm 规范](https://github.com/proxy-wasm/spec)
- [Go WebAssembly 文档](https://go.dev/wiki/WebAssembly)
- [Redis 命令参考](https://redis.io/commands/)
- [Redis INCR 命令](https://redis.io/commands/incr/)

