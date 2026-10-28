.PHONY: dev test lint check fix vuln

dev:
	docker compose up --build

test:
	go test -race ./...

lint:
	golangci-lint run

check:
	go build -o /dev/null ./...
	go vet ./...
	go test -race ./...

fix:
	go fix ./...

vuln:
	go tool govulncheck ./...
