# haku — Project plan

> Job alert emails from every Finnish job board, one Telegram digest every morning.

This document is the source of truth for building **haku**. It is written for Claude Code: read the section you need when starting a milestone, follow the conventions, and update this file when a decision changes.

---

## 1. Summary

haku is a **personal tool with one user** (the owner). The owner subscribes one dedicated mailbox to the job alert emails ("hakuvahti") of every job board. Every day at **07:00 Finnish time**, haku reads the new alert emails, extracts the listings, drops duplicates and sends **one Telegram digest** to the owner.

haku never fetches a job board (the main boards forbid scraping). All keyword and location filtering happens in the alerts the owner sets up on each site.

It is a small, single-binary Go service that runs in Docker on an existing AWS machine (the same one that runs Duunit). It has no web UI, no inbound port and no Telegram commands.

---

## 2. Functional specification

### 2.1 Sources

Alert emails from these senders are parsed. Each source is identified by the sender's domain.

| Source          | Sender domain (verify from a real email) |
| --------------- | ---------------------------------------- |
| Duunitori       | `duunitori.fi`                           |
| Jobly           | `jobly.fi`                               |
| Työmarkkinatori | `tyomarkkinatori.fi`                     |
| Kuntarekry      | `kuntarekry.fi`                          |
| Valtiolle.fi    | `valtiolle.fi`                           |
| LinkedIn        | `linkedin.com`                           |

- Emails from other senders, or from a known sender that contain no listings (welcome, confirmation), are marked read and ignored.
- An email from a known sender that fails to parse is marked read (it stays in the mailbox and can be re-processed by marking it unread) and is reported in the digest.

### 2.2 The daily digest

- Sent every day at `DIGEST_TIME` (default **07:00 Europe/Helsinki**; DST handled by the time zone, not a fixed offset).
- Contains all listings found since the last digest. If it exceeds Telegram's 4096-character limit, it is split into several messages at entry boundaries.
- Each entry: **title** (linked), **company** and source.
- **Duplicates** (same listing from several sources, or repeated by the same source on another day) are shown once, linked to the source where it was seen first.
- No new listings → a short message: "No new listings today."
- Warnings at the end of the digest (including the "no listings" message):
  - `⚠️ Couldn't read 1 email from LinkedIn` — parse failures.
  - `⚠️ No email from Duunitori in 7 days` — an alert may have expired or broken.
- **Missed digest:** if the process was down at digest time, the digest is sent on startup when today's digest has not been sent and it is past digest time.

Example:

```
haku · Tue 27 Oct · 3 new listings

• Junior Software Developer — Acme Oy · Duunitori
• Frontend Developer (React) — Example Group · LinkedIn
• Harjoittelija, ohjelmistokehitys — Kaupunki X · Kuntarekry

⚠️ No email from Jobly in 7 days
```

(Titles are links. Link previews are disabled.)

### 2.3 Out of scope (v1)

Multiple users, access control, Telegram commands, keyword/location filtering inside haku, fetching job pages, scraping, web UI, AI features, backups (data is small and re-creatable).

---

## 3. Tech stack and conventions

### 3.1 Stack

| Area         | Choice                                                                                                                                                                                                                                                                                                                                   |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language     | **Go 1.27**, module `github.com/jipeso/haku`                                                                                                                                                                                                                                                                                             |
| Dependencies | Standard library first. Allowed: `modernc.org/sqlite` (pure Go SQLite), `github.com/emersion/go-imap/v2` (the standard library has no IMAP client), `github.com/emersion/go-message` (MIME and charset decoding of real-world email; comes with go-imap), `github.com/PuerkitoBio/goquery` (CSS selectors keep the HTML email parsers short). Anything else needs a reason recorded in this file. |
| Database     | SQLite via `modernc.org/sqlite` (pure Go → `CGO_ENABLED=0`, static binary). WAL mode, `busy_timeout`. Three tables, so plain `database/sql`; the schema is a `CREATE TABLE IF NOT EXISTS` script run on startup (no migration tool, no code generation).                                                                                    |
| Mail         | IMAP over TLS (port 993) to the dedicated mailbox.                                                                                                                                                                                                                                                                                       |
| Telegram     | Thin client on `net/http`: `sendMessage` only. Outbound only, so no polling and no webhook.                                                                                                                                                                                                                                              |
| Logging      | `log/slog` JSON handler to stdout.                                                                                                                                                                                                                                                                                                       |
| Dev tools    | Pinned in `go.mod` with `go get -tool` and run via `go tool`: `air`, `govulncheck`. `golangci-lint` v2 installed as a binary (its recommended method).                                                                                                                                                                                   |
| Container    | Single multi-stage `Dockerfile` with `dev` and `prod` targets. Prod runs on distroless static, non-root.                                                                                                                                                                                                                                 |

