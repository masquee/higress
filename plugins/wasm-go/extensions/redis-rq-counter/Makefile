.PHONY: build run
build:
	env GOPROXY=https://goproxy.cn,direct GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared -o plugin.wasm ./main.go

run: build
	docker-compose up

.PHONY: clean
clean:
	docker-compose down
