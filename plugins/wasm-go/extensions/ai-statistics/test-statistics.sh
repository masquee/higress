#!/bin/bash

# AI Statistics 插件测试脚本

set -e

ENVOY_URL="http://localhost:10000"

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 打印带颜色的信息
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# 检查服务是否运行
check_services() {
    print_info "检查服务状态..."

    if ! docker ps | grep -q "envoy-gateway"; then
        print_error "Envoy 服务未运行"
        exit 1
    fi

    if ! docker ps | grep -q "httpbin-service"; then
        print_error "Httpbin 服务未运行"
        exit 1
    fi

    print_success "所有服务运行正常"
}

# 测试1: 非流式请求统计
test_non_streaming_statistics() {
    print_info "=========================================="
    print_info "测试1: 非流式请求的 AI 统计"
    print_info "=========================================="

    response=$(curl -s -i "${ENVOY_URL}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -H "x-mse-consumer: test-user-1" \
        -d '{
            "model": "gpt-3",
            "messages": [
                {"role": "user", "content": "你好，请介绍一下你自己"}
            ],
            "stream": false
        }')

    http_code=$(echo "$response" | head -n 1 | grep -o '[0-9]\{3\}')

    if [ "$http_code" = "200" ]; then
        print_success "请求成功: HTTP $http_code"

        # 提取响应体中的 token 信息
        body=$(echo "$response" | sed '1,/^$/d')
        model=$(echo "$body" | grep -o '"model":"[^"]*"' | cut -d'"' -f4 || echo "N/A")
        input_tokens=$(echo "$body" | grep -o '"prompt_tokens":[0-9]*' | cut -d':' -f2 || echo "N/A")
        output_tokens=$(echo "$body" | grep -o '"completion_tokens":[0-9]*' | cut -d':' -f2 || echo "N/A")
        total_tokens=$(echo "$body" | grep -o '"total_tokens":[0-9]*' | cut -d':' -f2 || echo "N/A")

        print_info "模型: $model"
        print_info "输入 tokens: $input_tokens"
        print_info "输出 tokens: $output_tokens"
        print_info "总计 tokens: $total_tokens"
    else
        print_error "请求失败: HTTP $http_code"
        echo "$response"
    fi
    echo ""
}

# 测试2: 流式请求统计
test_streaming_statistics() {
    print_info "=========================================="
    print_info "测试2: 流式请求的 AI 统计"
    print_info "=========================================="

    response=$(curl -s -N "${ENVOY_URL}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -H "x-mse-consumer: test-user-2" \
        -d '{
            "model": "gpt-4",
            "messages": [
                {"role": "user", "content": "讲一个笑话"}
            ],
            "stream": true
        }')

    # 检查是否是 SSE 格式
    if echo "$response" | grep -q "data:"; then
        print_success "流式响应正常"

        # 计算接收到的数据块数量
        chunk_count=$(echo "$response" | grep -c "^data:" || echo "0")
        print_info "接收到 $chunk_count 个数据块"

        # 尝试提取最后的 usage 信息
        usage_line=$(echo "$response" | grep "usage" | tail -1)
        if [ -n "$usage_line" ]; then
            print_info "Token 使用信息已包含在响应中"
        fi
    else
        print_warning "响应格式不是预期的 SSE 格式"
    fi
    echo ""
}

# 测试3: 查看 Envoy 访问日志
test_access_logs() {
    print_info "=========================================="
    print_info "测试3: 查看 Envoy 访问日志"
    print_info "=========================================="

    print_info "最近的访问日志（包含 AI 统计信息）："

    # 获取最近 5 条包含 ai_log 的日志
    docker logs envoy-gateway 2>&1 | grep "ai_log" | tail -5 | while read line; do
        echo "$line" | jq -C '.' 2>/dev/null || echo "$line"
    done

    echo ""
}

