#!/bin/bash

# 集群限流插件测试脚本

set -e

ENVOY_URL="http://localhost:10000"
REDIS_CONTAINER="redis-server"

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

    if ! docker ps | grep -q "redis-server"; then
        print_error "Redis 服务未运行"
        exit 1
    fi

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

# 清理 Redis 数据
cleanup_redis() {
    print_info "清理 Redis 数据..."
    docker exec ${REDIS_CONTAINER} redis-cli FLUSHDB > /dev/null
    print_success "Redis 数据已清理"
}

# 测试1: 基于 URL 参数 apikey 的限流
test_param_ratelimit() {
    print_info "=========================================="
    print_info "测试1: 基于 URL 参数 apikey 的限流"
    print_info "限制: test-key-1 每分钟 5 次请求"
    print_info "=========================================="

    cleanup_redis

    # 发送 6 次请求，第 6 次应该被限流
    for i in {1..6}; do
        # 使用 -i 获取响应头，使用临时文件存储响应
        response=$(curl -s -i "${ENVOY_URL}/get?apikey=test-key-1")

        # 提取状态码
        http_code=$(echo "$response" | head -n 1 | grep -o '[0-9]\{3\}')

        # 提取响应头（注意响应头的名称是小写的）
        limit=$(echo "$response" | grep -i "^x-ratelimit-limit:" | awk '{print $2}' | tr -d '\r')
        remaining=$(echo "$response" | grep -i "^x-ratelimit-remaining:" | awk '{print $2}' | tr -d '\r')
        reset=$(echo "$response" | grep -i "^x-ratelimit-reset:" | awk '{print $2}' | tr -d '\r')

        if [ "$i" -le 5 ]; then
            if [ "$http_code" = "200" ]; then
                print_success "请求 $i: HTTP $http_code | Limit: $limit | Remaining: $remaining"
            else
                print_error "请求 $i: HTTP $http_code (期望 200)"
            fi
        else
            if [ "$http_code" = "429" ]; then
                print_success "请求 $i: HTTP $http_code (已触发限流) | Reset: ${reset}s ✓"
            else
                print_error "请求 $i: HTTP $http_code (期望 429)"
            fi
        fi

        sleep 0.2
    done

    # 查看 Redis 中的数据
    print_info "Redis 中的限流计数:"
    docker exec ${REDIS_CONTAINER} redis-cli KEYS "higress-cluster-key-rate-limit:*" | while read key; do
        if [ -n "$key" ]; then
            value=$(docker exec ${REDIS_CONTAINER} redis-cli GET "$key")
            ttl=$(docker exec ${REDIS_CONTAINER} redis-cli TTL "$key")
            echo "  $key = $value (TTL: ${ttl}s)"
        fi
    done
    echo ""
}

# 测试2: 基于请求头的限流
test_header_ratelimit() {
    print_info "=========================================="
    print_info "测试2: 基于请求头 x-api-key 的限流"
    print_info "限制: header-key-1 每秒 2 次请求"
    print_info "=========================================="

    cleanup_redis

    # 发送 3 次请求，第 3 次应该被限流
    for i in {1..3}; do
        response=$(curl -s -i -H "x-api-key: header-key-1" "${ENVOY_URL}/get")

        # 提取状态码和响应头
        http_code=$(echo "$response" | head -n 1 | grep -o '[0-9]\{3\}')
        limit=$(echo "$response" | grep -i "^x-ratelimit-limit:" | awk '{print $2}' | tr -d '\r')
        remaining=$(echo "$response" | grep -i "^x-ratelimit-remaining:" | awk '{print $2}' | tr -d '\r')
        reset=$(echo "$response" | grep -i "^x-ratelimit-reset:" | awk '{print $2}' | tr -d '\r')

        if [ "$i" -le 2 ]; then
            if [ "$http_code" = "200" ]; then
                print_success "请求 $i: HTTP $http_code | Limit: $limit | Remaining: $remaining"
            else
                print_error "请求 $i: HTTP $http_code (期望 200)"
            fi
        else
            if [ "$http_code" = "429" ]; then
                print_success "请求 $i: HTTP $http_code (已触发限流) | Reset: ${reset}s ✓"
            else
                print_error "请求 $i: HTTP $http_code (期望 429)"
            fi
        fi

        sleep 0.1
    done
    echo ""
}

