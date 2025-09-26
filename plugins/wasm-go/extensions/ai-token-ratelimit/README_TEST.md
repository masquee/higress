# AI Token RateLimit 本地测试指南

本指南介绍如何在本地使用 Docker Compose 测试 ai-token-ratelimit 插件。

## 快速开始

### 1. 构建并启动测试环境

```bash
# 构建 WASM 插件并启动所有服务
make run
```

这将启动四个服务：
- **Envoy Gateway** (端口 10000, 9901) - 网关服务
- **Redis** (端口 6379) - 用于存储 token 计数
- **Mock AI** (端口 8080) - 模拟 AI 服务，返回包含 token usage 的响应
- **Httpbin** (端口 12345) - HTTP 测试服务

### 2. 测试 Token 限流功能

使用 Mock AI 服务测试真实的 token 限流（每次请求随机消耗 5-15 个 token）：

```bash
# 测试 test-key-1 (每分钟限制 50 tokens)
# 大约发送 4-6 次请求后会被限流
curl -X POST "http://localhost:10000/v1/chat/completions?apikey=test-key-1" \
  -H "Content-Type: application/json" \
  -d '{"model": "gpt-3.5-turbo", "messages": [{"role": "user", "content": "Hello"}]}'

# 测试 test-key-2 (每分钟限制 100 tokens)
# 大约发送 8-12 次请求后会被限流
curl -X POST "http://localhost:10000/v1/chat/completions?apikey=test-key-2" \
  -H "Content-Type: application/json" \
  -d '{"model": "gpt-3.5-turbo", "messages": [{"role": "user", "content": "Hello"}]}'

# 测试未配置的 key（不会限流）
curl -X POST "http://localhost:10000/v1/chat/completions?apikey=unknown-key" \
  -H "Content-Type: application/json" \
  -d '{"model": "gpt-3.5-turbo", "messages": [{"role": "user", "content": "Hello"}]}'
```

当触发限流时，你会看到 429 响应：

```json
{
  "error": "Too many tokens consumed. Please try again later."
}
```

并包含 `X-TokenRateLimit-Reset` 响应头，指示限流重置时间。

**便捷测试脚本**：

我们提供了一个自动化测试脚本，可以快速验证限流功能：

```bash
# 测试 test-key-1（默认发送 5 次请求）
./test-ratelimit.sh

# 测试 test-key-2（发送 5 次请求）
./test-ratelimit.sh test-key-2

# 测试 test-key-1（发送 10 次请求）
./test-ratelimit.sh test-key-1 10
```

脚本会自动显示每次请求的结果、消耗的 token 数量，以及触发限流后的 Redis 状态。

### 3. 查看日志和调试

```bash
# 查看 Envoy 日志（包含 WASM debug 日志）
docker-compose logs -f envoy

# 查看 Mock AI 服务日志（可以看到每次请求消耗的 token 数）
docker-compose logs -f mock-ai

# 查看 Redis 数据
docker-compose exec redis redis-cli
> KEYS higress-token-ratelimit:*
> GET higress-token-ratelimit:test_limit_by_param_apikey:limit_by_param:60:apikey:test-key-1
> TTL higress-token-ratelimit:test_limit_by_param_apikey:limit_by_param:60:apikey:test-key-1
```

Mock AI 服务日志示例：
```
[2025-10-24 10:30:15] Request processed - Tokens: 12 (prompt: 5, completion: 7)
[2025-10-24 10:30:16] Request processed - Tokens: 8 (prompt: 3, completion: 5)
```

### 4. 访问 Envoy 管理界面

```bash
# 在浏览器中打开
open http://localhost:9901
```

可以查看：
- `/stats` - 统计信息
- `/config_dump` - 配置信息
- `/clusters` - 集群状态

### 5. 停止测试环境

```bash
make clean
```

## 完整测试（含 ai-proxy 插件）

如果需要测试完整的 AI token 限流功能，需要：

1. **构建 ai-proxy 插件**：

```bash
cd ../ai-proxy
make build
cp plugin.wasm ../ai-token-ratelimit/ai-proxy.wasm
cd ../ai-token-ratelimit
```

2. **更新 docker-compose.yaml**，添加 ai-proxy.wasm 挂载：

```yaml
services:
  envoy:
    volumes:
      - ./envoy.yaml:/etc/envoy/envoy.yaml
      - ./plugin.wasm:/etc/envoy/plugin.wasm
      - ./ai-proxy.wasm:/etc/envoy/ai-proxy.wasm  # 添加这行
```

3. **使用完整配置文件**：

```bash
# 备份当前配置
cp envoy.yaml envoy-simple.yaml

# 使用完整配置（如果提供了 envoy-full.yaml）
# 或手动编辑 envoy.yaml 添加 ai-proxy 插件配置
```

4. **配置通义千问 API Token**：

编辑 `envoy.yaml`，找到 ai-proxy 配置，替换 `<YOUR_QWEN_API_TOKEN>` 为你的实际 token。

5. **测试 AI 请求**：

```bash
curl "http://localhost:10000/v1/chat/completions?apikey=test-key-1" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-3",
    "messages": [
      {
        "role": "user",
        "content": "你好，你是谁？"
      }
    ],
    "stream": false
  }'
```

## 配置说明

### 当前限流规则

在 `envoy.yaml` 中配置了基于 URL 参数 `apikey` 的限流：

- `test-key-1`: 每分钟 50 tokens（方便测试限流）
- `test-key-2`: 每分钟 100 tokens（方便测试限流）

Mock AI 服务每次请求随机返回 5-15 个 token 的消耗量，所以：
- 使用 `test-key-1` 大约 4-6 次请求后会被限流
- 使用 `test-key-2` 大约 8-12 次请求后会被限流

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
- 查看 Mock AI 服务是否返回 token usage：`curl http://localhost:8080/health`
- 确认使用正确的 endpoint：必须是 `/v1/chat/completions`，不是 `/anything`
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
