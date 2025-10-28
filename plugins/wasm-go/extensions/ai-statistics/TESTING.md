# AI Statistics 插件测试指南

## 插件功能

AI Statistics 插件提供 AI 服务的**全方位可观测能力**，包括 Metrics、Logs 和 Traces，帮助监控和分析 AI 服务的使用情况。

**核心特性:**
- **Metrics 指标**: 输入/输出 token 数量、首 token 延时、总响应时间等
- **日志增强**: 在访问日志中记录 model、token usage、问题/答案等信息
- **链路追踪**: 在 Trace Span 中添加 AI 相关属性
- **灵活配置**: 支持从请求/响应的 header、body、streaming body 中提取任意字段
- **多维度观测**: 支持按路由、集群、模型、Consumer 四个维度进行统计
- **流式响应支持**: 支持从 SSE 流式响应中提取信息

## 环境要求

- **Go**: 1.24.1 或更高版本（用于编译 WASM）
- **Docker**: 用于运行 Envoy 和 httpbin
- **Docker Compose**: 用于编排容器
- **AI 服务 API Key**: 需要配置 Qwen API Token（或其他 AI 服务）

## 前置依赖

**重要**: 本插件需要配合 `ai-proxy` 插件使用。在启动前需要先编译 ai-proxy 插件。

```bash
# 1. 编译 ai-proxy 插件
cd ../ai-proxy
make build

# 2. 返回 ai-statistics 目录
cd ../ai-statistics
```

## 快速开始

### 1. 配置 AI 服务 API Key

编辑 `envoy.yaml` 文件，替换 Qwen API Token：

```yaml
# 找到 ai-proxy 插件配置部分（第 140 行左右）
"apiTokens": [
  "sk-your-qwen-api-token-here"  # 替换为你的真实 API Token
]
```

**获取 API Key**:
- Qwen (通义千问): https://dashscope.console.aliyun.com/
- OpenAI: https://platform.openai.com/api-keys
- Claude: https://console.anthropic.com/

### 2. 一键编译并启动（推荐）

```bash
# 编译 WASM 插件并启动所有服务
make run
```

该命令会：
1. 编译 ai-statistics 插件（plugin.wasm）
2. 启动 Envoy 网关（端口 10000 和 9901）
3. 启动 httpbin 测试服务（端口 8080）
4. 加载 ai-proxy 和 ai-statistics 两个插件

### 3. 分步操作（可选）

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

### 4. 查看服务日志

```bash
# 查看所有服务日志
docker-compose logs -f

# 只查看 Envoy 日志（包含 WASM 和访问日志）
docker-compose logs -f envoy

# 实时查看包含 AI 统计的访问日志
docker-compose logs -f envoy | grep ai_log

# 查看 httpbin 日志
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

# 检查 Envoy Admin 接口
curl http://localhost:9901/ready
# 应该返回: LIVE

# 查看 Envoy 配置
curl http://localhost:9901/config_dump | jq '.configs[2].dynamic_listeners'
```

### 2. 使用自动化测试脚本（推荐）

我们提供了一个自动化测试脚本，可以快速验证插件的各项功能：

```bash
# 运行自动化测试
./test-statistics.sh
```

该脚本会测试：
- ✅ 非流式请求的 AI 统计
- ✅ 流式请求的 AI 统计
- ✅ 不同 Consumer 的独立统计
- ✅ 问题和答案提取
- ✅ Envoy 访问日志
- ✅ Prometheus Metrics

### 3. 手动测试各种场景

#### 测试 1: 非流式请求统计

```bash
curl -i http://localhost:10000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-mse-consumer: alice" \
  -d '{
    "model": "gpt-3",
    "messages": [
      {"role": "user", "content": "你好，请介绍一下你自己"}
    ],
    "stream": false
  }'
```

**观察响应**:
- 状态码应该是 200
- 响应 body 包含 `usage` 字段，其中有 `prompt_tokens` 和 `completion_tokens`

**查看日志**:
```bash
# 查看包含此请求统计信息的访问日志
docker logs envoy-gateway 2>&1 | grep ai_log | tail -1 | jq .

# 预期输出类似:
{
  "ai_log": "{\"model\":\"qwen-turbo\",\"input_token\":\"15\",\"output_token\":\"42\",\"llm_service_duration\":\"1250\"}",
  "consumer": "alice",
  "model": "qwen-turbo",
  "input_token": "15",
  "output_token": "42",
  "question": "你好，请介绍一下你自己"
}
```

#### 测试 2: 流式请求统计

```bash
curl -N http://localhost:10000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-mse-consumer: bob" \
  -d '{
    "model": "gpt-4",
    "messages": [
      {"role": "user", "content": "讲一个笑话"}
    ],
    "stream": true
  }'
```

