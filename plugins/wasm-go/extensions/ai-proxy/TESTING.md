# AI Proxy 插件测试指南

## 插件功能

该插件实现了基于 OpenAI API 契约的 AI 代理功能,支持多种 AI 服务提供商的协议转换和代理。

**核心特性:**
- 支持多种 AI 服务提供商(OpenAI、通义千问、Claude、Gemini 等)
- 自动协议检测和转换(OpenAI ↔ Claude)
- 支持流式和非流式响应
- 支持模型名称映射
- 支持自定义参数覆盖
- 支持文本向量(Embeddings)接口
- 支持多模态(文本+图片)请求

## 环境要求

- **Go**: 1.24.1 或更高版本(用于编译 WASM)
- **Docker**: 用于运行 Envoy 和测试服务
- **Docker Compose**: 用于编排容器
- **AI 服务 API Key**: 测试所需的 AI 服务提供商 API 密钥

## 快速开始

### 1. 配置 API Key

在开始测试之前,需要配置你的 AI 服务提供商 API Key。编辑 `envoy.yaml` 文件:

```bash
# 编辑配置文件,替换 API Token
vim envoy.yaml

# 找到配置中的 apiTokens 字段,替换为你的真实 API Key:
# "apiTokens": [
#   "YOUR_REAL_API_KEY"  # 替换这里
# ]
```

**注意:** 默认配置使用通义千问(qwen)作为 AI 服务提供商,你可以根据需要修改为其他提供商。

### 2. 一键编译并启动(推荐)

```bash
cd /Users/zhongyuan/github/masquee/higress/plugins/wasm-go/extensions/ai-proxy

# 编译 WASM 插件并启动所有服务
make run
```

该命令会:
1. 编译 WASM 插件(plugin.wasm)
2. 启动 Envoy 网关(端口 10000、20000 和 9901)
3. 启动 httpbin 测试服务(端口 12345)

### 3. 分步操作(可选)

```bash
# 只编译 WASM 插件
make build

# 启动 Docker Compose 服务(后台运行)
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

# 只查看 Envoy 日志(包含 WASM 调试信息)
docker-compose logs -f envoy

# 只查看 httpbin 日志
docker-compose logs -f httpbin
```

## 编译说明

Makefile 使用以下配置编译 WASM 插件:

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

# 查看 Envoy 集群状态
curl http://localhost:9901/clusters | grep qwen
# 应该看到 qwen 集群的健康状态
```

### 2. 测试 AI 对话接口 (OpenAI 协议)

```bash
# 使用 OpenAI 协议发送聊天请求
curl -i http://localhost:10000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-3",
    "messages": [
      {
        "role": "user",
        "content": "你好,你是谁?"
      }
    ],
    "temperature": 0.3
  }'
```

### 3. 测试流式响应

```bash
# 测试流式输出
curl -i http://localhost:10000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-3",
    "messages": [
      {
        "role": "user",
        "content": "讲一个笑话"
      }
    ],
    "stream": true
  }'

# 观察响应会以 Server-Sent Events (SSE) 格式逐块返回
```

### 4. 测试模型映射

```bash
# 请求使用 gpt-4-turbo,会自动映射到 qwen-max
curl http://localhost:10000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4-turbo",
    "messages": [
      {
        "role": "user",
        "content": "介绍一下你自己"
      }
    ]
  }'

# 检查响应中的 model 字段,应该是 qwen-max
```

### 5. 测试文本向量接口

```bash
# 测试 embeddings 接口
curl http://localhost:10000/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{
    "model": "text-embedding-v1",
    "input": "Hello World"
  }'

# 应该返回向量数组
```

## 预期结果

### 正常响应示例 (非流式)

```bash
$ curl -i http://localhost:10000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-3",
    "messages": [{"role": "user", "content": "你好"}]
  }'

HTTP/1.1 200 OK
content-type: application/json
content-length: 342
date: Sun, 27 Oct 2024 10:00:00 GMT
server: envoy

