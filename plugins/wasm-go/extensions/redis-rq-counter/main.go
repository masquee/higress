package main

import (
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/higress-group/proxy-wasm-go-sdk/proxywasm"
	"github.com/higress-group/proxy-wasm-go-sdk/proxywasm/types"
	"github.com/higress-group/wasm-go/pkg/log"
	"github.com/higress-group/wasm-go/pkg/wrapper"
	"github.com/tidwall/gjson"
	"github.com/tidwall/resp"
)

func main() {}

func init() {
	wrapper.SetCtx(
		"redis-rq-counter",
		wrapper.ParseConfig(parseConfig),
		wrapper.ProcessRequestHeaders(onHttpRequestHeaders),
		wrapper.ProcessResponseHeaders(onHttpResponseHeaders),
	)
}

const (
	// RedisKeyPrefix Redis 中 key 的统一前缀
	RedisKeyPrefix = "higress-redis-rq-counter"
	// CounterKeyFormat Redis key 格式
	CounterKeyFormat = RedisKeyPrefix + ":%s"
	// CounterContextKey 上下文中存储计数值的 key
	CounterContextKey = "CounterValue"
	// DefaultCounterKey 默认的计数器名称
	DefaultCounterKey = "global"
	// ResponseHeaderName 响应头名称
	ResponseHeaderName = "X-Request-Count"
)

type RedisRqCounterConfig struct {
	CounterKey  string              // 计数器名称，可以配置多个不同的计数器
	RedisClient wrapper.RedisClient // Redis 客户端
}

func parseConfig(json gjson.Result, cfg *RedisRqCounterConfig) error {
	// 初始化 Redis 客户端
	err := initRedisClient(json, cfg)
	if err != nil {
		return err
	}

	// 获取计数器名称，默认为 "global"
	counterKey := json.Get("counter_key").String()
	if counterKey == "" {
		counterKey = DefaultCounterKey
	}
	cfg.CounterKey = counterKey

	return nil
}

func initRedisClient(json gjson.Result, config *RedisRqCounterConfig) error {
	redisConfig := json.Get("redis")
	if !redisConfig.Exists() {
		return errors.New("missing redis in config")
	}

	serviceName := redisConfig.Get("service_name").String()
	if serviceName == "" {
		return errors.New("redis service name must not be empty")
	}

	servicePort := int(redisConfig.Get("service_port").Int())
	if servicePort == 0 {
		if strings.HasSuffix(serviceName, ".static") {
			servicePort = 80
		} else {
			servicePort = 6379
		}
	}

	username := redisConfig.Get("username").String()
	password := redisConfig.Get("password").String()
	timeout := int(redisConfig.Get("timeout").Int())
	if timeout == 0 {
		timeout = 1000
	}

	config.RedisClient = wrapper.NewRedisClusterClient(wrapper.FQDNCluster{
		FQDN: serviceName,
		Port: int64(servicePort),
	})
	database := int(redisConfig.Get("database").Int())
	return config.RedisClient.Init(username, password, int64(timeout), wrapper.WithDataBase(database))
}

func onHttpRequestHeaders(ctx wrapper.HttpContext, cfg RedisRqCounterConfig) types.Action {
	// 禁用重新路由
	ctx.DisableReroute()

	// 构造 Redis key
	redisKey := fmt.Sprintf(CounterKeyFormat, cfg.CounterKey)

	// 使用 INCR 命令对计数器加一
	err := cfg.RedisClient.Incr(redisKey, func(response resp.Value) {
		if response.Error() != nil {
			log.Errorf("redis incr failed: %v", response.Error())
			proxywasm.ResumeHttpRequest()
			return
		}

		// 获取当前计数值
		currentCount := response.Integer()
		log.Infof("current request count: %d", currentCount)

		// 将计数值存储到上下文中，以便在响应阶段使用
		ctx.SetContext(CounterContextKey, currentCount)

		// 恢复请求处理
		proxywasm.ResumeHttpRequest()
	})

	if err != nil {
		log.Errorf("redis call failed: %v", err)
		return types.ActionContinue
	}

	// 等待 Redis 响应
	return types.HeaderStopAllIterationAndWatermark
}

func onHttpResponseHeaders(ctx wrapper.HttpContext, cfg RedisRqCounterConfig) types.Action {
	// 从上下文中获取计数值
	counterValue, ok := ctx.GetContext(CounterContextKey).(int)
	if !ok {
		// 如果获取不到计数值，直接返回
		return types.ActionContinue
	}

	// 在响应头中添加计数值
	err := proxywasm.AddHttpResponseHeader(ResponseHeaderName, strconv.Itoa(counterValue))
	if err != nil {
		log.Warnf("failed to add response header: %v", err)
	}

	return types.ActionContinue
}