**观察响应**:
- 应该看到 SSE 格式的流式输出
- 每行以 `data:` 开头
- 最后一行是 `data: [DONE]`

**查看日志**:
```bash
# 查看包含流式请求统计的日志
docker logs envoy-gateway 2>&1 | grep ai_log | tail -1 | jq .

# 预期输出包含:
{
  "ai_log": "{\"model\":\"qwen-max\",\"input_token\":\"8\",\"output_token\":\"56\",\"llm_first_token_duration\":\"320\",\"llm_service_duration\":\"2150\"}",
  "answer": "为什么程序员总是...",  # 完整的答案内容
  "llm_first_token_duration": "320"  # 首个 token 的延时（毫秒）
}
```

#### 测试 3: 查看 Prometheus Metrics

```bash
# 访问 Prometheus metrics 端点
curl http://localhost:9901/stats/prometheus | grep route_upstream_model_consumer_metric

# 或者在浏览器中打开
open http://localhost:9901/stats/prometheus
```

**关键 Metrics 说明**:

```
# 输入 token 总数（counter）
route_upstream_model_consumer_metric_input_token{
  ai_route="local_route",
  ai_cluster="qwen",
  ai_model="qwen-turbo",
  ai_consumer="alice"
} 150

# 输出 token 总数（counter）
route_upstream_model_consumer_metric_output_token{
  ai_route="local_route",
  ai_cluster="qwen",
  ai_model="qwen-turbo",
  ai_consumer="alice"
} 420

# AI 服务总响应时间，单位毫秒（counter）
route_upstream_model_consumer_metric_llm_service_duration{
  ai_route="local_route",
  ai_cluster="qwen",
  ai_model="qwen-turbo",
  ai_consumer="alice"
} 12500

# 请求总次数（counter）
route_upstream_model_consumer_metric_llm_duration_count{
  ai_route="local_route",
  ai_cluster="qwen",
  ai_model="qwen-turbo",
  ai_consumer="alice"
} 10

# 流式请求首 token 延时，单位毫秒（counter）
route_upstream_model_consumer_metric_llm_first_token_duration{
  ai_route="local_route",
  ai_cluster="qwen",
  ai_model="qwen-turbo",
  ai_consumer="alice"
} 3200

# 流式请求次数（counter）
route_upstream_model_consumer_metric_llm_stream_duration_count{
  ai_route="local_route",
  ai_cluster="qwen",
  ai_model="qwen-turbo",
  ai_consumer="alice"
} 8
```

**使用 Metrics 计算平均值**:

```promql
# 流式请求首 token 的平均延时（毫秒）
irate(route_upstream_model_consumer_metric_llm_first_token_duration[2m])
/
irate(route_upstream_model_consumer_metric_llm_stream_duration_count[2m])

# 所有请求的平均响应时间（毫秒）
irate(route_upstream_model_consumer_metric_llm_service_duration[2m])
/
irate(route_upstream_model_consumer_metric_llm_duration_count[2m])

# 平均每次请求的输入 token 数
irate(route_upstream_model_consumer_metric_input_token[2m])
/
irate(route_upstream_model_consumer_metric_llm_duration_count[2m])

# 平均每次请求的输出 token 数
irate(route_upstream_model_consumer_metric_output_token[2m])
/
irate(route_upstream_model_consumer_metric_llm_duration_count[2m])
```

#### 测试 4: 不同 Consumer 的独立统计

```bash
# Consumer alice 发送 3 次请求
for i in {1..3}; do
  echo "Alice 请求 $i:"
  curl -s http://localhost:10000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -H "x-mse-consumer: alice" \
    -d '{
      "model": "gpt-3",
      "messages": [{"role": "user", "content": "hello"}]
    }' | jq '.usage'
  sleep 1
done

# Consumer bob 发送 2 次请求
for i in {1..2}; do
  echo "Bob 请求 $i:"
  curl -s http://localhost:10000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -H "x-mse-consumer: bob" \
    -d '{
      "model": "gpt-4",
      "messages": [{"role": "user", "content": "hi"}]
    }' | jq '.usage'
  sleep 1
done

# 查看每个 Consumer 的统计
curl -s http://localhost:9901/stats/prometheus | \
  grep route_upstream_model_consumer_metric_input_token | \
  grep -E "alice|bob"

# 应该看到 alice 和 bob 的独立计数
```

#### 测试 5: 问题和答案提取

```bash
# 发送一个问题
curl http://localhost:10000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-3",
    "messages": [
      {"role": "user", "content": "人工智能的未来发展趋势是什么?"}
    ],
    "stream": true
  }' > /dev/null

# 等待响应完成
sleep 3

# 查看日志中提取的问题和答案
docker logs envoy-gateway 2>&1 | grep ai_log | tail -1 | jq '{
  question: .question,
  answer: .answer,
  model: .model,
  input_token: .input_token,
  output_token: .output_token
}'

# 预期输出:
{
  "question": "人工智能的未来发展趋势是什么?",
  "answer": "人工智能的未来发展趋势包括...",
  "model": "qwen-turbo",
  "input_token": "18",
  "output_token": "156"
}
```

