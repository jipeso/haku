# haku

Telegram bot that sends a daily digest of new Finnish job listings matching each user's keywords.
Go 1.27, SQLite (modernc, sqlc, goose), Docker. Spec: docs/PLAN.md — read the relevant section before starting work.

## Commands

- `make dev` — run in Docker with live reload (uses the dev bot from .env)
- `make check` — build + vet + test (must pass before finishing)
- `make lint` — golangci-lint
- `make generate` — regenerate sqlc code after editing store/queries.sql or migrations
- `go run ./cmd/haku check --dry-run --keyword <k>` — live smoke test against real boards

## Conventions

- Minimal and clean: simplest code that meets the spec; no abstractions, options or interfaces it doesn't need. Full style rules: docs/PLAN.md §3.2.
- Standard library first; new dependencies need a reason in docs/PLAN.md.
- Tests never touch the network: save real responses in testdata/ and use httptest.
- Inject time (`now func() time.Time`); all dates are Europe/Helsinki.
- Never edit store/db/ by hand — it is sqlc output.
- Boards: follow docs/PLAN.md §5 politeness rules. Never add workarounds for blocking.
