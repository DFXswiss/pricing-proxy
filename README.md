# pricing-proxy

Small caching reverse-proxy in front of the **CoinGecko Pro API** and
**GeckoTerminal API**. Holds the CoinGecko upstream key in a single place,
validates upstream error envelopes before caching, and coalesces
concurrent identical requests so one cache miss cannot stampede the
upstream.

Designed for the DFX.swiss service stack but useful for anyone who runs
several backends against CoinGecko Pro or GeckoTerminal from one host:
the upstream key lives only here, every consumer is configured with
`COINGECKO_BASE_URL=http://pricing-proxy:8080/coingecko` (or
`GECKOTERMINAL_BASE_URL=http://pricing-proxy:8080/geckoterminal`) and
never sees the key.

Both routes share the same cache, coalescing, and validation pipeline.
GeckoTerminal is currently free-tier only (no auth), but the API-key
plumbing is already in place for the day it ships a Pro tier.

Distributed as a versioned Docker image on Docker Hub:
**[`dfxswiss/pricing-proxy`](https://hub.docker.com/r/dfxswiss/pricing-proxy)**

## Architecture

```
┌──────────────────────────────────────────────────┐
│  Docker host                                     │
│                                                  │
│  ┌────────┐  ┌────────┐  ┌────────────┐          │
│  │   A    │  │   B    │  │     …      │          │
│  └───┬────┘  └───┬────┘  └────┬───────┘          │
│      │           │            │                  │
│      │   COINGECKO_BASE_URL=                     │
│      │   http://pricing-proxy:8080/coingecko     │
│      │   GECKOTERMINAL_BASE_URL=                 │
│      │   http://pricing-proxy:8080/geckoterminal │
│      └───────────┼────────────┘                  │
│                  ▼                               │
│        ┌──────────────────┐                      │
│        │  pricing-proxy   │                      │
│        │   (OpenResty)    │                      │
│        │                  │                      │
│        │  · cache (60 s + │                      │
│        │    15 m stale)   │                      │
│        │  · key inject    │                      │
│        │  · body validate │                      │
│        │  · coalescing    │                      │
│        └───┬───────────┬──┘                      │
│            │           │                         │
└────────────┼───────────┼─────────────────────────┘
             ▼           ▼
   pro-api.coingecko.com  api.geckoterminal.com
```

## What it does

- **Single API key.** The CoinGecko Pro key is set once in the proxy's
  `.env`. Consumers never see it. (GeckoTerminal is free-tier only and
  needs no key.)
- **60 s fresh cache + 15 m stale window.** Concurrent identical
  requests collapse to one upstream call; subsequent hits within 60 s
  are served from memory (`X-Cache-Status: HIT`). On transient upstream
  failure only, the last validated body may be served for up to
  15 minutes as `X-Cache-Status: STALE`.
- **Body validation before cache.** CoinGecko Pro returns HTTP 200 with
  an `error_message` envelope on quota exhaustion or bad parameters;
  GeckoTerminal wraps failures in an `errors` array. Any top-level
  `error*` field carrying a truthy value rejects the response with HTTP
  502 — **never** cached as a valid price.
- **Request coalescing.** Per cache key, only one request reaches the
  upstream even under burst; the others wait up to 5 s for the
  freshly-populated cache. Especially valuable for GeckoTerminal, whose
  free-tier 30 req/min quota is shared across the whole host IP.
- **IPv4 only.** The runtime resolver filters AAAA records so the proxy
  cannot pick an IPv6 Cloudflare endpoint that the host network can't
  route.
- **Identity transfer-encoding.** The proxy strips `Accept-Encoding` on
  the upstream call so the Lua validator sees plain JSON, not gzip.

## Quick start

```bash
git clone https://github.com/DFXswiss/pricing-proxy.git
cd pricing-proxy
cp .env.example .env
# put your CoinGecko Pro key into .env
docker compose up -d
curl -s http://localhost:8080/health
curl -si 'http://localhost:8080/coingecko/api/v3/simple/price?ids=bitcoin&vs_currencies=usd'
curl -si 'http://localhost:8080/geckoterminal/api/v2/networks/eth/tokens/0xdac17f958d2ee523a2206206994597c13d831ec7'
```

The bundled `docker-compose.yaml` pulls a tagged image from Docker Hub —
no local build needed.

## Pinning a version (recommended)

The compose default tracks `:latest`, which moves on every push to `main`.
For a reproducible deployment, pin to a release tag:

```yaml
services:
  pricing-proxy:
    image: dfxswiss/pricing-proxy:v1.0.0
    # …
```

| Tag | Source |
|---|---|
| `v<major>.<minor>.<patch>` | Built from a matching `v*.*.*` git tag (immutable) |
| `latest` | Built from every push to `main` |
| `beta` | Built from every push to `develop` |

## Consumer integration

| Upstream | Direct URL | Proxied URL |
|---|---|---|
| CoinGecko Pro | `https://pro-api.coingecko.com/<path>` | `http://pricing-proxy:8080/coingecko/<path>` |
| GeckoTerminal | `https://api.geckoterminal.com/<path>` | `http://pricing-proxy:8080/geckoterminal/<path>` |

### CoinGecko

In your consumer compose:

```diff
  environment:
-   COINGECKO_API_KEY: ${COINGECKO_API_KEY}
+   COINGECKO_BASE_URL: http://pricing-proxy:8080/coingecko
```

In your consumer code, fetch via the base URL and skip the auth header —
the proxy injects it:

```ts
const res = await fetch(
  `${process.env.COINGECKO_BASE_URL}/api/v3/simple/price?ids=bitcoin&vs_currencies=usd`,
);
const { bitcoin } = await res.json();
```

### GeckoTerminal

GeckoTerminal needs no API key — the proxy gives you cache + coalescing +
validation on top of the shared free-tier 30 req/min quota.

```diff
  environment:
+   GECKOTERMINAL_BASE_URL: http://pricing-proxy:8080/geckoterminal
```

```ts
const res = await fetch(
  `${process.env.GECKOTERMINAL_BASE_URL}/api/v2/networks/citrea/tokens/${address}`,
);
const { data } = await res.json();
```

A consumer can still talk to either upstream directly by setting
`*_BASE_URL` to the upstream origin (and, for CoinGecko Pro, supplying
its own `x-cg-pro-api-key` header) — the proxy is the recommended path
but not the only one.

## Behaviour

### Cache TTL

- **Fresh: 60 s** for every validated upstream response. This is the
  project-wide hard cap on the fresh key — never raise it.
- **Stale: 15 minutes.** Independently, the last **validated** body per
  cache key is remembered under a `stale:`-prefixed key. When the
  upstream subrequest is not HTTP 200 because of a transient failure
  (connect/read timeout, HTTP 408/429/5xx, or capture status 0/502/504),
  that body is served as HTTP 200 with `X-Cache-Status: STALE` instead
  of 502. Coalesced waiters that find no fresh key after the lock go
  to upstream like the leader; STALE is only on a proven transient
  capture status. Serving STALE does **not** refresh the fresh 60 s
  key.
- Cache key: `<upstream>:<path>?<query-string>` (e.g.
  `coingecko:/api/v3/...`, `geckoterminal:/api/v2/...`). The stale key
  is `stale:` plus the same string (including the original client query
  for the CoinGecko `usd`→`tether` alias).
- Storage: `lua_shared_dict pricing_cache 50m` (in-memory, lost on
  restart, shared across upstreams).
- `X-Cache-Status` values: `HIT` | `MISS` | `STALE`.

### Validation

A response is cached only when all of the following are true:

- HTTP status is `200`
- Body parses as JSON
- Body is a JSON object or array
- No top-level field whose name starts with `error` carries a truthy
  value (catches CoinGecko's `error` / `error_message` and
  GeckoTerminal's `errors`; an empty array, empty string, `0`, or
  `false` does not trip the check, so upstreams that ship a benign
  diagnostic counter alongside a successful payload still cache)
- No nested `status.error_message` envelope (CoinGecko Pro's
  quota-exhausted / bad-params shape)

Any failed check → the consumer receives HTTP 502 with a JSON body
describing the rejection. Neither the fresh nor the stale key is
updated, so an invalid or error-envelope body is never remembered or
served as `STALE`. Non-transient upstream 4xx (e.g. 400/401/403/404)
also never trigger `STALE` — only the transient statuses listed under
Cache TTL do.

### CoinGecko id alias

On CoinGecko `/api/v3/simple/price` only, the proxy deliberately rewrites
one coin id. CoinGecko's `usd` id is not the US dollar — it is a dust
token — so consumers that ask for `ids=usd` as an FX rate would otherwise
cache a near-zero price. The proxy substitutes USDT instead:

- Whole-token, case-insensitive match: `usd` / `USD` in the `ids` list
  is fetched as `tether`. Comma-separated lists are rewritten in place
  (`ids=usd,bitcoin` → `ids=tether,bitcoin`).
- `usd-coin` (USDC) and other ids that merely contain `usd` are **not**
  rewritten.
- `vs_currencies=usd` is **not** rewritten.
- The JSON response key remains `usd`: the upstream `tether` object is
  remapped so existing `response.usd.eur` readers keep working. If the
  client also requested `tether`, both keys are present.
- If the upstream body has no `tether` object after the alias rewrite,
  the proxy returns 502 and does not cache (so HITs never serve a body
  without `usd`).
- The cache key is the **original** client query string (`ids=usd…`), so
  identical follow-up requests HIT the already-aliased body.
- Other CoinGecko paths and all of GeckoTerminal are untouched.

This is the one place the proxy is not fully transparent.

### What it never does

- Cache an upstream error envelope (invalid JSON, top-level `error*` /
  `status.error_message`, or any body that fails validation). Those
  responses are never stored on the fresh or stale key and are never
  served as `STALE`.
- Serve `STALE` for non-transient upstream 4xx other than 408/429
  (e.g. 400/401/403/404) — those stay HTTP 502.
- Hold a **fresh** value longer than the configured 60 s TTL. The
  15-minute window applies only to the last validated body, and only
  when a transient upstream failure would otherwise produce 502. If no
  stale body exists, the consumer still gets HTTP 502.

## Quota monitoring

The proxy ships with a background monitor that polls CoinGecko's
`/api/v3/key` endpoint at a fixed cadence and pushes Telegram alerts
when the monthly credit drops below configured thresholds. This lets
the proxy — the single component that owns the upstream key — own its
own alerting, instead of bolting quota checks onto each consumer.

### How it works

`monitor.lua` schedules an `ngx.timer.every` task on worker 0 only, so
a multi-worker deployment still emits exactly one probe per cycle.

OpenResty does **not** allow `ngx.location.capture` from inside a timer
callback, so the timer cannot do the upstream work itself. Instead the
timer issues a loopback TCP `GET` to `/_internal/quota_probe`, which is
a normal request location (firewalled to `127.0.0.1` so external
callers cannot trigger alerts). Its `content_by_lua_block` calls
`monitor.run_check()` in a real request context, where subrequests
work, and the actual probe-and-alert pipeline runs:

1. Issues an internal subrequest to `/_internal/coingecko/api/v3/key`
   so the same key plumbing, runtime resolver, and gzip stripping that
   serve consumer traffic also handle the probe. This bypasses the
   public `/coingecko/` location on purpose, so a probe response never
   lands in the 60 s response cache and can never be served as a
   consumer price.
2. Extracts `monthly_call_credit`, `current_total_monthly_calls`, and
   `current_remaining_monthly_calls` from the response.
3. Compares the used percentage against two thresholds and, if a
   threshold is crossed and the per-threshold dedup window has expired,
   POSTs a Markdown-formatted message to Telegram via
   `/_internal/telegram_send` (token kept in env, passed per request
   via `ngx.location.capture`'s `vars`, never in the URL or logs).
4. Writes the latest percentage into the `monitor_state` shared dict so
   `/quota` can expose it and so a drop back below the warn threshold
   triggers a single recovery notification.

### Thresholds and state transitions

The monitor classifies each probe into one of three levels:

| Level | Used credit |
|---|---|
| ✅ Healthy | < 80% |
| ⚠️ Warning | ≥ 80% |
| 🚨 Critical | ≥ 95% |

Telegram messages are emitted:

- **On every escalation** (healthy → warn, healthy → crit, warn → crit).
- **On every de-escalation** (crit → warn re-sends the warn alert so the
  operator still sees the system is non-healthy; warn|crit → healthy
  sends a single recovery message).
- **Periodically while non-healthy** — once every `REALERT_INTERVAL_S`
  (default 24 h) at the current level, so a persistent over-quota
  condition keeps surfacing without spamming inside the window.

If a Telegram send fails, the new state is **not** persisted, so the
next probe inside `CHECK_INTERVAL_S` will retry. This means a transient
Telegram outage will not silently swallow an alert.

Constants live at the top of `monitor.lua`
(`CHECK_INTERVAL_S`, `WARN_THRESHOLD_PCT`, `CRIT_THRESHOLD_PCT`,
`REALERT_INTERVAL_S`, `STARTUP_DELAY_S`). Change them there if the
operating profile shifts — the values are intentionally constants
rather than env vars because they describe the alert contract, not
per-deployment configuration.

### Enabling alerts

Set both env vars in your `.env`. Either one missing → the proxy still
runs and still probes (the result lands in the log every 30 min), but
no Telegram messages are sent.

```bash
TELEGRAM_BOT_TOKEN=123456:ABC-DEF…
TELEGRAM_CHAT_ID=948932168
```

To find the chat id, message your bot once (`/start`) and read it from
`https://api.telegram.org/bot<TOKEN>/getUpdates`.

### Disabling alerts

Leave `TELEGRAM_BOT_TOKEN` or `TELEGRAM_CHAT_ID` empty (the default in
`.env.example`). The background monitor still runs and logs every cycle
so operators can spot trends in `docker logs`, but no message is sent.

### `/quota` endpoint

`GET /quota` returns a snapshot of what the monitor last observed:

```bash
$ curl -s http://localhost:8080/quota
{"last_pct":12.3,"last_level":0,"last_alert_ts":1716120000}
```

Fields:
- `last_pct` — percentage of monthly credit used at the last probe.
- `last_level` — `0` healthy, `1` warning, `2` critical.
- `last_alert_ts` — Unix time of the last successfully sent Telegram
  message (omitted if no alert has fired since startup).

This is **not** a live probe — it serves whatever the background task
last wrote into the shared dict, so the value is at most
`CHECK_INTERVAL_S` old and may be missing entirely for the first
`STARTUP_DELAY_S` after a restart. Use it for dashboards and
human-readable checks; do not script retry/backoff against it.

### Operational notes

- **Worker affinity.** The timer is fenced to `ngx.worker.id() == 0` so
  alerting does not multiply with `worker_processes`. If you ever turn
  `worker_processes` to `1` or move to a single-process runtime this
  fence still does the right thing.
- **State is in memory.** The `monitor_state` shared dict resets on a
  container restart, which means the level history resets too. That is
  acceptable: the next probe within `CHECK_INTERVAL_S` will derive the
  level from scratch and alert if the condition still holds.
- **No Telegram from the request path.** Only the timer touches
  Telegram. Consumer requests never block on Telegram availability.
- **Token never logged.** `access_log off` on
  `/_internal/telegram_send` keeps the bot token out of access logs;
  the token is also passed via per-request `vars`, never templated into
  config.

## Building from source

The Docker image is the supported distribution; building locally is only
needed for development on the proxy itself.

```bash
docker build -t pricing-proxy:dev .
docker run -d -p 8080:8080 -e COINGECKO_API_KEY=$YOUR_KEY pricing-proxy:dev
```

## Files

| File | Purpose |
|---|---|
| `nginx.conf` | OpenResty top-level config: shared dicts, resolver with `ipv6=off`, env var pass-through, monitor bootstrap |
| `pricing.conf` | Server block: public `/coingecko/`, `/geckoterminal/`, `/health`, `/quota` locations and their internal `/_internal/<upstream>/` and `/_internal/telegram_send` `proxy_pass` targets |
| `proxy.lua` | Request handler: upstream config lookup → fresh cache lookup → coalescing lock → subrequest → (transient → stale) → JSON validation → fresh + stale cache store |
| `monitor.lua` | Background quota monitor: timer → `/api/v3/key` probe → threshold check → Telegram alert |
| `Dockerfile` | Bakes the configs and Lua files into the OpenResty base image |
| `docker-compose.yaml` | Reference deployment using the published image |
| `.env.example` | `COINGECKO_API_KEY` plus optional `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` for alerts |

## Debugging

| What | How |
|---|---|
| Health | `curl http://localhost:8080/health` → `OK` |
| Last quota snapshot | `curl http://localhost:8080/quota` → `{"last_pct":12.3}` (cached, not a live probe) |
| Logs | `docker logs pricing-proxy` — every request is logged with `cache=HIT\|MISS\|STALE` |
| Rejected upstream responses | Look for `pricing-proxy reject <upstream> ...` warnings in the logs |
| Non-JSON upstream body | A `pricing-proxy non-JSON body ... body[0..200]=...` warning includes a snippet so you can see what the upstream actually returned (HTML challenge, gzip, etc.) |
| Quota monitor cycle | A `monitor: quota <plan> used=X/Y (Z%) remaining=…` NOTICE is logged every `CHECK_INTERVAL_S` (default 30 min) |
| Quota monitor errors | `monitor: telegram send failed …` or `monitor: quota probe …` warnings indicate alerting/probe problems |
| Cache state | Restart the container — cache is in-memory and clears on restart |

## License

MIT — see [LICENSE](LICENSE).
