# mud-dispatch-channel

A local Claude Code **custom channel** MCP server. The MudClient game process
HTTP POSTs freeform developer feedback (typed in-game via `#claude <text>`) plus
a path to a context bundle to this server. The server, loaded by a running
`claude` session as a channel, **pushes** that feedback into the session as a
channel notification so Claude sees it and acts on it.

`#chat <message>` (or `#claude --chat <message>`) sends the message with **no
context attached** — no transcript, no raw capture — for when you just want to
converse through the client instead of filing a task. The receiving session is
told (in the bundle) to reply, not spawn work.

The reply leg (Claude → game) rides a **file inbox**: after acting on a dispatch,
Claude calls the `report_to_game` MCP tool, which drops a small JSON file the
MudClient app watches and echoes in-game as a bright `↙ claude` line (mirroring the
outbound `↗ claude`). See "Reply path" below.

### Automatic completion pings (`stop-ping.py`)

`report_to_game` is deliberate — Claude only calls it after a `#claude` dispatch. To
surface **every** turn's completion in-game (including tasks started from the terminal),
a `Stop` hook in `.claude/settings.local.json` runs `tools/dispatch/stop-ping.py`: it
reads the turn's final assistant text from the transcript, condenses it to one line, and
writes it to the **same inbox** the app already watches — so it echoes as a `↙ claude`
line automatically. It skips no-text turns and turns that end in a question (waiting on
you, not done). It writes to the same `MUD_DISPATCH_INBOX` (default
`~/Documents/MudClient/claude-inbox/`) and can never fail a turn (any error → exit 0,
no write). Disable/edit it via `/hooks`. This is separate from — and additive to —
`report_to_game`.

## Launching

Channels must be enabled **when `claude` launches** — they cannot be attached to
an already-running session. To receive dispatches, relaunch your `claude`
session from the repo root with:

```
claude --dangerously-load-development-channels server:muddispatch
```

`.mcp.json` at the repo root declares the `muddispatch` server, so Claude spawns
`node tools/dispatch/mud-channel.mjs` over stdio automatically.

When a dispatch arrives Claude sees:

```
<channel source="muddispatch" bundle="/path/to/dispatch.md" dir="/path">FEEDBACK</channel>
```

## Reply path (`report_to_game` → file inbox → game)

Claude reports a result back INTO the game with the MCP tool `report_to_game`
(exposed by this server over the same stdio connection):

```
report_to_game({ message: string, action?: string })
```

- `message` (required) — the human-readable, one-line result/summary to show the
  player.
- `action` (optional) — a single command the player should run next, e.g.
  `#reload`, `just run`, `just build`.

On call the server ensures the inbox dir exists (mode `0700`) and writes a file
`<epoch-ms>-<rand>.json` (mode `0600`):

```json
{ "message": "reload done, corpse timing fixed", "action": "#reload", "ts": "2026-07-12T00:00:00.000Z" }
```

`action` is always present (empty string when none). `ts` is ISO-8601.

Inbox path: `~/Documents/MudClient/claude-inbox/` (override with
`MUD_DISPATCH_INBOX`). The MudClient app watches this folder, echoes each reply
in-game as:

```
↙ claude  <message>
          → run <action>      # only when action is non-empty
```

then moves the file into `claude-inbox/archive/` so it renders exactly once. All
writes go to **stderr** logs only (never stdout — that's the MCP channel).

Harness (no live MCP client needed):

```
node tools/dispatch/report-to-game.test.mjs   # asserts the reply file is written + parses
```

## Token

The `/dispatch` endpoint requires the header `x-dispatch-token` to match a shared
token:

- If `MUD_DISPATCH_TOKEN` is set in the environment, that value is used.
- Otherwise the server reads (or, on first run, generates) a random hex token at
  `~/Documents/MudClient/dispatch.token` (written with mode `0600`).

The resolved token path is logged to **stderr** on startup (never stdout — stdout
is the MCP stdio channel).

## Environment variables

| Var                   | Default       | Purpose                          |
| --------------------- | ------------- | -------------------------------- |
| `MUD_DISPATCH_PORT`   | `8788`        | HTTP listener port               |
| `MUD_DISPATCH_HOST`   | `127.0.0.1`   | Bind address (loopback only)     |
| `MUD_DISPATCH_TOKEN`  | _(unset)_     | Override the token file          |
| `MUD_DISPATCH_INBOX`  | `~/Documents/MudClient/claude-inbox` | Reply-file inbox dir |

## HTTP API

`POST /dispatch`

- Header: `x-dispatch-token: <token>` (else `403`)
- JSON body: `{ "feedback": string, "bundle"?: string, "dir"?: string }`
- Response: `200 {"ok":true}` once pushed to the channel.
  - `400` on malformed JSON / missing feedback.
  - `202` if the channel has no MCP peer connected yet (server started without a
    parent `claude` session) — the request is accepted but not delivered.

Any other path/method → `404`.

## Smoke test

```
# start the server (leave running)
node tools/dispatch/mud-channel.mjs

# wrong token → 403
curl -s -o /dev/null -w '%{http_code}\n' -X POST 127.0.0.1:8788/dispatch \
  -H 'x-dispatch-token: nope' -H 'content-type: application/json' \
  -d '{"feedback":"x"}'

# right token → 2xx
curl -s -X POST 127.0.0.1:8788/dispatch \
  -H "x-dispatch-token: $(cat ~/Documents/MudClient/dispatch.token)" \
  -H 'content-type: application/json' \
  -d '{"feedback":"hello from curl","bundle":"/tmp/x/dispatch.md"}'
```

When run standalone (no parent `claude` process attached over stdio), the
notification push has no MCP peer, so the good-token POST returns `202`
(accepted, not delivered) instead of `200`. Under a real
`claude --dangerously-load-development-channels server:muddispatch` session it
returns `200` and the feedback appears in the session.