{
  "id": "chatcmpl-123456",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "你好!我是通义千问,由阿里云开发的AI助手。有什么我可以帮助你的吗?"
      },
      "finish_reason": "stop"
    }
  ],
  "created": 1698400000,
  "model": "qwen-turbo",
  "object": "chat.completion",
  "usage": {
    "prompt_tokens": 10,
    "completion_tokens": 25,
    "total_tokens": 35
  }
}
```

### 流式响应示例

```bash
$ curl http://localhost:10000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "gpt-3", "messages": [{"role": "user", "content": "你好"}], "stream": true}'

data: {"id":"chatcmpl-123","choices":[{"index":0,"delta":{"role":"assistant","content":"你"},"finish_reason":null}]}

data: {"id":"chatcmpl-123","choices":[{"index":0,"delta":{"content":"好"},"finish_reason":null}]}

data: {"id":"chatcmpl-123","choices":[{"index":0,"delta":{"content":"!"},"finish_reason":null}]}

data: {"id":"chatcmpl-123","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

data: [DONE]
```

## 故障排查

### 问题 1: 请求返回 401 或 403 错误

**可能原因:**
- API Key 无效或未配置
- API Key 权限不足

**排查步骤:**
```bash
# 1. 检查 envoy.yaml 中的 API Key 配置
grep -A 5 "apiTokens" envoy.yaml

# 2. 查看 Envoy 日志中的认证错误
docker-compose logs envoy | grep -i "auth\|401\|403"

# 3. 尝试直接访问 AI 服务验证 API Key
# (以通义千问为例)
curl https://dashscope.aliyuncs.com/api/v1/services/aigc/text-generation/generation \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen-turbo","input":{"messages":[{"role":"user","content":"测试"}]}}'
```

### 问题 2: 请求超时或无响应

**可能原因:**
- AI 服务网络不可达
- 请求超时时间设置过短
- Envoy 未正确配置 DNS

**排查步骤:**
```bash
# 1. 检查 Envoy 容器是否能访问 AI 服务
docker-compose exec envoy ping -c 2 dashscope.aliyuncs.com

# 2. 检查 Envoy 日志中的网络错误
docker-compose logs envoy | grep -i "timeout\|connection\|dns"

# 3. 查看 Envoy stats 中的超时统计
curl http://localhost:9901/stats | grep -E "timeout|upstream_rq"

# 4. 增加 envoy.yaml 中的超时时间
# 找到 route.timeout 配置,默认是 300s
```

### 问题 3: WASM 插件加载失败

**可能原因:**
- WASM 文件编译失败或损坏
- Envoy 版本不兼容
- 配置语法错误

**排查步骤:**
```bash
# 1. 检查 WASM 文件是否存在
ls -lh plugin.wasm

# 2. 检查 Envoy 启动日志
docker-compose logs envoy | grep -i "wasm\|plugin"

# 3. 验证 WASM 文件格式
file plugin.wasm
# 应该显示: WebAssembly (wasm) binary module

# 4. 重新编译 WASM 插件
make build

# 5. 检查 envoy.yaml 语法
docker-compose config
```

### 问题 4: 协议转换错误

**可能原因:**
- 请求格式不符合 OpenAI 规范
- 模型映射配置错误
- AI 服务返回格式异常

**排查步骤:**
```bash
# 1. 查看详细的 WASM 日志
docker-compose logs envoy | grep "wasm"

# 2. 检查请求是否包含必需字段
# OpenAI 格式必需: model, messages
curl http://localhost:10000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "gpt-3", "messages": [{"role": "user", "content": "test"}]}' \
  -v

# 3. 验证模型映射配置
grep -A 10 "modelMapping" envoy.yaml
```

## 高级测试

### 测试不同的 AI 服务提供商

修改 `envoy.yaml` 中的配置以测试不同的提供商:

#### 测试 OpenAI

```yaml
value: |
  {
    "provider": {
      "type": "openai",
      "apiTokens": ["YOUR_OPENAI_API_KEY"]
    }
  }
```

同时修改 cluster 配置:
```yaml
clusters:
  - name: openai
    connect_timeout: 30s
    type: LOGICAL_DNS
    dns_lookup_family: V4_ONLY
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: openai
      endpoints:
        - lb_endpoints:
            - endpoint:
                address:
                  socket_address:
                    address: api.openai.com
                    port_value: 443
    transport_socket:
      name: envoy.transport_sockets.tls
      typed_config:
        "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext
        "sni": "api.openai.com"
```

#### 测试 Claude

```yaml
value: |
  {
    "provider": {
      "type": "claude",
      "apiTokens": ["YOUR_CLAUDE_API_KEY"],
      "claudeVersion": "2023-06-01"
    }
  }
```

修改 cluster 指向 api.anthropic.com:443

### 测试多模态请求 (图片+文本)

```bash
# 测试图片理解功能 (需要使用支持多模态的模型)
curl http://localhost:10000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4o",
    "messages": [
      {
        "role": "user",
        "content": [
          {
            "type": "text",
            "text": "这张图片是什么?"
          },
          {
            "type": "image_url",
            "image_url": {
              "url": "https://example.com/image.jpg"
            }
          }
        ]
      }
    ]
  }'