## 预期结果

### 访问日志格式

当配置了 `as_separate_log_field: true` 时，日志字段会被单独提取：

```json
{
  "timestamp": "2024-10-28T12:00:00.000Z",
  "protocol": "HTTP/1.1",
  "method": "POST",
  "path": "/v1/chat/completions",
  "response_code": 200,
  "duration": 1250,
  "bytes_sent": 1024,
  "bytes_received": 512,
  "ai_log": "{\"model\":\"qwen-turbo\",\"input_token\":\"15\",\"output_token\":\"42\",\"llm_service_duration\":\"1250\"}",
  "consumer": "alice",
  "model": "qwen-turbo",
  "input_token": "15",
  "output_token": "42",
  "question": "你好，请介绍一下你自己",
  "answer": "你好！我是通义千问，由阿里云开发的..."
}
```

### Metrics 维度

所有 metrics 都包含以下标签维度：

| 标签 | 说明 | 示例值 |
|------|------|--------|
| `ai_route` | 路由名称 | `local_route` |
| `ai_cluster` | 上游集群名称 | `qwen` |
| `ai_model` | AI 模型名称 | `qwen-turbo` |
| `ai_consumer` | Consumer 名称 | `alice` 或 `none` |

## 故障排查

### 问题 1: 日志中没有 ai_log 字段

**可能原因:**
- 请求路径不在 `enable_path_suffixes` 配置中
- WASM 插件未正确加载

**排查步骤:**
```bash
# 1. 检查插件是否加载
docker logs envoy-gateway 2>&1 | grep -i "ai-statistics"

# 2. 检查请求路径
# 确保请求路径是 /v1/chat/completions

# 3. 查看 WASM debug 日志
docker logs envoy-gateway 2>&1 | grep wasm

# 4. 检查配置
curl http://localhost:9901/config_dump | jq '.configs[] | select(.wasm)'
```

### 问题 2: Metrics 没有数据

**可能原因:**
- 还没有发送过任何请求
- AI 服务返回了错误
- Metrics 端点访问错误

**排查步骤:**
```bash
# 1. 确认已发送请求
curl http://localhost:10000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-3","messages":[{"role":"user","content":"test"}]}'

# 2. 检查所有 stats
curl http://localhost:9901/stats | grep -i "route_upstream_model"

# 3. 检查是否有错误
docker logs envoy-gateway 2>&1 | grep -i error

# 4. 访问 Prometheus 格式的 metrics
curl http://localhost:9901/stats/prometheus | grep route_upstream_model_consumer_metric
```

### 问题 3: 流式响应中的 answer 字段为空

**可能原因:**
- 配置的 JSONPath 不正确
- 响应格式与预期不符
- `rule` 配置错误

**排查步骤:**
```bash
# 1. 检查流式响应的实际格式
curl -N http://localhost:10000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-3","messages":[{"role":"user","content":"test"}],"stream":true}' \
  | head -20

# 2. 查看 WASM 日志中的提取信息
docker logs envoy-gateway 2>&1 | grep "streaming body"

# 3. 验证配置的 value 路径
# 确保 "value": "choices.0.delta.content" 与实际响应格式匹配

# 4. 检查 rule 配置
# rule: "append" - 拼接所有块的内容
# rule: "replace" - 取最后一个非空值
# rule: "first" - 取第一个非空值
```

### 问题 4: ai-proxy 插件未加载

**可能原因:**
- ai-proxy.wasm 文件不存在
- Docker volume 挂载路径错误

**排查步骤:**
```bash
# 1. 检查 ai-proxy 插件文件是否存在
ls -lh ../ai-proxy/plugin.wasm

# 2. 如果不存在，编译 ai-proxy
cd ../ai-proxy
make build
cd ../ai-statistics

# 3. 重启服务
make clean
make run

# 4. 检查 Envoy 日志
docker logs envoy-gateway 2>&1 | grep -i "ai-proxy"
```

## 高级配置

### 配置 1: 提取自定义字段

```yaml
attributes:
  - key: request_id
    value_source: request_header
    value: x-request-id
    apply_to_log: true
    as_separate_log_field: true

  - key: user_ip
    value_source: request_header
    value: x-forwarded-for
    apply_to_log: true
    apply_to_span: true

  - key: temperature
    value_source: request_body
    value: temperature
    default_value: "0.7"
    apply_to_log: true
```

重启服务后测试：
```bash
docker-compose restart envoy

curl http://localhost:10000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-request-id: req-12345" \
  -H "x-forwarded-for: 192.168.1.100" \
  -d '{
    "model": "gpt-3",
    "messages": [{"role": "user", "content": "test"}],
    "temperature": 0.9
  }'

# 查看日志
docker logs envoy-gateway 2>&1 | grep ai_log | tail -1 | jq .
```

