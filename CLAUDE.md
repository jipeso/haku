# haku

Personal Telegram bot: reads job alert emails from a dedicated mailbox and sends the owner one daily digest of new listings.
Go 1.27, SQLite (modernc, plain database/sql), IMAP (go-imap), Docker. Spec: docs/PLAN.md — read the relevant section before starting work.

## Commands

- `make dev` — run in Docker with live reload (dry run: never marks mail read or sends to Telegram)
- `make check` — build + vet + test (must pass before finishing)
- `make lint` — golangci-lint
- `go run ./cmd/haku digest --dry-run` — parse the real mailbox and print the digest

## Conventions

- Minimal and clean: simplest code that meets the spec; no abstractions, options or interfaces it doesn't need. Full style rules: docs/PLAN.md §3.2.
- Single user, no commands, no scraping: haku only reads alert emails and sends Telegram messages.
- Standard library first; new dependencies need a reason in docs/PLAN.md.
- Tests never touch the network: real emails live in internal/alert/testdata/*.eml; use httptest for Telegram.
- Inject time (`now func() time.Time`); all dates are Europe/Helsinki.
- Only production marks mail read. Anything run in dev uses `--dry-run`.
