# haku — Project plan

> One job search watch, many Finnish job boards, one Telegram digest every morning.

This document is the source of truth for building **haku**. It is written for Claude Code: read the section you need when starting a milestone, follow the conventions, and update this file when a decision changes.

---

## 1. Summary

Each user sets **keywords** and a **location** once in a Telegram bot. Every day at **07:00 Finnish time**, haku searches the major Finnish job boards and sends each user **one digest** of new matching listings. A listing that appears on several boards is shown once.

It is a small, single-binary Go service that runs in Docker on an existing AWS machine (the same one that runs Duunit). It has no web UI and no public HTTP endpoint.

---

## 2. Functional specification

### 2.1 Users and access

- The admin is identified by `ADMIN_CHAT_ID` (env). The admin is approved automatically on `/start`.
- Anyone else who sends `/start` becomes **pending**. The admin receives a message with the person's name, @username and chat ID, plus inline **Approve** / **Deny** buttons.
  - Approve → user status `approved`; the user gets a welcome message with `/help`.
  - Deny → status `denied`; the user is told once, later messages are ignored.
  - A pending user who writes again gets "Still waiting for approval."
- Only approved users can use commands.

### 2.2 The watch (hakuvahti)

- Exactly **one watch per user**: a list of keywords and a list of locations.
- **Keywords**: a listing matches if it matches **any** keyword. Case-insensitive.
- **Locations**: a listing matches if its location contains **any** of the user's locations (case-insensitive). No locations set = all of Finland.
- No other filters (no exclude words, employment type or remote filter).
- **Changing the watch never sends old listings.** When keywords or locations change, all listings that currently match are recorded as _seen_ (baseline) without being sent. Only listings found later are sent.

### 2.3 Boards

Target boards: **Duunitori, Oikotie Työpaikat, Jobly, Työmarkkinatori, Monster, Kuntarekry, Valtiolle.fi.**

A board is only included if it can be read **politely and within its terms** (see §5). A board that cannot is dropped, not worked around.

### 2.4 The daily digest

- Sent every day at **07:00 Europe/Helsinki** (DST handled by the time zone, not a fixed offset).
- Contains **all** new matches since the last digest. If it exceeds Telegram's 4096-character limit, it is split into several messages at entry boundaries.
- Each entry: **title** (linked) and **company**.
- **Duplicates across boards** are shown once. The link points to the board where the listing was **seen first**.
- No new matches → a short message: "No new matches today."
- If any board failed during the run, every digest (including the "no matches" message) ends with a note, e.g. "⚠️ Couldn't check today: Jobly".
- Paused users get nothing.

Example:

```
haku · Tue 27 Oct · 3 new matches

• Junior Software Developer — Acme Oy
• Frontend Developer (React) — Example Group
• Harjoittelija, ohjelmistokehitys — Kaupunki X

⚠️ Couldn't check today: Jobly
```

(Titles are links. Link previews are disabled.)

### 2.5 Commands (English)

| Command                             | Behaviour                                                                                                                |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `/start`                            | Request access (or welcome back if approved).                                                                            |
| `/help`                             | List commands.                                                                                                           |
| `/keywords react, frontend, junior` | Replace keywords (comma-separated). Without arguments: show current keywords. Triggers a baseline.                       |
| `/location Helsinki, Espoo`         | Replace locations. `/location all` clears them (= all of Finland). Without arguments: show current. Triggers a baseline. |
| `/settings`                         | Show the watch, paused state, digest time.                                                                               |
| `/pause` / `/resume`                | Stop / restart digests.                                                                                                  |
| `/now`                              | Run a fresh check now, then show **all of today's matches**, including ones already sent this morning.                   |
| `/delete`                           | Ask for confirmation (inline button), then delete all of the user's data.                                                |

`/now` details:

- "Today's matches" = the user's non-baseline matches whose match time is on today's date (Europe/Helsinki).
- Unsent matches shown by `/now` are marked sent, so the next morning digest does not repeat them.
- Rate limit: one `/now` per user per 15 minutes. If a check is already running, wait for it instead of starting another.

