# Gateway Setup — Running Harness for Portal

Portal is the native client for **Harness**
([`ethenotethan/harness`](https://github.com/ethenotethan/harness)), an opinionated fork of
[Hermes Agent](https://github.com/NousResearch/hermes-agent). It talks to the Harness
gateway over WebSocket JSON-RPC at `/v1/ws`.

**That endpoint does not exist in stock hermes-agent.** Upstream only exposes an
OpenAI-compatible HTTP API (`/v1/chat/completions`, `/v1/responses`). The WebSocket
JSON-RPC endpoint — and with it the wiki, cron-graph, artifact, learning, file-browser,
feed and push-notification RPCs this app is built on — exists only in Harness. Point
Portal at a stock install and the connection health probe succeeds while the WebSocket
upgrade fails.

What Harness changes relative to upstream is published as a fork diff at
[ethenotethan.github.io/harness](https://ethenotethan.github.io/harness/), described in
the repo's `fork.yaml` and enforced by its CI (a rebase onto newer upstream cannot land
without updating the analysis — see Harness's `docs/forkdiff.md`).

> **Do not run `hermes update` on a Harness checkout.** It pulls upstream over the fork
> and removes `/v1/ws`. Update by pulling Harness's `main` instead. Harness is rebased
> onto upstream periodically (as of 2026-09-14 it sits on upstream `main` from
> 2026-08-12 and changes 94 files), so it lags upstream by weeks, not months.

## 1. Install Harness

### Fresh machine (recommended path)

Run the upstream installer first — it sets up `uv`, Python, the venv, the `hermes`
entrypoint, and a managed checkout at `~/.hermes/hermes-agent`:

```bash
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
source ~/.zshrc   # or ~/.bashrc
```

Then repoint the managed checkout at Harness:

```bash
cd ~/.hermes/hermes-agent
git remote add fork https://github.com/ethenotethan/harness.git
git fetch fork
git checkout -B main fork/main

# Reinstall so the venv picks up Harness's code + pinned deps
uv pip install -e ".[all,dev]"
```

### Migrating an existing hermes-agent install

Same remote swap, on your existing checkout:

```bash
cd ~/.hermes/hermes-agent    # or wherever your checkout lives
git stash                    # if you have local changes
git remote add fork https://github.com/ethenotethan/harness.git
git fetch fork
git checkout -B main fork/main
uv pip install -e ".[all,dev]"
```

Your config (`~/.hermes/.env`), memory, sessions, and skills are untouched — they live
outside the repo checkout. Because Harness trails upstream by the weeks since its last
rebase, migrating can mean giving up very recent upstream features while gaining the
native-client RPC surface. There is no data migration in either direction; only the code
changes.

### Manual clone (containers / CI)

```bash
git clone https://github.com/ethenotethan/harness.git
cd harness
uv venv venv --python 3.11
export VIRTUAL_ENV="$(pwd)/venv"
uv pip install -e ".[all,dev]"
```

Run the `hermes` entrypoint from this venv (`./venv/bin/hermes`), not a system Python.
Requires Python ≥3.11 and <3.14.

## 2. Configure the agent

If this is a fresh install, configure a model provider first:

```bash
hermes setup            # full wizard (provider, tools, gateway)
# or: hermes setup --portal   # one-command Nous Portal setup
```

Then enable the API server in `~/.hermes/.env`:

```bash
API_SERVER_ENABLED=true
API_SERVER_KEY=<paste a strong secret>       # e.g. `openssl rand -hex 32`
# Optional overrides (defaults shown):
# API_SERVER_HOST=127.0.0.1
# API_SERVER_PORT=8642
```

`API_SERVER_KEY` is **required** — the gateway refuses to start the API server without
it, even on loopback. On a network-accessible bind (`API_SERVER_HOST=0.0.0.0`), the key
must be at least 16 characters and non-placeholder or the server refuses to start: this
endpoint dispatches terminal-capable agent work, so a guessable key is remote code
execution.

## 3. Start the gateway

```bash
hermes gateway
```

Look for:

```
[API Server] API server listening on http://127.0.0.1:8642
```

Sanity-check the endpoint Portal will use:

```bash
curl -s http://127.0.0.1:8642/health
curl -s -H "Authorization: Bearer $API_SERVER_KEY" http://127.0.0.1:8642/v1/capabilities
```

If `/v1/capabilities` 404s, you are running stock hermes-agent, not Harness — go back
to step 1.

## 4. Connect the app

On first launch Portal asks for a gateway URL and API key:

| Field | Value |
|-------|-------|
| Gateway URL | `ws://127.0.0.1:8642/v1/ws` (the app default) — or your host |
| API Key | The `API_SERVER_KEY` you set above |

You can also paste `http://host:8642` — the app converts `http(s)://` to `ws(s)://` and
appends `/v1/ws` automatically. Additional gateways can be added later under
**Settings → Connection → Saved Gateways**.

## 5. Optional features

Everything below degrades gracefully — the app detects gateway capabilities via
`/v1/capabilities` and hides features the gateway doesn't support.

| Feature | Gateway requirement |
|---------|---------------------|
| Wiki suite (browser, graphs, timeline) | Set `WIKI_PATH=/path/to/wiki` in `~/.hermes/.env` (defaults to `~/wiki`) |
| Push notifications (iOS/macOS) | APNs credentials on the gateway — see [`apns-setup.md`](apns-setup.md) |
| Feed / digest videos | Digest pipeline configured on the gateway (`feed.*` RPCs) |
| Cron dashboard and dataflow graph | Built-in — the graph fills in as jobs declare `inputs` / `outputs` / `side_effects` / `source_files` |
| Living artifacts, learning, file browser | Built-in — `artifact.*`, `learning.*`, `files.*` RPCs |

## 6. Remote / hosted gateways

- **Reverse proxy:** put the gateway behind TLS and connect with
  `wss://your-host/v1/ws`. The proxy must pass WebSocket upgrades through on `/v1/ws`.
- **Cloudflare Access:** supported natively — the app runs the CF Access login flow and
  stores a per-host `CF_Authorization` cookie. Just enter the protected URL.
- **Bare public bind:** avoid. If you must, use a long random `API_SERVER_KEY` and
  understand that the gateway drives a terminal as the host user.

## Troubleshooting

| Symptom | Likely cause |
|---------|-------------|
| App stuck on "connecting", gateway logs no WS upgrade | Stock hermes-agent (no `/v1/ws`) — install Harness |
| `API server` never starts | `API_SERVER_ENABLED` unset, or missing/weak `API_SERVER_KEY` |
| 401 on connect | API key mismatch; the app sends `Authorization: Bearer <key>` |
| Worked, then broke after `hermes update` | Update pulled upstream over Harness — re-checkout `fork/main` (step 1) |
| Wiki tab empty | `WIKI_PATH` unset or pointing at an empty directory |

See [`rpc-reference.md`](rpc-reference.md) for the full RPC/event catalog and
connection lifecycle, and [`../DESIGN.md`](../DESIGN.md) for the auth design.