### 3.2 Code style: minimal and clean

The goal is code that is short, obvious and easy to delete. When in doubt, write less. Reference: [Effective Go](https://go.dev/doc/effective_go), [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments) and the [Google Go Style Guide](https://google.github.io/styleguide/go/).

**Simplicity**

- Write the simplest code that meets the spec. No speculative abstractions, options, config, hooks or extension points the spec doesn't ask for.
- No interface until there are two implementations or a test needs a fake at an I/O boundary (the mailbox, the Telegram client, the clock). Define it where it is **used** and keep it small. Source parsers are plain functions in a map, not an interface.
- Plain functions and structs over patterns. No frameworks, no dependency-injection containers, no generic "manager"/"service"/"helper" types.
- A little duplication is better than the wrong abstraction. Extract only when the third copy appears.
- No goroutines except the one scheduler loop. Everything is sequential.

**Structure**

- Small packages named for what they provide (`alert`, `digest`); never `util`, `common`, `helpers` or `models`.
- Short functions with one job. Handle errors and edge cases first and return early; keep the happy path unindented. No `else` after `return`.
- No package-level mutable state. Dependencies are passed explicitly as struct fields, wired in `main`.
- `context.Context` is the first parameter of anything that does I/O; pass it through, never store it.

**Naming**

- Go conventions: `MixedCaps`, short names in small scopes (`l` for a listing in a loop), descriptive names for wider scopes, no stutter (`digest.Render`, not `digest.RenderDigest`).
- Exported only when another package needs it.

**Errors**

- Wrap with context: `fmt.Errorf("parse linkedin email %s: %w", id, err)`. Messages lowercase, no trailing punctuation.
- Handle an error once: return it **or** log it, never both. Log at the top (the daily run), not deep inside.
- No `panic` outside `main` startup.

**Comments**

- Doc comments on exported identifiers, one or two lines.
- Other comments explain _why_, never _what_. No commented-out code, no stale TODOs.

**Go specifics**

- Prefer the standard library and its modern helpers (`slices`, `maps`, `strings.Cut`, `min`/`max`, range over int). Run `go fix ./...` to apply modernizers.
- Time is injected (`now func() time.Time`) so scheduling and "today" logic are testable. Load `Europe/Helsinki` with `time.LoadLocation` and blank-import `time/tzdata` (distroless has no tz database).
- Graceful shutdown: `signal.NotifyContext` in `main`.
- Configuration from environment variables only, parsed and validated once at startup into a `Config` struct.

**Tests**

- Table-driven, standard `testing` package only (no assertion libraries), `httptest` for HTTP, real SQLite in `t.TempDir()` (no DB mocks), **no network access**. Run with `-race`.
- Test behaviour through the package's API, not private details. Keep test helpers few and marked with `t.Helper()`.

**Enforced by tools**

- `gofmt` on every edit (Claude Code hook), `golangci-lint` in `make lint` and CI with `.golangci.yml` (revive, errorlint, unparam, misspell, nolintlint; gofmt and goimports).

Before finishing a milestone, review the diff for anything that can be deleted or simplified (see §8).

### 3.3 Configuration (env)

| Variable           | Example                | Notes                                                       |
| ------------------ | ---------------------- | ----------------------------------------------------------- |
| `TELEGRAM_TOKEN`   | —                      | Bot created with @BotFather.                                |
| `TELEGRAM_CHAT_ID` | `123456789`            | The owner's chat with the bot; the only recipient.          |
| `IMAP_ADDR`        | `imap.gmail.com:993`   | TLS only.                                                   |
| `IMAP_USER`        | `haku.alerts@...`      | The dedicated mailbox.                                      |
| `IMAP_PASSWORD`    | —                      | An app password (Gmail requires 2-Step Verification for it). |
| `DB_PATH`          | `/data/haku.db`        |                                                             |
| `DIGEST_TIME`      | `07:00`                | Europe/Helsinki.                                            |
| `LOG_LEVEL`        | `info`                 |                                                             |

---

## 4. Architecture

### 4.1 Layout

```
cmd/haku/main.go          subcommands: run (scheduler), digest (one digest now; --dry-run)
internal/
  config/                 env parsing + validation
  mailbox/                IMAP: fetch unread messages, mark them read
  alert/                  Parse(msg) → []Listing; one file per source + testdata/*.eml + tests
  store/                  SQLite schema and queries (database/sql), fingerprinting
  digest/                 render + split (HTML parse mode, escaped)
  telegram/               sendMessage client
docs/
  PLAN.md                 this file
deploy/
  compose.prod.yaml, deploy.sh
```

The daily flow (§4.4) and the scheduler loop live in `cmd/haku`; they are short and only wire the packages together.

### 4.2 Parsing alerts

```go
type Listing struct {
    Title   string
    Company string
    URL     string
    Source  string // "Duunitori", "LinkedIn", ...
}

// Parse picks the parser by the sender's domain. ok is false for unknown senders.
func Parse(from string, html []byte) (ls []Listing, source string, ok bool, err error)
```

- Each source is one function `func(doc *goquery.Document) ([]Listing, error)` in its own file, registered in a map keyed by sender domain.
- Parsers work on the email's HTML part (go-message decodes transfer encoding and charset).
- Find listings by the **link pattern** of job pages (e.g. LinkedIn `/jobs/view/<id>`), then read title and company from the surrounding elements. This survives cosmetic template changes better than long CSS paths.
- **Clean URLs:** strip tracking parameters; where the link is a click-tracking redirect that contains the real URL or job ID, rebuild the canonical job URL (e.g. `https://www.linkedin.com/jobs/view/<id>/`). If the real URL can't be recovered, keep the redirect link as it is.
- An email from a known sender with zero listings is not an error (confirmation and welcome emails). A parse error means the structure was not recognised (e.g. job links found but no title).

### 4.3 Data model (SQLite)

```
listings(id INTEGER PK, fingerprint TEXT UNIQUE, title, company, url, source,
         first_seen_at, sent_at NULL)
sources(name PK, last_email_at)     -- for the "no email in 7 days" warning
digests(day PK, sent_at)            -- one row per sent digest (missed-digest check)
```

- **Fingerprint** = normalized company + normalized title: lowercase, trimmed, collapsed whitespace, company legal suffixes removed (Oy, Oyj, Ab, Ltd, ry, Ky). It will occasionally miss a pair; that is accepted.
- Listings whose `first_seen_at` is older than 60 days are pruned (their alerts have stopped repeating them by then).

### 4.4 Daily flow

1. Fetch all **unread** messages from INBOX.
2. For each message: identify the source by sender domain, parse, insert listings (`INSERT … ON CONFLICT(fingerprint) DO NOTHING`), update `sources.last_email_at`. Collect parse failures per source.
3. Mark the fetched messages read.
4. Load unsent listings, render the digest with warnings, send it, set `sent_at`, insert today's `digests` row.
5. Prune old listings.

Ordering is crash-safe: listings are stored before messages are marked read (re-parsing is harmless thanks to the fingerprint), and they stay unsent until Telegram accepted the digest. If sending fails, the run logs the error and the next run sends them.

`haku digest --dry-run` fetches and parses without marking messages read or writing the database, and prints the digest to stdout. This is how to test against the real mailbox safely.

---

## 5. Mailbox setup (done by the owner)

1. Create the dedicated mailbox (e.g. a new Gmail account), enable 2-Step Verification and create an app password for IMAP.
2. On each site in §2.1, create an account with that address and set up job alerts with the wanted keywords and locations. Choose **daily** emails where the site offers it.
3. Confirm the subscriptions (click the confirmation links by hand).
4. Do not read the mailbox in a mail client that marks messages read — haku uses the unread flag to know what is new. (Reading in the web UI and marking unread again is fine.)
5. Once each source has sent at least one real alert, download one per source as `.eml` (Gmail: ⋮ → "Download message") for the test fixtures. Remove the unsubscribe/tracking tokens and personal details before committing them.

---

## 6. Environments and delivery

### 6.1 Development

- `docker compose up` (file `compose.yaml`) builds the `dev` target: `golang:1.27` image running `go tool air` for live reload. Source is bind-mounted; Go module cache, build cache and `/data` are named volumes. Secrets come from a git-ignored `.env` (`.env.example` committed).
- In dev, air runs `haku digest --dry-run`, so development never marks mail read or sends to Telegram. Only production consumes the mailbox.
- **Go is also installed on the host** (with `gcc`, needed by `-race`), because Claude Code's hooks, tests and the `gopls` language server run there.
- `Makefile` targets: `dev`, `test` (`go test -race ./...`), `lint` (`golangci-lint run`), `check` (build + vet + test, used by the Stop hook), `fix` (`go fix ./...`), `vuln` (`go tool govulncheck ./...`).

### 6.2 Production

- `prod` target: build with `CGO_ENABLED=0 go build -trimpath -ldflags="-s -w"`, copy the binary into a distroless static **nonroot** image, with `/data` owned by UID 65532 so the named volume is writable.
- `deploy/compose.prod.yaml`: `image: ${IMAGE}:${APP_TAG}`, `restart: unless-stopped`, `env_file: .env`, volume `haku_data:/data`, log rotation (`max-size: 10m`, `max-file: 3`). **No ports.**
- Runs on the Duunit AWS machine in `~/haku/deploy`, completely separate from Duunit's compose project.
- **Exactly one production instance** reads the mailbox.

### 6.3 CI/CD

- `.github/workflows/test.yml` (reusable): `go vet`, golangci-lint, `go test -race ./...`, `govulncheck`.
- `production.yml`: GitHub Release published → test → build and push `docker.io/<user>/haku:<tag>` and `:latest` → SSH to the server → `~/haku/deploy/deploy.sh <tag>` (`compose pull && up -d`).
- Reuse Duunit's secrets: `DOCKER_USERNAME`, `DOCKER_PASSWORD`, `PROD_SSH_KEY`, `PROD_HOST`, `PROD_USER`. Pin third-party actions by commit SHA.

---

## 7. Testing strategy

| What                     | How                                                                                                         |
| ------------------------ | ----------------------------------------------------------------------------------------------------------- |
| Alert parsers            | Real emails saved as `internal/alert/testdata/<source>.eml`, parsed in table-driven tests (expected listings). |
| Fingerprinting           | Table tests incl. Finnish characters (ä, ö, å), case, company suffixes.                                      |
| Digest rendering/splitting | Golden files; HTML escaping; split exactly at the 4096 limit; warnings.                                   |
| Store                    | Real SQLite in a temp dir: dedupe, unsent/sent, last-email tracking, missed-digest check, pruning.           |
| Telegram client          | Fake Bot API with `httptest.Server`.                                                                        |
| End to end               | `TestDailyRun`: fake mailbox (fixture emails) + fake Telegram + fake clock → expected messages, including a duplicate across sources, a parse failure and a stale source. |
| Live check               | `haku digest --dry-run` against the real mailbox. Manual only, never in CI.                                 |

---

## 8. Claude Code setup and working rhythm

`CLAUDE.md`, `.claude/settings.json` and the hooks (`gofmt.sh` after edits, `check.sh` running `make check` on stop) live in the repo. Keep them short; add to them only when Claude repeatedly gets something wrong.

- **One milestone per session.** Start in plan mode: "Read docs/PLAN.md §X and plan milestone N." Review the plan, then implement.
- Before committing: review the diff against §3.2 (remove anything the spec doesn't need, simplify what's left, keep tests passing), then run `/code-review`. Commit per milestone (or smaller), conventional commit messages.
- When a decision changes, update `docs/PLAN.md` in the same commit.

---

## 9. Milestones

Each milestone ends with `make check` and `make lint` passing.

| #   | Milestone | Done when |
| --- | --------- | --------- |
| 1   | **Mailbox and fixtures** (owner, §5): mailbox, alerts on every site, one `.eml` per source. | Every source has sent a real alert; fixtures are in `internal/alert/testdata/`. |
| 2   | **Parsers**: `alert` package, one parser per source, fingerprinting. | Fixture tests pass for every source. |
| 3   | **Digest end to end**: config, `mailbox`, `store`, `digest`, `telegram`, `haku digest` (+ `--dry-run`). | Dry run prints the real digest; `haku digest` delivers it to Telegram; `TestDailyRun` passes. |
| 4   | **Schedule and production**: `run` loop at `DIGEST_TIME`, missed-digest catch-up, pruning, stale-source warning; `deploy/` files, production workflow, first GitHub Release. | The 07:00 digest arrives from the AWS machine. |

---

## 10. Risks and accepted trade-offs

- **Email templates change** without notice. A broken parser shows up as a warning in the digest; the email stays in the mailbox and is re-processed after the fix by marking it unread.
- **Alerts can expire or get unsubscribed** (some sites stop alerts after inactivity). The "no email in 7 days" warning makes this visible.
- **Alert emails may hold only a subset** of matches (LinkedIn sends a handful of top matches). Accepted.
- **Duplicate detection** is heuristic; occasional duplicates are accepted.
- **Changing what to watch** means editing the alerts on each site by hand. Accepted for a single user.
- **Only one process may consume the mailbox.** Dev always uses `--dry-run`.
