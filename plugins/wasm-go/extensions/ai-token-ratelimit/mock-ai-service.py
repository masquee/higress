#!/usr/bin/env python3
"""
Mock AI Service - 模拟 AI API 响应，用于测试 ai-token-ratelimit 插件

返回符合 OpenAI API 格式的响应，包含 token usage 信息
"""

from http.server import HTTPServer, BaseHTTPRequestHandler
import json
import random
from datetime import datetime

class MockAIHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        # 读取请求体
        content_length = int(self.headers.get('Content-Length', 0))
        if content_length > 0:
            body = self.rfile.read(content_length)
            try:
                request_data = json.loads(body)
            except:
                request_data = {}
        else:
            request_data = {}

        # 模拟不同的 token 消耗（用于测试限流）
        # 每次请求随机消耗 5-15 个 token
        prompt_tokens = random.randint(3, 8)
        completion_tokens = random.randint(5, 10)
        total_tokens = prompt_tokens + completion_tokens

        # 构造符合 OpenAI API 格式的响应
        response = {
            "id": f"chatcmpl-mock-{datetime.now().timestamp()}",
            "object": "chat.completion",
            "created": int(datetime.now().timestamp()),
            "model": request_data.get("model", "gpt-3.5-turbo"),
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": f"This is a mock AI response. Your request consumed {total_tokens} tokens."
                    },
                    "finish_reason": "stop"
                }
            ],
            "usage": {
                "prompt_tokens": prompt_tokens,
                "completion_tokens": completion_tokens,
                "total_tokens": total_tokens
            }
        }

        # 返回响应
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(response, indent=2).encode('utf-8'))

        # 打印日志
        print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] "
              f"Request processed - Tokens: {total_tokens} "
              f"(prompt: {prompt_tokens}, completion: {completion_tokens})")

    def do_GET(self):
        # 健康检查端点
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({"status": "healthy"}).encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        # 禁用默认的访问日志，我们使用自定义日志
        pass

if __name__ == '__main__':
    port = 8080
    server = HTTPServer(('0.0.0.0', port), MockAIHandler)
    print(f"Mock AI Service starting on port {port}...")
    print(f"Each request will consume 5-15 random tokens for testing rate limiting")
    server.serve_forever()