# 测试4: 查看 Prometheus Metrics
test_prometheus_metrics() {
    print_info "=========================================="
    print_info "测试4: 查看 Prometheus Metrics"
    print_info "=========================================="

    metrics=$(curl -s "http://localhost:9901/stats/prometheus" | grep "route_upstream_model_consumer_metric")

    if [ -n "$metrics" ]; then
        print_success "找到 AI 统计相关 metrics:"
        echo ""

        # 按指标类型分组显示
        echo "📊 输入 Token 统计:"
        echo "$metrics" | grep "input_token" | head -3
        echo ""

        echo "📊 输出 Token 统计:"
        echo "$metrics" | grep "output_token" | head -3
        echo ""

        echo "📊 服务响应时间统计:"
        echo "$metrics" | grep "llm_service_duration" | head -3
        echo ""

        echo "📊 首个 Token 延时统计 (流式):"
        echo "$metrics" | grep "llm_first_token_duration" | head -3
        echo ""

        echo "📊 请求计数统计:"
        echo "$metrics" | grep "llm_duration_count" | head -3
        echo ""
    else
        print_warning "未找到 AI 统计相关 metrics（可能还没有产生请求）"
    fi
    echo ""
}

# 测试5: 自定义 Consumer 统计
test_consumer_statistics() {
    print_info "=========================================="
    print_info "测试5: 不同 Consumer 的独立统计"
    print_info "=========================================="

    # Consumer 1 发送 2 次请求
    print_info "Consumer test-user-1 发送 2 次请求..."
    for i in {1..2}; do
        curl -s "${ENVOY_URL}/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -H "x-mse-consumer: test-user-1" \
            -d '{
                "model": "gpt-3",
                "messages": [{"role": "user", "content": "hello"}],
                "stream": false
            }' > /dev/null
        sleep 0.5
    done

    # Consumer 2 发送 3 次请求
    print_info "Consumer test-user-2 发送 3 次请求..."
    for i in {1..3}; do
        curl -s "${ENVOY_URL}/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -H "x-mse-consumer: test-user-2" \
            -d '{
                "model": "gpt-4",
                "messages": [{"role": "user", "content": "hi"}],
                "stream": false
            }' > /dev/null
        sleep 0.5
    done

    print_success "请求发送完成"

    # 等待日志输出
    sleep 2

    print_info "查看不同 Consumer 的日志记录:"
    docker logs envoy-gateway 2>&1 | grep "ai_log" | grep -E "test-user-1|test-user-2" | tail -5 | while read line; do
        consumer=$(echo "$line" | jq -r '.consumer' 2>/dev/null || echo "unknown")
        model=$(echo "$line" | jq -r '.model' 2>/dev/null || echo "unknown")
        print_info "Consumer: $consumer, Model: $model"
    done
    echo ""
}

# 测试6: 提取问题和答案
test_question_answer_extraction() {
    print_info "=========================================="
    print_info "测试6: 问题和答案提取"
    print_info "=========================================="

    question="人工智能的未来发展趋势是什么?"

    curl -s "${ENVOY_URL}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -H "x-mse-consumer: qa-tester" \
        -d "{
            \"model\": \"gpt-3\",
            \"messages\": [{\"role\": \"user\", \"content\": \"$question\"}],
            \"stream\": true
        }" > /dev/null

    sleep 3

    print_info "查看最新的问答日志:"
    latest_log=$(docker logs envoy-gateway 2>&1 | grep "ai_log" | tail -1)

    if [ -n "$latest_log" ]; then
        echo "$latest_log" | jq -C '{
            question: .question,
            answer: .answer,
            input_token: .input_token,
            output_token: .output_token
        }' 2>/dev/null || echo "$latest_log"
    else
        print_warning "未找到相关日志"
    fi
    echo ""
}

# 主函数
main() {
    echo ""
    print_info "开始 AI Statistics 插件测试"
    echo ""

    check_services
    echo ""

    # 运行测试
    test_non_streaming_statistics
    test_streaming_statistics
    test_consumer_statistics
    test_question_answer_extraction
    test_access_logs
    test_prometheus_metrics

    print_info "=========================================="
    print_success "所有测试完成！"
    print_info "=========================================="
    echo ""
    print_info "提示："
    print_info "1. 访问 http://localhost:9901/stats/prometheus 查看所有 metrics"
    print_info "2. 使用 'docker logs -f envoy-gateway' 实时查看日志"
    print_info "3. 日志中的 ai_log 字段包含了详细的统计信息"
}

# 运行主函数
main