```

### 测试自定义参数覆盖

```yaml
# 在 envoy.yaml 中添加 customSettings
value: |
  {
    "provider": {
      "type": "qwen",
      "apiTokens": ["YOUR_API_KEY"],
      "customSettings": [
        {
          "name": "max_tokens",
          "value": 100,
          "overwrite": true
        },
        {
          "name": "temperature",
          "value": 0.7,
          "overwrite": false
        }
      ]
    }
  }
```

重启服务后测试:
```bash
docker-compose restart envoy

curl http://localhost:10000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-3",
    "messages": [{"role": "user", "content": "给我讲个长故事"}]
  }'

# 响应应该不超过 100 tokens (因为 customSettings 覆盖了默认值)
```

### 性能测试

使用 wrk 进行压力测试 (如果已安装):

```bash
# 安装 wrk (macOS)
brew install wrk

# 创建测试请求文件
cat > test-request.lua <<'EOF'
wrk.method = "POST"
wrk.body   = '{"model":"gpt-3","messages":[{"role":"user","content":"hello"}]}'
wrk.headers["Content-Type"] = "application/json"
EOF

# 运行性能测试
wrk -t4 -c100 -d30s --script=test-request.lua http://localhost:10000/v1/chat/completions

# 测试期间观察 Envoy 统计信息
watch -n 1 'curl -s http://localhost:9901/stats | grep -E "wasm|upstream"'
```

### 监控和调试

查看详细的 WASM 调试日志:

```bash
# 查看 WASM 日志
docker-compose logs envoy | grep -i "wasm"

# 查看协议转换日志
docker-compose logs envoy | grep "protocol\|convert"

# 实时监控日志
docker-compose logs -f envoy

# 查看 Envoy 内部状态
curl http://localhost:9901/stats/prometheus | grep wasm
```

## 清理环境

```bash
# 使用 Makefile 清理 (推荐)
make clean

# 或手动清理
docker-compose down

# 删除数据卷
docker-compose down -v

# 删除 WASM 文件
rm plugin.wasm
```

## 配置说明

### 插件配置参数 (envoy.yaml)

插件在 `envoy.yaml` 中的配置示例:

```yaml
configuration:
  "@type": "type.googleapis.com/google.protobuf.StringValue"
  value: |
    {
      "activeProviderId": "qwen",       # 当前激活的提供商 ID
      "providers": [
        {
          "id": "qwen",                 # 提供商唯一标识
          "type": "qwen",               # 提供商类型
          "domain": "dashscope.aliyuncs.com",  # API 域名
          "apiTokens": ["YOUR_API_KEY"], # API 密钥列表
          "timeout": 1200000,           # 超时时间 (毫秒)
          "qwenEnableCompatible": true, # 启用通义千问兼容模式
          "modelMapping": {              # 模型名称映射
            "gpt-3": "qwen-turbo",
            "gpt-4": "qwen-max",
            "*": "qwen-turbo"            # 默认映射
          }
        }
      ]
    }
