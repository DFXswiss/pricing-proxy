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
│        │  · cache (60 s)  │                      │
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
- **60 s shared cache.** Concurrent identical requests collapse to one
  upstream call; subsequent hits within 60 s are served from memory.
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

- **60 s** for every upstream response. This is the project-wide hard
  cap — never raise it.
- Cache key: `<upstream>:<path>?<query-string>` (e.g.
  `coingecko:/api/v3/...`, `geckoterminal:/api/v2/...`).
- Storage: `lua_shared_dict pricing_cache 50m` (in-memory, lost on
  restart, shared across upstreams).

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
describing the rejection, and the cache stays empty for that key so the
next request triggers a fresh upstream call.

### What it never does

- Serve a stale value when an upstream is down. There is no
  `proxy_cache_use_stale`. If the upstream is unreachable or returns
  garbage, the consumer gets HTTP 502 and decides for itself how to
  react (pause minting, retry, alert).
- Cache an upstream error envelope.
- Hold a value longer than the configured 60 s TTL.

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
| `pricing.conf` | Server block: public `/coingecko/` and `/geckoterminal/` locations and their internal `/_internal/<upstream>/` `proxy_pass` targets |
| `proxy.lua` | Request handler: upstream config lookup → cache lookup → coalescing lock → subrequest → JSON validation → cache store |
| `Dockerfile` | Bakes the three configs into the OpenResty base image |
| `docker-compose.yaml` | Reference deployment using the published image |
| `.env.example` | Only secret is `COINGECKO_API_KEY` |

## Debugging

| What | How |
|---|---|
| Health | `curl http://localhost:8080/health` → `OK` |
| Logs | `docker logs pricing-proxy` — every request is logged with `cache=HIT\|MISS` |
| Rejected upstream responses | Look for `pricing-proxy reject <upstream> ...` warnings in the logs |
| Non-JSON upstream body | A `pricing-proxy non-JSON body ... body[0..200]=...` warning includes a snippet so you can see what the upstream actually returned (HTML challenge, gzip, etc.) |
| Cache state | Restart the container — cache is in-memory and clears on restart |

## License

MIT — see [LICENSE](LICENSE).
