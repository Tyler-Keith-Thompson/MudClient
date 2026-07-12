# mud-dispatch-channel

A local Claude Code **custom channel** MCP server. The MudClient game process
HTTP POSTs freeform developer feedback (typed in-game via `#claude <text>`) plus
a path to a context bundle to this server. The server, loaded by a running
`claude` session as a channel, **pushes** that feedback into the session as a
channel notification so Claude sees it and acts on it.

One-way only: game → Claude. There is no reply path.

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
