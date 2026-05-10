# pricing-proxy

Small caching reverse-proxy in front of the **CoinGecko Pro API**. Holds the
upstream key in a single place, validates upstream error envelopes before
caching, and coalesces concurrent identical requests so one cache miss
cannot stampede the upstream.

Designed for the DFX.swiss service stack but useful for anyone who runs
several backends against CoinGecko Pro from one host: the upstream key
lives only here, every consumer is configured with
`COINGECKO_BASE_URL=http://pricing-proxy:8080/coingecko` and never sees
the key.

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
│      └───────────┼────────────┘                  │
│                  ▼                               │
│        ┌──────────────────┐                      │
│        │  pricing-proxy   │                      │
│        │   (OpenResty)    │                      │
│        │                  │                      │
│        │  · cache (60 s)  │                      │
│        │  · key inject    │                      │
│        │  · body validate │                      │
│        │  · coalescing    │                      │
│        └────────┬─────────┘                      │
│                 │                                │
└─────────────────┼────────────────────────────────┘
                  ▼
         pro-api.coingecko.com
```

## What it does

- **Single API key.** The CoinGecko Pro key is set once in the proxy's
  `.env`. Consumers never see it.
- **60 s shared cache.** Concurrent identical requests collapse to one
  upstream call; subsequent hits within 60 s are served from memory.
  `/coins/{id}/history?date=...` responses are cached without expiry
  because they are date-pinned and immutable.
- **Body validation before cache.** CoinGecko Pro returns HTTP 200 with an
  `error_message` envelope on quota exhaustion or bad parameters. Those
  responses are rejected with HTTP 502 and **never** cached as a valid
  price.
- **Request coalescing.** Per cache key, only one request reaches CoinGecko
  even under burst; the others wait up to 5 s for the freshly-populated
  cache.
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

Every URL under `https://pro-api.coingecko.com/<path>` becomes
`http://pricing-proxy:8080/coingecko/<path>` from an in-cluster consumer.

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

A consumer can still talk to `pro-api.coingecko.com` directly by setting
`COINGECKO_BASE_URL` to that origin and supplying its own
`x-cg-pro-api-key` header — the proxy is the recommended path but not the
only one.

## Behaviour

### Cache TTL

Two tiers, picked by upstream path:

| Path pattern | TTL | Rationale |
|---|---|---|
| `/api/v3/coins/{id}/history` | unbounded | Date-pinned daily snapshot, immutable once the day is over |
| everything else | 60 s | Hard cap for live prices — never raise it |

- Cache key: `coingecko:<path>?<query-string>`.
- Storage: `lua_shared_dict pricing_cache 50m` (in-memory, lost on
  restart). Unbounded entries are evicted only by LRU pressure on the
  50 MB shared dict or by container restart.
- Caveat for the unbounded tier: a `/history?date=<today>` request pins
  the intraday snapshot until the container restarts. Reporting code
  should query `/history` only for dates strictly in the past.

### Validation

A response is cached only when all of the following are true:

- HTTP status is `200`
- Body parses as JSON
- Body is a JSON object or array
- No `status.error_message`, `error_message`, or `error` field is present
  at the top level

Any failed check → the consumer receives HTTP 502 with a JSON body
describing the rejection, and the cache stays empty for that key so the
next request triggers a fresh upstream call.

### What it never does

- Serve a stale value when the upstream is down. There is no
  `proxy_cache_use_stale`. If CoinGecko is unreachable or returns
  garbage, the consumer gets HTTP 502 and decides for itself how to
  react (pause minting, retry, alert).
- Cache an upstream error envelope.
- Hold a non-`/history` value longer than the configured 60 s TTL.

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
| `nginx.conf` | OpenResty top-level config: shared dicts, resolver with `ipv6=off`, env var pass-through |
| `pricing.conf` | Server block: public `/coingecko/` location and the internal `/_internal/coingecko/` `proxy_pass` target |
| `proxy.lua` | Request handler: cache lookup → coalescing lock → subrequest → JSON validation → cache store |
| `Dockerfile` | Bakes the three configs into the OpenResty base image |
| `docker-compose.yaml` | Reference deployment using the published image |
| `.env.example` | Only secret is `COINGECKO_API_KEY` |

## Debugging

| What | How |
|---|---|
| Health | `curl http://localhost:8080/health` → `OK` |
| Logs | `docker logs pricing-proxy` — every request is logged with `cache=HIT\|MISS` |
| Rejected upstream responses | Look for `pricing-proxy reject coingecko ...` warnings in the logs |
| Non-JSON upstream body | A `pricing-proxy non-JSON body ... body[0..200]=...` warning includes a snippet so you can see what the upstream actually returned (HTML challenge, gzip, etc.) |
| Cache state | Restart the container — cache is in-memory and clears on restart |

## License

MIT — see [LICENSE](LICENSE).