# 测试3: 基于 per_param 的动态限流
test_per_param_ratelimit() {
    print_info "=========================================="
    print_info "测试3: 基于 per_param 的动态限流"
    print_info "限制: 每个不同的 user 参数值每分钟 20 次请求"
    print_info "=========================================="

    cleanup_redis

    # 测试不同的用户
    for user in "alice" "bob"; do
        print_info "测试用户: $user"
        for i in {1..3}; do
            response=$(curl -s -i "${ENVOY_URL}/get?user=$user")

            # 提取状态码和响应头
            http_code=$(echo "$response" | head -n 1 | grep -o '[0-9]\{3\}')
            limit=$(echo "$response" | grep -i "^x-ratelimit-limit:" | awk '{print $2}' | tr -d '\r')
            remaining=$(echo "$response" | grep -i "^x-ratelimit-remaining:" | awk '{print $2}' | tr -d '\r')

            if [ "$http_code" = "200" ]; then
                print_success "  请求 $i: HTTP $http_code | Limit: $limit | Remaining: $remaining"
            else
                print_error "  请求 $i: HTTP $http_code"
            fi
            sleep 0.2
        done
    done

    # 查看 Redis 中为每个用户创建的计数器
    print_info "Redis 中的用户限流计数:"
    docker exec ${REDIS_CONTAINER} redis-cli KEYS "higress-cluster-key-rate-limit:*user*" | while read key; do
        if [ -n "$key" ]; then
            value=$(docker exec ${REDIS_CONTAINER} redis-cli GET "$key")
            ttl=$(docker exec ${REDIS_CONTAINER} redis-cli TTL "$key")
            echo "  $key = $value (TTL: ${ttl}s)"
        fi
    done
    echo ""
}

# 测试4: 不同 API Key 的独立限流
test_multiple_keys() {
    print_info "=========================================="
    print_info "测试4: 不同 API Key 的独立限流"
    print_info "test-key-1: 5 次/分钟"
    print_info "test-key-2: 10 次/分钟"
    print_info "=========================================="

    cleanup_redis

    # 测试 test-key-1
    print_info "测试 test-key-1 (5次/分钟):"
    for i in {1..3}; do
        response=$(curl -s -i "${ENVOY_URL}/get?apikey=test-key-1")

        # 提取状态码和响应头
        http_code=$(echo "$response" | head -n 1 | grep -o '[0-9]\{3\}')
        limit=$(echo "$response" | grep -i "^x-ratelimit-limit:" | awk '{print $2}' | tr -d '\r')
        remaining=$(echo "$response" | grep -i "^x-ratelimit-remaining:" | awk '{print $2}' | tr -d '\r')

        print_success "  请求 $i: HTTP $http_code | Limit: $limit | Remaining: $remaining"
        sleep 0.2
    done

    # 测试 test-key-2
    print_info "测试 test-key-2 (10次/分钟):"
    for i in {1..3}; do
        response=$(curl -s -i "${ENVOY_URL}/get?apikey=test-key-2")

        # 提取状态码和响应头
        http_code=$(echo "$response" | head -n 1 | grep -o '[0-9]\{3\}')
        limit=$(echo "$response" | grep -i "^x-ratelimit-limit:" | awk '{print $2}' | tr -d '\r')
        remaining=$(echo "$response" | grep -i "^x-ratelimit-remaining:" | awk '{print $2}' | tr -d '\r')

        print_success "  请求 $i: HTTP $http_code | Limit: $limit | Remaining: $remaining"
        sleep 0.2
    done

    print_info "两个 API Key 的限流计数器应该是独立的:"
    docker exec ${REDIS_CONTAINER} redis-cli KEYS "higress-cluster-key-rate-limit:*apikey*" | while read key; do
        if [ -n "$key" ]; then
            value=$(docker exec ${REDIS_CONTAINER} redis-cli GET "$key")
            ttl=$(docker exec ${REDIS_CONTAINER} redis-cli TTL "$key")
            echo "  $key = $value (TTL: ${ttl}s)"
        fi
    done
    echo ""
}

# 主函数
main() {
    echo ""
    print_info "开始集群限流插件测试"
    echo ""

    check_services
    echo ""

    # 运行测试
    test_param_ratelimit
    test_header_ratelimit
    test_per_param_ratelimit
    test_multiple_keys

    print_info "=========================================="
    print_success "所有测试完成！"
    print_info "=========================================="
}

# 运行主函数
main