```

**核心配置参数说明:**

| 参数 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| `activeProviderId` | string | 是 | - | 当前使用的提供商 ID |
| `providers[].type` | string | 是 | - | AI 服务提供商类型 (openai/qwen/claude 等) |
| `providers[].apiTokens` | array | 是 | - | API 密钥列表 |
| `providers[].timeout` | int | 否 | 120000 | 请求超时时间 (毫秒) |
| `providers[].modelMapping` | object | 否 | {} | 模型名称映射表 |

### Envoy Cluster 配置

AI 服务需要在 `clusters` 中定义:

```yaml
clusters:
  - name: qwen                          # 必须与路由配置匹配
    connect_timeout: 30s
    type: LOGICAL_DNS                   # 使用 DNS 解析
    dns_lookup_family: V4_ONLY          # 仅使用 IPv4
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: qwen
      endpoints:
        - lb_endpoints:
            - endpoint:
                address:
                  socket_address:
                    address: dashscope.aliyuncs.com  # AI 服务域名
                    port_value: 443
    transport_socket:                   # 启用 TLS
      name: envoy.transport_sockets.tls
      typed_config:
        "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext
        "sni": "dashscope.aliyuncs.com"
```

### Docker Compose 配置

当前的 `docker-compose.yaml` 配置了两个服务:

```yaml
services:
  envoy:
    image: higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/gateway:v2.1.5
    command: -c /etc/envoy/envoy.yaml --component-log-level wasm:debug
    ports: ["10000:10000", "20000:20000", "9901:9901"]
    volumes:
      - ./envoy.yaml:/etc/envoy/envoy.yaml
      - ./plugin.wasm:/etc/envoy/plugin.wasm

  httpbin:
    image: kennethreitz/httpbin:latest
    ports: ["12345:80"]
```

**端口说明:**
- **10000**: Envoy HTTP 代理端口 (AI API 接口)
- **20000**: Envoy 备用端口
- **9901**: Envoy Admin 管理端口 (用于监控和调试)
- **12345**: httpbin 测试服务端口

## 代码实现说明

### 工作流程

插件的工作流程如下:

**1. 请求处理阶段**
- 解析请求路径,判断 API 类型 (/v1/chat/completions 或 /v1/messages)
- 根据路径自动选择协议 (OpenAI 或 Claude)
- 应用模型映射规则
- 应用自定义参数覆盖
- 转换请求格式为目标提供商格式

**2. 响应处理阶段**
- 接收 AI 服务响应
- 转换响应格式为标准 OpenAI 格式
- 处理流式响应 (SSE 格式)
- 返回给客户端

### 协议转换

插件支持自动协议转换:

- **OpenAI → Qwen**: 转换 messages 格式和参数名称
- **OpenAI → Claude**: 转换 system message 和参数格式
- **Claude → OpenAI**: 如果目标不支持 Claude,自动转换为 OpenAI 格式

### 主要依赖库

主要依赖库 (go.mod):
- `github.com/higress-group/proxy-wasm-go-sdk` - Proxy-Wasm Go SDK
- `github.com/tidwall/gjson` - JSON 解析
- `github.com/tidwall/sjson` - JSON 修改

## 参考资料

- [Higress 文档](https://higress.io/docs/)
- [AI Proxy 插件文档](./README.md)
- [Envoy Proxy 文档](https://www.envoyproxy.io/docs/envoy/latest/)
- [Proxy-Wasm 规范](https://github.com/proxy-wasm/spec)
- [OpenAI API 文档](https://platform.openai.com/docs/api-reference)
- [通义千问 API 文档](https://help.aliyun.com/zh/dashscope/)
- [Claude API 文档](https://docs.anthropic.com/claude/reference/)