### 配置 2: 只监控特定路径

```yaml
enable_path_suffixes: [
  "/v1/chat/completions",
  "/v1/completions"
]
```

### 配置 3: 限制 value 长度

```yaml
value_length_limit: 1000  # 单个字段最大 1000 字符
```

### 配置 4: 非 OpenAI 协议支持

如果使用其他 AI 服务（非 OpenAI 兼容），需要手动配置 token 提取：

```yaml
disable_openai_usage: true
attributes:
  - key: model
    value_source: response_body
    value: usage.models.0.model_id
    apply_to_log: true

  - key: input_token
    value_source: response_body
    value: usage.models.0.input_tokens
    apply_to_log: true

  - key: output_token
    value_source: response_body
    value: usage.models.0.output_tokens
    apply_to_log: true
```

## 性能监控建议

### Grafana Dashboard 示例

使用以下 PromQL 查询构建 Grafana 仪表板：

**1. QPS (每秒请求数)**
```promql
sum(rate(route_upstream_model_consumer_metric_llm_duration_count{ai_model="qwen-turbo"}[1m]))
```

**2. 平均响应时间**
```promql
rate(route_upstream_model_consumer_metric_llm_service_duration{ai_model="qwen-turbo"}[1m])
/
rate(route_upstream_model_consumer_metric_llm_duration_count{ai_model="qwen-turbo"}[1m])
```

**3. Token 消耗趋势**
```promql
# 输入 token 速率
sum(rate(route_upstream_model_consumer_metric_input_token[1m])) by (ai_model)

# 输出 token 速率
sum(rate(route_upstream_model_consumer_metric_output_token[1m])) by (ai_model)
```

**4. 按 Consumer 分组的使用量**
```promql
sum(rate(route_upstream_model_consumer_metric_llm_duration_count[5m])) by (ai_consumer)
```

**5. 流式请求首 token 延时（P95）**
```promql
histogram_quantile(0.95,
  rate(route_upstream_model_consumer_metric_llm_first_token_duration[5m])
)
```

## 清理环境

```bash
# 使用 Makefile 清理（推荐）
make clean

# 或手动清理
docker-compose down

# 删除数据卷
docker-compose down -v

# 删除 WASM 文件
rm plugin.wasm
```

## 架构说明

### 插件协作关系

```
Client Request
     ↓
  Envoy
     ↓
[ai-statistics] ← 先执行，记录请求信息
     ↓
[ai-proxy] ← 后执行，转发到 AI 服务
     ↓
AI Service (Qwen/OpenAI/Claude)
     ↓
[ai-proxy] ← 处理响应
     ↓
[ai-statistics] ← 提取响应信息，记录统计
     ↓
Client Response
```

**执行顺序说明:**
1. **请求阶段**: ai-statistics → ai-proxy
2. **响应阶段**: ai-proxy → ai-statistics

**为什么 ai-statistics 优先级更高 (200 > 100)?**
- 需要在 ai-proxy 修改请求/响应之前捕获原始数据
- 确保能够准确提取和记录所有统计信息

### 数据流

```
┌─────────────┐
│   Request   │
└─────┬───────┘
      │
      ↓
┌─────────────────────────────────┐
│ ai-statistics                   │
│ - 提取 consumer, model, question│
│ - 记录请求开始时间              │
└─────────┬───────────────────────┘
          │
          ↓
┌─────────────────────────────────┐
│ ai-proxy                        │
│ - 协议转换                      │
│ - 模型映射                      │
│ - 添加认证                      │
└─────────┬───────────────────────┘
          │
          ↓
┌─────────────────────────────────┐
│ AI Service                      │
│ - 处理请求                      │
│ - 返回响应 + usage              │
└─────────┬───────────────────────┘
          │
          ↓
┌─────────────────────────────────┐
│ ai-proxy                        │
│ - 协议转换回 OpenAI 格式        │
└─────────┬───────────────────────┘
          │
          ↓
┌─────────────────────────────────┐
│ ai-statistics                   │
│ - 提取 token usage, answer      │
│ - 计算延时                       │
│ - 写入日志和 metrics             │
│ - 添加 trace span 属性           │
└─────────┬───────────────────────┘
          │
          ↓
┌─────────────┐
│  Response   │
└─────────────┘
```

## 参考资料

- [AI Statistics 插件文档](./README.md)
- [Higress 官方文档](https://higress.io/docs/)
- [Envoy Metrics](https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/statistics)
- [Prometheus Query Examples](https://prometheus.io/docs/prometheus/latest/querying/examples/)
- [gjson Path Syntax](https://github.com/tidwall/gjson#path-syntax)
