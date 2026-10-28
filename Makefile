.PHONY: dev test lint generate check fix vuln

dev:
	docker compose up --build

test:
	go test -race ./...

lint:
	golangci-lint run

generate:
	go tool sqlc generate

check:
	go build -o /dev/null ./...
	go vet ./...
	go test -race ./...

fix:
	go fix ./...

vuln:
	go tool govulncheck ./...
