# torabot

A Discord MCP server written in V, using V's own `vlib/mcp` implementation. No
Node.js, no Python, no external packages — one binary built from V source.

It lets an MCP client read a server's channels and message history, search it,
post messages, and watch messages as they arrive over the Discord gateway.

## Contents

- [Requirements](#requirements)
- [Setup](#setup)
- [Build](#build)
- [Register with an MCP client](#register-with-an-mcp-client)
- [Tools](#tools)
- [How it works](#how-it-works)
- [Upstream bugs worked around](#upstream-bugs-worked-around)
- [Tests](#tests)
- [Troubleshooting](#troubleshooting)
- [Limits](#limits)
- [Layout](#layout)

## Requirements

- **V 0.5.2 or newer.** Built and tested against `v hash e690943`.
- **A Discord bot**, since Discord offers no read access for ordinary user
  accounts. Creating one takes about five minutes and is described below.
- **A C compiler.** The bundled TCC is enough on Windows; see [Build](#build).

## Setup

### 1. Create a bot

1. Open <https://discord.com/developers/applications> and click
   **New Application**. Name it and **Create**.
2. In the left sidebar open **Bot**, then **Reset Token** and copy the value.
   Discord shows it once.
3. On the same **Bot** page, turn on **Message Content Intent**. Without it,
   Discord returns message bodies as empty strings, and every read tool will
   appear to work while returning nothing.
4. Open **Installation**, copy the install link, and use **Add to server** to
   invite the bot to a server. Grant:
   - `View Channel`
   - `Read Message History`
   - `Send Messages`, if you want the `send_message` tool to work

The install link looks like:
`https://discord.com/oauth2/authorize?client_id=<your application id>`

### 2. Provide the token

Set `DISCORD_TOKEN` in the environment rather than in source or config files:

```powershell
setx DISCORD_TOKEN "your-bot-token"
```

Open a new terminal afterwards, since `setx` only affects processes started
later.

## Build

```powershell
v.exe -cc tcc -d no_vschannel -o torabot.exe main.v
```

Both flags matter:

- **`-cc tcc`** forces the bundled TCC compiler. The implicit compiler path can
  fail to build `libgc` and then fall back to a `gcc` that may not be installed,
  which turns a working build into a confusing failure.
- **`-d no_vschannel`** switches `net.http` off Windows Schannel and onto
  mbedTLS. Without it every request to `discord.com` fails at the TLS handshake
  with `0x80090308` (`SEC_E_INVALID_TOKEN`). See
  [Upstream bugs](#upstream-bugs-worked-around).

If `v` is not on your PATH, use the absolute path to the compiler.

## Register with an MCP client

Add this to your MCP client's server list. The command path must be absolute.

```json
{
  "mcpServers": {
    "discord": {
      "command": ["C:\\path\\to\\torabot\\torabot.exe"],
      "environment": {
        "DISCORD_TOKEN": "your-bot-token"
      }
    }
  }
}
```

The server speaks MCP over stdio, so it is normally launched by the client
rather than by hand. If you do run it directly, it will read JSON-RPC frames
from stdin and write replies to stdout, which is why there is no startup
output to look for.

### OpenCode

Add to `~/.config/opencode/opencode.json`:

```json
"mcp": {
  "discord": {
    "type": "local",
    "command": ["C:\\Users\\MR\\Projects\\torabot\\torabot.exe"],
    "enabled": true,
    "environment": { "DISCORD_TOKEN": "{env:DISCORD_TOKEN}" }
  }
}
```

## Tools

| Tool | Read-only | Purpose |
| --- | --- | --- |
| `list_guilds` | yes | Servers the bot is in. Start here for a `guild_id`. |
| `list_channels` | yes | Channels of a server. `text_only` hides voice and categories. |
| `read_messages` | yes | Up to 100 recent messages, `before` to page further back. |
| `read_all_messages` | yes | Whole history, oldest first, bounded by `max_messages`. |
| `search_messages` | yes | Messages containing a substring. |
| `list_threads` | yes | Active threads of a channel. |
| `send_message` | **no** | Post a message. The only tool that changes state. |
| `watch_messages` | yes | Live messages over the gateway, without polling. |

All ids are Discord snowflakes (strings), not channel names.

### Reading a whole channel

```
list_guilds → guild_id
list_channels(guild_id) → channel_id
read_all_messages(channel_id, max_messages=500)
```

`read_all_messages` pages backwards in batches of 100 and returns the result
oldest-first, which is the order you want to read in. When `max_messages`
truncates the result, the most recent messages are kept.

### Watching live messages

`watch_messages` opens a gateway connection, waits, and returns whatever
arrived:

```
watch_messages(channel_ids=["123..."], seconds=30, max_messages=100)
```

It blocks for the requested duration, so keep `seconds` modest. Each call opens
its own gateway connection, which costs one Identify handshake; for sustained
monitoring, prefer one longer call over many short ones.

## How it works

```
main.v                 MCP server: tool registration, formatting, error text
torabot/discord.v      Discord REST client
torabot/gateway.v      Discord gateway: WebSocket, identify, heartbeat, dispatch
torabot/http.v         HTTP/1.1 over mbedTLS
torabot/inflate.v      DEFLATE handling for gateway frames
torabot/args.v         Typed access to decoded tool arguments
```

The MCP layer is V's own `vlib/mcp`, which implements the **2025-11-25**
revision of the specification. That revision is the right choice here: the
newer `2026-07-28` revision removes the `initialize` handshake in favour of a
stateless core, and clients that still send the handshake cannot talk to it.

### Gateway compression is off, on purpose

`gateway_url` does not request `compress=zlib-stream`, so gateway frames arrive
as plain JSON and no inflation happens. At a few hundred bytes per frame the
bandwidth saving would be small next to the cost of a decompressor on the hot
path, and leaving it off keeps the reader simple.

`inflate.v` still inflates a frame that arrives compressed, and falls back to
returning the raw bytes rather than failing, so the path stays correct if an
edge node compresses regardless of what was requested.

### Why there is a hand-written HTTP client

`vlib/net/http` uses Win32 Schannel on Windows, and Schannel as used by V cannot
complete a handshake with `discord.com`. `vlib/net/ssl`, however, defaults to
mbedTLS and negotiates with Discord without trouble.

Rather than patch the compiler, `torabot/http.v` speaks the small amount of
HTTP/1.1 needed here directly over `net.ssl`: request rendering, response
parsing, chunked transfer decoding, and a bounded read. It also handles
`Retry-After` and `X-RateLimit-*`, so a throttled read waits rather than
failing.

Verified on Windows 11:

```
$ v.exe -cc tcc -d no_vschannel -o torabot.exe main.v
$ node probe.mjs
INIT: discord-v 2025-11-25
TOOLS: list_guilds, list_channels, read_messages, read_all_messages,
       search_messages, list_threads, send_message, watch_messages
list_guilds -> The bot is not a member of any server yet.
watch_messages -> No messages received in 15s.
```

## Upstream bug worked around

### `net.http` on Windows cannot reach `discord.com`

`net.http` uses Schannel on Windows. Against `discord.com` the handshake fails
with `0x80090308` (`SEC_E_INVALID_TOKEN`).

What makes this a V defect rather than a Discord or Cloudflare policy:

- `curl.exe` shipped with Windows also uses Schannel, and receives `200` from
  the same URL.
- Seven other Cloudflare-fronted hosts (`github.com`, `api.openai.com`,
  `api.anthropic.com`, `registry.npmjs.org`, `cdnjs.cloudflare.com`,
  `unpkg.com`) all succeed through V. Only the Discord edge nodes are affected.
- Disabling HTTP/2 changes nothing, so the ALPN compatibility shim in
  `vschannel.c` is not involved.
- Building with `-d no_vschannel` swaps the backend and nothing else, and the
  same code then returns `200`.

Reported upstream: <https://github.com/vlang/v/issues/29231>

Workaround: build with `-d no_vschannel`.

## Tests

```powershell
v.exe -cc tcc -o t.exe torabot\http_test.v     ; .\t.exe
v.exe -cc tcc -o t.exe torabot\discord_test.v  ; .\t.exe
v.exe -cc tcc -o t.exe torabot\args_test.v     ; .\t.exe
v.exe -cc tcc -o t.exe torabot\inflate_test.v  ; .\t.exe
```

Run them one file at a time. `v test torabot\` builds the files concurrently,
which on this machine trips the same `libgc` failure described under
[Build](#build), and the resulting `exec failed (SetHandleInformation)` message
says nothing useful about the real problem.

To confirm which failure you are actually looking at, build and run manually:

```powershell
v.exe -cc tcc -keepc -o probe.exe torabot\http_test.v ; .\probe.exe
```

`-keepc` leaves the generated C behind, which is worth doing when a build fails
inside the C compiler rather than the V checker.

## Troubleshooting

**Every request fails with `0x80090308`**
You built without `-d no_vschannel`. Rebuild.

**`DISCORD_TOKEN is not set`**
The variable is not visible to the server process. `setx` only affects new
processes, so restart your terminal and the MCP client.

**`401` from Discord**
The token was reset, or belongs to a different application. The Developer
Portal shows a token only once.

**`403` from Discord**
The bot lacks a permission in that channel. Re-invite it with **View Channel**
and **Read Message History**, then re-grant the channel overrides in Discord's
own UI, which can override the server-level permissions.

**`404 Unknown Guild`**
The id is wrong, or the bot is not a member of that server. Confirm with
`list_guilds`.

**Message bodies come back empty**
**Message Content Intent** is off. Enable it in the Developer Portal. This is
the most common cause of "the tools work but there is nothing in them".

**`watch_messages` returns nothing**
Expected when the bot is in a quiet channel. If you expect traffic, check the
intent above, and confirm the bot is actually in the channel.

**`Rate limited`**
Discord throttled the request. `Retry-After` is honoured up to 30 seconds; a
longer wait is reported rather than slept through, so retry after the stated
delay.

## Limits

- **Rate limits are honoured but not retried.** A `429` surfaces as an error
  instead of blocking.
- **No resume support.** A dropped gateway connection is not resumed; the next
  `watch_messages` call identifies afresh. Discord allows resumption by session
  id, which is not implemented.
- **One gateway connection per `watch_messages` call.** Fine for interactive
  use, wasteful for sustained monitoring.
- **Bot visibility only.** The bot cannot read DMs or channels it was not
  invited to. Reading through a personal account instead would violate
  Discord's terms and risk the account, so it is deliberately not implemented.
- **Blocking tool.** `watch_messages` holds the MCP request open for its whole
  duration, so a client with a short tool timeout will cut it off.

## Licence

MIT.