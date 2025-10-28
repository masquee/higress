#!/bin/bash
# 测试脚本：快速验证 AI Token 限流功能

set -e

ENDPOINT="http://localhost:10000/v1/chat/completions"
API_KEY="${1:-test-key-1}"
NUM_REQUESTS="${2:-5}"

echo "========================================"
echo "AI Token RateLimit 测试脚本"
echo "========================================"
echo "API Key: ${API_KEY}"
echo "请求次数: ${NUM_REQUESTS}"
echo ""
echo "说明："
echo "  - test-key-1: 每分钟限制 50 tokens"
echo "  - test-key-2: 每分钟限制 100 tokens"
echo "  - 使用 Qwen AI 服务进行真实测试"
echo "========================================"
echo ""

# 清空 Redis 中的限流记录（可选）
read -p "是否清空 Redis 中的限流记录? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "清空 Redis 记录..."
    docker-compose exec -T redis redis-cli DEL "higress-token-ratelimit:test_limit_by_param_apikey:limit_by_param:60:apikey:${API_KEY}" > /dev/null 2>&1 || true
    echo "✓ Redis 记录已清空"
    echo ""
fi

# 发送多次请求
for i in $(seq 1 $NUM_REQUESTS); do
    echo "--- 请求 #${i} ---"

    # 发送请求并保存响应
    RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST "${ENDPOINT}?apikey=${API_KEY}" \
        -H "Content-Type: application/json" \
        -d '{
            "model": "qwen-turbo",
            "messages": [
                {"role": "user", "content": "你好"}
            ]
        }')

    # 提取 HTTP 状态码
    HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
    BODY=$(echo "$RESPONSE" | sed '/HTTP_CODE:/d')

    # 根据状态码显示结果
    if [ "$HTTP_CODE" = "200" ]; then
        # 提取 token 使用量
        TOTAL_TOKENS=$(echo "$BODY" | grep -o '"total_tokens":[0-9]*' | cut -d: -f2)
        PROMPT_TOKENS=$(echo "$BODY" | grep -o '"prompt_tokens":[0-9]*' | cut -d: -f2)
        COMPLETION_TOKENS=$(echo "$BODY" | grep -o '"completion_tokens":[0-9]*' | cut -d: -f2)

        echo "✓ 成功 (HTTP 200)"
        echo "  消耗 Token: ${TOTAL_TOKENS} (prompt: ${PROMPT_TOKENS}, completion: ${COMPLETION_TOKENS})"
    elif [ "$HTTP_CODE" = "429" ]; then
        echo "✗ 限流 (HTTP 429)"
        echo "  响应: $(echo "$BODY" | head -n 1)"

        # 查询 Redis 中的当前计数
        REDIS_COUNT=$(docker-compose exec -T redis redis-cli GET "higress-token-ratelimit:test_limit_by_param_apikey:limit_by_param:60:apikey:${API_KEY}" 2>/dev/null || echo "N/A")
        REDIS_TTL=$(docker-compose exec -T redis redis-cli TTL "higress-token-ratelimit:test_limit_by_param_apikey:limit_by_param:60:apikey:${API_KEY}" 2>/dev/null || echo "N/A")
        echo "  Redis 计数: ${REDIS_COUNT} (TTL: ${REDIS_TTL}s)"
    else
        echo "⚠ 异常 (HTTP ${HTTP_CODE})"
        echo "  响应: $(echo "$BODY" | head -n 1)"
    fi

    echo ""

    # 短暂延迟
    if [ $i -lt $NUM_REQUESTS ]; then
        sleep 0.5
    fi
done

# 显示 Redis 中的最终状态
echo "========================================"
echo "Redis 最终状态"
echo "========================================"
REDIS_COUNT=$(docker-compose exec -T redis redis-cli GET "higress-token-ratelimit:test_limit_by_param_apikey:limit_by_param:60:apikey:${API_KEY}" 2>/dev/null || echo "0")
REDIS_TTL=$(docker-compose exec -T redis redis-cli TTL "higress-token-ratelimit:test_limit_by_param_apikey:limit_by_param:60:apikey:${API_KEY}" 2>/dev/null || echo "-1")

echo "API Key: ${API_KEY}"
echo "累计消耗 Token: ${REDIS_COUNT}"
echo "限流重置时间: ${REDIS_TTL} 秒后"
echo ""
echo "提示: 等待 ${REDIS_TTL} 秒后限流将自动重置"
echo "========================================"