### 2.6 Out of scope (v1)

Web UI, AI features, CV or cover letters, Duunit integration, exclude words, per-user digest times, multiple watches per user, LinkedIn/Indeed, backups (data is small and re-creatable).

---

## 3. Tech stack and conventions

### 3.1 Stack

| Area         | Choice                                                                                                                                                                                                                                                               |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language     | **Go 1.27**, module `github.com/jipeso/haku`                                                                                                                                                                                                                         |
| Dependencies | Standard library first. Allowed: `modernc.org/sqlite`, `github.com/pressly/goose/v3`, `golang.org/x/sync`, `github.com/temoto/robotstxt`, `github.com/PuerkitoBio/goquery` (only if a board needs HTML parsing). Anything else needs a reason recorded in this file. |
| Database     | SQLite via `modernc.org/sqlite` (pure Go → `CGO_ENABLED=0`, static binary). WAL mode, `busy_timeout`, `foreign_keys` on.                                                                                                                                             |
| Migrations   | goose, SQL files embedded with `embed.FS`, applied on startup.                                                                                                                                                                                                       |
| Queries      | **sqlc** (SQLite engine) generating typed Go from `queries.sql`.                                                                                                                                                                                                     |
| Telegram     | Thin client written on `net/http` (no bot library): `getUpdates` long polling, `sendMessage`, `answerCallbackQuery`, `editMessageText`, `deleteWebhook`. No webhook, so no inbound port.                                                                             |
| Logging      | `log/slog` JSON handler to stdout.                                                                                                                                                                                                                                   |
| Dev tools    | Pinned in `go.mod` with `go get -tool` and run via `go tool`: `sqlc`, `air`, `govulncheck`. `golangci-lint` v2 installed as a binary (its recommended method).                                                                                                       |
| Container    | Single multi-stage `Dockerfile` with `dev` and `prod` targets. Prod runs on distroless static, non-root.                                                                                                                                                             |

### 3.2 Code style: minimal and clean

The goal is code that is short, obvious and easy to delete. When in doubt, write less. Reference: [Effective Go](https://go.dev/doc/effective_go), [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments) and the [Google Go Style Guide](https://google.github.io/styleguide/go/).

**Simplicity**

- Write the simplest code that meets the spec. No speculative abstractions, options, config, hooks or extension points the spec doesn't ask for.
- No interface until there are two implementations or a test needs a fake at an I/O boundary (`Board`, the Telegram client, the clock). Define it where it is **used** and keep it small.
- Plain functions and structs over patterns. No frameworks, no dependency-injection containers, no generic "manager"/"service"/"helper" types.
- A little duplication is better than the wrong abstraction. Extract only when the third copy appears.
- Use goroutines only where the plan needs concurrency (boards in parallel, bot + scheduler). Everything else is sequential.

**Structure**

- Small packages named for what they provide (`digest`, `match`); never `util`, `common`, `helpers` or `models`.
- Short functions with one job. Handle errors and edge cases first and return early; keep the happy path unindented. No `else` after `return`.
- No package-level mutable state. Dependencies are passed explicitly as struct fields, wired in `main`.
- `context.Context` is the first parameter of anything that does I/O; pass it through, never store it.

**Naming**

- Go conventions: `MixedCaps`, short names in small scopes (`l` for a listing in a loop), descriptive names for wider scopes, no stutter (`digest.Render`, not `digest.RenderDigest`).
- Exported only when another package needs it.

**Errors**

- Wrap with context: `fmt.Errorf("fetch duunitori page %d: %w", page, err)`. Messages lowercase, no trailing punctuation.
- Handle an error once: return it **or** log it, never both. Log at the top (the run or the handler), not deep inside.
- No `panic` outside `main` startup.

**Comments**

- Doc comments on exported identifiers, one or two lines.
- Other comments explain _why_, never _what_. No commented-out code, no stale TODOs.

**Go specifics**

- Prefer the standard library and its modern helpers (`slices`, `maps`, `strings.Cut`, `min`/`max`, range over int). Run `go fix ./...` to apply modernizers.
- Time is injected (`now func() time.Time`) so scheduling and "today" logic are testable. Load `Europe/Helsinki` with `time.LoadLocation` and blank-import `time/tzdata` (distroless has no tz database).
- Graceful shutdown: `signal.NotifyContext` in `main`, components run under an `errgroup`.
- Configuration from environment variables only, parsed and validated once at startup into a `Config` struct.

**Tests**

- Table-driven, standard `testing` package only (no assertion libraries), `httptest` for HTTP, real SQLite in `t.TempDir()` (no DB mocks), **no network access**. Run with `-race`.
- Test behaviour through the package's API, not private details. Keep test helpers few and marked with `t.Helper()`.

**Enforced by tools**

- `gofmt` on every edit (Claude Code hook), `golangci-lint` in `make lint` and CI with this `.golangci.yml`:

```yaml
version: "2"
linters:
  default: standard
  enable:
    - revive # naming, doc comments, stutter, early return
    - errorlint # correct %w wrapping and errors.Is/As
    - unparam # unused parameters and results
    - misspell
    - nolintlint # no unexplained //nolint
formatters:
  enable:
    - gofmt
    - goimports
```

Before finishing a milestone, review the diff for anything that can be deleted or simplified (see §8.6).

### 3.3 Configuration (env)

| Variable         | Example                                      | Notes                                                                      |
| ---------------- | -------------------------------------------- | -------------------------------------------------------------------------- |
| `TELEGRAM_TOKEN` | —                                            | Separate bot for dev and prod (a token can only be polled by one process). |
| `ADMIN_CHAT_ID`  | `123456789`                                  |                                                                            |
| `DB_PATH`        | `/data/haku.db`                              |                                                                            |
| `DIGEST_TIME`    | `07:00`                                      | Europe/Helsinki. Useful to set near "now" in dev.                          |
| `USER_AGENT`     | `haku/0.1 (+https://github.com/jipeso/haku)` | Honest, identifies the project.                                            |
| `LOG_LEVEL`      | `info`                                       |                                                                            |

---

## 4. Architecture

### 4.1 Layout

```
cmd/haku/main.go          subcommands: run (bot + scheduler), check (one-off, --dry-run)
internal/
  config/                 env parsing + validation
  board/                  Board interface, Listing type, polite HTTP client
    duunitori/            one package per board: adapter + testdata/ fixtures + tests
    oikotie/ ...
  check/                  one check run: query boards, store results, compute matches
  match/                  keyword/location matching, fingerprinting
  digest/                 render + split digests (HTML parse mode, escaped)
  bot/                    command handlers, access requests, callbacks
  telegram/               minimal Bot API client
  schedule/               next-07:00 timer loop
  store/
    migrations/*.sql      goose, embedded
    queries.sql           sqlc input
    db/                   sqlc output (generated, committed)
docs/
  PLAN.md                 this file
  boards.md               board feasibility findings (milestone 1)
deploy/
  compose.prod.yaml, deploy.sh
```

### 4.2 Board adapter contract

```go
type Board interface {
    Name() string
    // Search returns current listings for one keyword, newest first,
    // capped (e.g. max 3 pages / 100 results).
    Search(ctx context.Context, keyword string) ([]Listing, error)
}

type Listing struct {
    BoardID  string    // the board's own ID for the listing
    Title    string
    Company  string
    Location string
    URL      string
    Posted   time.Time // zero if unknown
}
```

Each board uses its **own search** with the keyword; location filtering is done locally (boards express location differently). A listing returned by a board's search for keyword K counts as matching K, even if K appears only in the description.

### 4.3 Data model (SQLite)

```
users(chat_id PK, name, username, status[pending|approved|denied], paused, created_at)
watch_keywords(chat_id FK, keyword, PK(chat_id, keyword))
watch_locations(chat_id FK, location, PK(chat_id, location))
listings(id PK, fingerprint UNIQUE, title, company, location, url, board,
         first_seen_at, last_seen_at)            -- url/board = first board seen
listing_sources(board, board_id, listing_id FK, PK(board, board_id))
listing_hits(listing_id FK, keyword, PK(listing_id, keyword))
matches(chat_id FK, listing_id FK, matched_at, sent_at NULL, baseline BOOL,
        PK(chat_id, listing_id))
runs(id PK, trigger[daily|now|baseline], started_at, finished_at)
run_boards(run_id FK, board, ok BOOL, error, found INT)
```

- `ON DELETE CASCADE` from users, so `/delete` is one statement.
- **Fingerprint** = normalized company + normalized title: lowercase, trimmed, collapsed whitespace, company legal suffixes removed (Oy, Oyj, Ab, Ltd, ry, Ky). It will occasionally miss a pair; that is accepted.
- Listings not seen for 60 days are pruned.

### 4.4 Flows

**Check run** (shared by daily, `/now`, baseline; only one runs at a time):

1. Collect the unique keywords of all approved, unpaused users (or just the given keywords for a baseline).
2. Query boards concurrently (one goroutine per board), keywords **sequentially within a board** with polite delays. Each board has an overall timeout.
3. For each result: find by `(board, board_id)`, else by fingerprint, else insert. Update `last_seen_at`, add `listing_hits`.
4. Record per-board success/failure in `run_boards`.
5. For each approved user: insert `matches` for listings that hit any of their keywords, pass their location filter and are not yet in `matches`.

**Daily digest** (07:00): check run → for each approved, unpaused user, send unsent non-baseline matches (or "No new matches today") plus the failed-boards note → mark sent.

**Baseline** (after `/keywords` or `/location`): run a check limited to that user's keywords, then insert all currently matching listings for that user as `baseline=true, sent_at=now`. Reply to the user when done ("Watch updated. New matches arrive in the 07:00 digest.").

**Missed digest:** if the process was down at 07:00, run the digest on startup when today's daily run does not exist and it is past 07:00.

---

## 5. Boards: feasibility and politeness

### 5.1 Rules (non-negotiable)

- Respect `robots.txt` (fetched and cached per run). If a board's terms of use forbid automated access, **drop the board**.
- Prefer data sources in this order: official API or RSS/feed → JSON endpoint the site's own frontend uses → Schema.org `JobPosting` JSON-LD in server-rendered HTML → HTML parsing.
- One check per day (+ occasional `/now`), requests one at a time per host, 2–4 s delay with jitter, 20 s timeout, at most one retry on 5xx/timeout. On 429 or 403: stop that board for this run and report it as failed.
- No headless browsers, proxies, IP rotation or CAPTCHA solving. A board that only works with those is dropped.
- Honest `USER_AGENT`.

### 5.2 Feasibility check (milestone 1)

For each board, record in `docs/boards.md`: data source type and URL pattern, available fields (ID, title, company, location, URL, posted date), pagination and newest-first sorting, robots.txt and terms findings, and a decision: **include** or **drop** (with reason).

Each included board must also be tested **from the AWS machine** (`curl` with the real User-Agent over SSH), because some sites block datacenter IP ranges.

Known leads (verify, don't trust):

- **Duunitori**: listing pages are server-rendered; job pages contain Schema.org `JobPosting` JSON-LD.
- **Työmarkkinatori**: the official job search API requires a Finnish business ID (Y-tunnus) and KEHA approval, so it is not available to a private person. Only the public site can be considered, if its terms allow.
- **Monster**: confirm it still operates a Finnish job board.
- **Oikotie, Jobly, Kuntarekry, Valtiolle.fi**: no public feed or API found yet; check for RSS links and the JSON calls their search pages make.

---

## 6. Environments and delivery

### 6.1 Development

- `docker compose up` (file `compose.yaml`) builds the `dev` target: `golang:1.27` image running `go tool air` for live reload. Source is bind-mounted; Go module cache, build cache and `/data` are named volumes. Secrets come from a git-ignored `.env` (`.env.example` committed).
- Uses a **separate dev bot** (create with @BotFather).
- **Go is also installed on the host**, because Claude Code's hooks, tests and the `gopls` language server run there. Docker is for running the app and production parity.
- `Makefile` targets: `dev`, `test` (`go test -race ./...`), `lint` (`golangci-lint run`), `generate` (`go tool sqlc generate`), `check` (build + vet + test, used by the Stop hook), `fix` (`go fix ./...`), `vuln` (`go tool govulncheck ./...`).

### 6.2 Production

- `prod` target: build with `CGO_ENABLED=0 go build -trimpath -ldflags="-s -w"`, copy the binary into a distroless static **nonroot** image. Create `/data` in the build stage owned by UID 65532 and copy it in, so the named volume is writable.
- `deploy/compose.prod.yaml`: `image: ${IMAGE}:${APP_TAG}`, `restart: unless-stopped`, `env_file: .env`, volume `haku_data:/data`, log rotation (`max-size: 10m`, `max-file: 3`). **No ports.**
- Runs on the Duunit AWS machine in `~/haku/deploy`, completely separate from Duunit's compose project.

### 6.3 CI/CD (same pattern as Duunit)

- `.github/workflows/test.yml` (reusable): `actions/setup-go` with `go-version-file: go.mod`, `go vet`, golangci-lint action, `go test -race ./...`, `govulncheck`. Check that `go tool sqlc generate` leaves no diff.
- `staging.yml`: push to `main` → test → build and push `docker.io/<user>/haku:staging`. (Never run against the prod bot token.)
- `production.yml`: GitHub Release published → test → push `:<tag>` and `:latest` → SSH to the server → `~/haku/deploy/deploy.sh <tag>` (`compose pull && up -d`).
- Reuse Duunit's secrets: `DOCKER_USERNAME`, `DOCKER_PASSWORD`, `PROD_SSH_KEY`, `PROD_HOST`, `PROD_USER`. Pin third-party actions by commit SHA, as Duunit does.

---

## 7. Testing strategy

| What                           | How                                                                                                                       |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------- |
| Board parsers                  | Real responses saved once into `internal/board/<name>/testdata/`, parsed in table-driven tests.                           |
| Matching, fingerprinting       | Table tests incl. Finnish characters (ä, ö, å), case, company suffixes.                                                   |
| Digest rendering and splitting | Golden files; HTML escaping; split exactly at the 4096 limit.                                                             |
| Store and flows                | Real SQLite in a temp dir with migrations applied: new vs baseline vs already sent, `/now` "today" logic, cascade delete. |
| Telegram client and bot        | Fake Bot API with `httptest.Server`.                                                                                      |
| End to end                     | `TestDailyRun`: fake boards + fake Telegram + fake clock → expected messages per user, including failed-board note.       |
| Live smoke test                | `haku check --dry-run --keyword react` hits the real boards and prints the digest to stdout. Manual only, never in CI.    |

---

## 8. Claude Code setup (minimal)

Create these in milestone 0. Keep them short; add to them only when Claude repeatedly gets something wrong.

### 8.1 `CLAUDE.md`

```markdown
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
```

### 8.2 `.claude/settings.json`

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "permissions": {
    "allow": [
      "Bash(go build *)",
      "Bash(go test *)",
      "Bash(go vet *)",
      "Bash(go tool *)",
      "Bash(go mod *)",
      "Bash(make *)",
      "Bash(golangci-lint *)",
      "Bash(docker compose *)",
      "Bash(git status *)",
      "Bash(git diff *)",
      "Bash(git log *)"
    ],
    "deny": ["Read(./.env)", "Read(./deploy/.env)"]
  },
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/gofmt.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/check.sh"
          }
        ]
      }
    ]
  }
}
```

### 8.3 Hook scripts (executable)

`.claude/hooks/gofmt.sh` — format every edited Go file:

```bash
#!/usr/bin/env bash
f=$(jq -r '.tool_input.file_path // empty')
[[ "$f" == *.go && -f "$f" ]] && gofmt -w "$f"
exit 0
```

`.claude/hooks/check.sh` — block finishing while the build or tests fail:

```bash
#!/usr/bin/env bash
cd "$CLAUDE_PROJECT_DIR" || exit 0
[[ -f go.mod ]] || exit 0
if ! out=$(make check 2>&1); then
  echo "make check failed:" >&2
  echo "$out" | tail -n 40 >&2
  exit 2
fi
```

### 8.4 Plugin and tools

- Install `gopls` (`go install golang.org/x/tools/gopls@latest`) and the official code intelligence plugin: `/plugin install gopls-lsp@claude-plugins-official`.
- Install `jq` (used by the hook) and the `gh` CLI.

### 8.5 Skill (create after the first board works, in milestone 2)

`.claude/skills/add-board/SKILL.md`: the repeatable steps for adding a board, written from the first real adapter: read its entry in `docs/boards.md` → save fixtures → implement `Board` → table tests → register in `main` → `haku check --dry-run` smoke test → update `docs/boards.md`.

### 8.6 Working rhythm

- **One milestone per session.** Start in plan mode: "Read docs/PLAN.md §X and plan milestone N." Review the plan, then implement.
- `/clear` between unrelated tasks. If a correction fails twice, `/clear` and restart with a better prompt.
- Before committing: ask Claude to simplify ("Review the diff against §3.2. Remove anything the spec doesn't need and simplify what's left. Keep tests passing."), then run `/code-review` for bugs. Commit per milestone (or smaller), conventional commit messages.
- When a decision changes, update `docs/PLAN.md` in the same commit.

---

## 9. Milestones

Each milestone ends with `make check` and `make lint` passing.

| #   | Milestone                                                                                                                                                                                                        | Done when                                                                                      |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| 0   | **Repo and tooling**: `go mod init`, layout, Makefile, Dockerfile (dev + prod), `compose.yaml` with air, `.golangci.yml` (from §3.2), `.env.example`, `test.yml`, Claude Code files from §8.                     | `make check` passes; `docker compose up` live-reloads a placeholder `main`; CI is green.       |
| 1   | **Board feasibility**: research every board per §5.2, write `docs/boards.md`. The AWS `curl` tests are done by you over SSH.                                                                                     | Every board has an include/drop decision with reasons.                                         |
| 2   | **First board end to end**: `Board` interface, polite HTTP client (robots.txt, delays, timeouts, retry), first included board (Duunitori if included), `haku check --dry-run`. Then write the `add-board` skill. | Fixture tests pass; dry run prints real listings.                                              |
| 3   | **Storage and matching**: migrations, sqlc queries, dedupe (source ID → fingerprint), hits, matches, baseline.                                                                                                   | Store and flow tests from §7 pass.                                                             |
| 4   | **Telegram bot**: client, long polling, access requests with Approve/Deny, all commands, digest rendering and splitting.                                                                                         | The dev bot works end to end on your phone.                                                    |
| 5   | **Schedule and digests**: 07:00 loop, daily run, `/now`, failed-board notes, missed-digest catch-up, 60-day pruning.                                                                                             | `TestDailyRun` passes; with `DIGEST_TIME` set a minute ahead, the dev bot sends a real digest. |
| 6   | **Production**: `deploy/` files, staging and production workflows, server setup, first GitHub Release.                                                                                                           | The 07:00 digest arrives from the AWS machine.                                                 |
| 7   | **Remaining boards**: one board per session using the `add-board` skill.                                                                                                                                         | All included boards in the digest.                                                             |

---

## 10. Risks and accepted trade-offs

- **Boards can block or change** without notice. Failures are visible in every digest; a broken adapter is fixed or the board is dropped.
- **Datacenter IP blocking** on some boards → found in milestone 1 and dropped.
- **Cross-board duplicate detection** is heuristic; occasional duplicates are accepted.
- **Search semantics differ** between boards (some search descriptions, some only titles), so the same keyword can find different sets per board. Accepted.
- **Only one process may poll a bot token.** Dev and prod use different bots; never run the staging image with the prod token.

---
