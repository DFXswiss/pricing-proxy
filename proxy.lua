-- Pricing-proxy request handler.
--
-- Selects a per-route upstream config (host, optional API key, internal
-- subrequest location), caches validated upstream responses for 60s
-- (fresh; project-wide hard cap) and remembers the last validated body
-- for 15 minutes (stale). On transient upstream failure, serves that
-- remembered body as HTTP 200 with X-Cache-Status: STALE. A response
-- that looks like an upstream error must never be cached or served as
-- a valid price.
--
-- CoinGecko /simple/price queries that are only `ids` and `vs_currencies`
-- are also stored per coin and currency. /simple/token_price/<platform>
-- queries that are only `contract_addresses` and `vs_currencies` are
-- stored per platform, address, and currency. A later request reuses
-- those quotes even when the rest of the query string differs.

local CACHE_TTL = 60
local STALE_TTL = 900  -- 15 minutes
local price_pairs = require("price_pairs")

-- Adding a new authenticated upstream means touching three files:
--   1. UPSTREAMS map below — host + path_prefix + internal_location +
--      api_key_env + api_key_var
--   2. pricing.conf — `set $<api_key_var> '';` inside the matching
--      `/_internal/<name>/` block, otherwise ngx.location.capture's
--      `vars` injection silently no-ops
--   3. nginx.conf — `env <api_key_env>;` so worker processes can read
--      the variable via os.getenv at request time
-- A free-tier upstream (GeckoTerminal) needs only steps 1 and 2 (no
-- api_key_*), and its step 2 reduces to `set $upstream '';`.
local UPSTREAMS = {
    coingecko = {
        host = "pro-api.coingecko.com",
        path_prefix = "^/coingecko/",
        internal_location = "/_internal/coingecko",
        api_key_env = "COINGECKO_API_KEY",
        api_key_var = "cg_key",
    },
    geckoterminal = {
        host = "api.geckoterminal.com",
        path_prefix = "^/geckoterminal/",
        internal_location = "/_internal/geckoterminal",
        -- GeckoTerminal is free-tier only, no auth header.
    },
}

local upstream_name = ngx.var.proxy_upstream
local upstream_cfg = UPSTREAMS[upstream_name]
if not upstream_cfg then
    ngx.status = 500
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({ proxy_error = "unknown upstream", upstream = upstream_name }))
    return
end

local cache = ngx.shared.pricing_cache
local upstream_path = ngx.re.sub(ngx.var.uri, upstream_cfg.path_prefix, "/", "jo")
local args = ngx.var.args or ""
local cache_key = upstream_name .. ":" .. upstream_path .. "?" .. args

-- ngx.decode_args stops at its argument cap and reports "truncated".
-- A query we did not see in full may hide an extra parameter, so it
-- stays on the raw query-string cache.
local function decode_query(raw)
    local decoded, err = ngx.decode_args(raw)
    if err then
        return nil
    end
    return decoded
end

local parsed_price = nil
if upstream_name == "coingecko"
    and upstream_path == "/api/v3/simple/price"
    and args ~= ""
then
    parsed_price = price_pairs.parse(decode_query(args))
end
if not parsed_price
    and upstream_name == "coingecko"
    and args ~= ""
then
    local platform = upstream_path:match("^/api/v3/simple/token_price/([%w_%-]+)$")
    if platform then
        parsed_price = price_pairs.parse_token(platform, decode_query(args))
    end
end

-- CoinGecko's `usd` coin id is not the US dollar; consumers treating it as FX
-- would get a dust token, so substitute USDT (`tether`) and remap the response
-- key. Plain ids+vs queries do this in price_pairs so the stored quote is the
-- same one callers already fetch as `tether`. Queries with extra parameters
-- keep this whole-response alias and the original query-string cache key.
local capture_args = args
local aliased_usd = false
local requested_tether = false
if not parsed_price
    and upstream_name == "coingecko"
    and upstream_path == "/api/v3/simple/price"
    and args ~= ""
then
    local decoded = decode_query(args)
    local ids_raw = decoded and decoded.ids
    if type(ids_raw) == "table" then
        ids_raw = table.concat(ids_raw, ",")
    end
    if type(ids_raw) == "string" and ids_raw ~= "" then
        local parts = {}
        local seen_tether = false
        for token in ids_raw:gmatch("[^,]+") do
            local t = token:match("^%s*(.-)%s*$")
            if t and t ~= "" then
                local lower = string.lower(t)
                if lower == "usd" then
                    aliased_usd = true
                    if not seen_tether then
                        parts[#parts + 1] = "tether"
                        seen_tether = true
                    end
                elseif lower == "tether" then
                    requested_tether = true
                    if not seen_tether then
                        parts[#parts + 1] = t
                        seen_tether = true
                    end
                else
                    parts[#parts + 1] = t
                end
            end
        end
        if aliased_usd then
            decoded.ids = table.concat(parts, ",")
            capture_args = ngx.encode_args(decoded)
        end
    end
end

local function send(status, cache_status, body)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json"
    ngx.header["X-Cache-Status"] = cache_status
    ngx.print(body)
end

local function is_transient_upstream(status)
    status = tonumber(status) or 0
    return status == 0 or status == 408 or status == 429 or status >= 500
end

local function pair_fresh_key(canonical, vs)
    if parsed_price and parsed_price.kind == "token" then
        return "coingecko:token:" .. parsed_price.platform .. ":" .. canonical .. ":" .. vs
    end
    return "coingecko:pair:" .. canonical .. ":" .. vs
end

local function read_quote(key)
    local raw = cache:get(key)
    if type(raw) ~= "string" or raw == "" then
        return nil
    end
    return tonumber(raw)
end

local function fresh_quote(canonical, vs)
    return read_quote(pair_fresh_key(canonical, vs))
end

local function any_quote(canonical, vs)
    return fresh_quote(canonical, vs) or read_quote("stale:" .. pair_fresh_key(canonical, vs))
end

local function remember(key, body, ttl)
    local ok, err = cache:set(key, body, ttl)
    if not ok then
        ngx.log(ngx.WARN, "pricing-proxy cache:set failed for ", key, ": ", err)
    end
end

local function remember_pair(canonical, vs, value)
    local encoded = tostring(value)
    local key = pair_fresh_key(canonical, vs)
    remember(key, encoded, CACHE_TTL)
    remember("stale:" .. key, encoded, STALE_TTL)
end

local function remember_body(body)
    remember(cache_key, body, CACHE_TTL)
    remember("stale:" .. cache_key, body, STALE_TTL)
end

local resty_lock = require "resty.lock"
local lock = resty_lock:new("pricing_locks", { timeout = 5, exptime = 10 })
local elapsed
local locked = false

local function acquire_lock()
    if locked or not lock then
        return
    end
    elapsed = lock:lock(price_pairs.lock_key(parsed_price, cache_key))
    locked = elapsed ~= nil
end

local function release_lock()
    if locked then
        lock:unlock()
        locked = false
    end
end

local function unlock_and_fail(status, detail, upstream_status)
    release_lock()
    ngx.log(ngx.WARN, "pricing-proxy reject ", upstream_name, " ", cache_key, ": ", detail or "")
    send(status, "MISS", cjson.encode({
        proxy_error = "upstream invalid",
        upstream = upstream_name,
        upstream_status = upstream_status,
        detail = detail,
    }))
end

local function invalid_detail(data)
    if data == nil then
        return "non-JSON body"
    end
    if type(data) ~= "table" then
        return "non-object body"
    end
    -- Reject any top-level field whose name starts with "error" *and* carries a
    -- truthy value. CoinGecko Pro returns HTTP 200 with an `error_message`
    -- envelope on quota exhaustion or bad params; GeckoTerminal wraps failures
    -- in an `errors` array. Gating on the value (not just presence) avoids a
    -- false reject if an upstream ever ships a legitimate `errors: []` or
    -- `error_count: 0` diagnostic alongside a successful payload.
    for k, v in pairs(data) do
        if type(k) == "string" and k:sub(1, 5) == "error" then
            local tripped =
                (type(v) == "table"   and next(v) ~= nil) or
                (type(v) == "string"  and v ~= "")        or
                (type(v) == "number"  and v ~= 0)         or
                (type(v) == "boolean" and v)
            if tripped then
                return "top-level " .. k .. " field present"
            end
        end
    end
    -- CoinGecko Pro also wraps quota errors in `status.error_message`, which
    -- the wildcard above does not catch because the outer key is `status`.
    if type(data.status) == "table" and data.status.error_message then
        return "status.error_message: " .. tostring(data.status.error_message)
    end
    return nil
end

local function try_serve_stale(upstream_status)
    local stale = cache:get("stale:" .. cache_key)
    if type(stale) == "string" and stale ~= "" then
        release_lock()
        ngx.log(ngx.WARN, "pricing-proxy serving STALE ", upstream_name, " ", cache_key,
            " upstream_status=", tostring(upstream_status))
        send(200, "STALE", stale)
        return true
    end
    return false
end

local function send_assembled(assembled, cache_status, upstream_status)
    local body = cjson.encode(assembled)
    if type(body) ~= "string" then
        return false
    end
    release_lock()
    if cache_status == "STALE" then
        ngx.log(ngx.WARN, "pricing-proxy serving STALE ", upstream_name, " ", cache_key,
            " upstream_status=", tostring(upstream_status))
    end
    send(200, cache_status, body)
    return true
end

local function try_serve_fresh_pairs()
    if not parsed_price then
        return false
    end
    local assembled = price_pairs.assemble(parsed_price, fresh_quote)
    if assembled == nil then
        return false
    end
    return send_assembled(assembled, "HIT", nil)
end

-- Set only for the duration of one pair or token fill. It prefers the
-- numbers copied before the upstream call, then a stale entry for a
-- number this request did not already have. It must not re-read a fresh
-- key: that key can expire while the call runs.
local fill_lookup = nil

local function try_serve_pair_stale(upstream_status)
    if not parsed_price then
        return false
    end
    local lookup = fill_lookup or any_quote
    local assembled = price_pairs.assemble(parsed_price, lookup)
    if assembled == nil then
        return false
    end
    local status = "STALE"
    if not fill_lookup then
        status = price_pairs.uses_stale(parsed_price, fresh_quote) and "STALE" or "HIT"
    end
    return send_assembled(assembled, status, upstream_status)
end

-- Inject the API key (if any) and the upstream hostname as request-scoped
-- nginx variables so the internal subrequest can place the key on the
-- upstream header and feed the hostname to a variable-based proxy_pass.
-- The latter forces nginx to use the runtime resolver (with `ipv6=off`)
-- per request instead of the boot-time DNS, which on this network
-- otherwise hands IPv6 endpoints to proxy_pass and breaks with
-- `connect() failed (101: Network unreachable)`.
local function capture(query)
    local capture_vars = { upstream = upstream_cfg.host }
    if upstream_cfg.api_key_var then
        capture_vars[upstream_cfg.api_key_var] = os.getenv(upstream_cfg.api_key_env) or ""
    end
    return ngx.location.capture(upstream_cfg.internal_location .. upstream_path, {
        args = query,
        vars = capture_vars,
    })
end

local function decode_upstream(res)
    local data = cjson.decode(res.body or "")
    local detail = invalid_detail(data)
    if detail == "non-JSON body" then
        local snippet = (res.body or ""):sub(1, 200):gsub("\n", " ")
        ngx.log(ngx.WARN, "pricing-proxy non-JSON body ", upstream_name, " ", cache_key,
            " upstream_status=", tostring(res.status),
            " body_len=", tostring(#(res.body or "")),
            " body[0..200]=", snippet)
    end
    return data, detail
end

-- Transport failures may serve the last good body. An HTTP 200 error
-- envelope must not: it is not cached and it is not a reason to reuse stale.
local function fail_or_stale(res, detail)
    if res.status ~= 200 and is_transient_upstream(res.status) then
        if try_serve_pair_stale(res.status) then
            return
        end
        if try_serve_stale(res.status) then
            return
        end
    end
    return unlock_and_fail(502, detail or ("upstream HTTP " .. tostring(res.status)), res.status)
end

if try_serve_fresh_pairs() then
    return
end

-- A composed pair or token_price body must not be a fresh hit. It can
-- contain a quote copied from an older entry, and a new 60s TTL on the
-- whole query would serve that number after its own entry expired.
-- Pair hits go through try_serve_fresh_pairs only.
if not parsed_price then
    local cached = cache:get(cache_key)
    if cached then
        send(200, "HIT", cached)
        return
    end
end

acquire_lock()

if try_serve_fresh_pairs() then
    return
end

if not parsed_price and elapsed and elapsed > 0 then
    local cached = cache:get(cache_key)
    if cached then
        release_lock()
        send(200, "HIT", cached)
        return
    end
end

if parsed_price then
    -- Copy fresh numbers before the upstream call. The 60s entry can expire while it runs.
    local known = {}
    local function local_quote(canonical, vs)
        return known[canonical .. "\0" .. vs]
    end
    for _, resp in ipairs(parsed_price.responses) do
        for _, vs in ipairs(resp.vs) do
            local fresh = fresh_quote(resp.canonical, vs)
            if fresh ~= nil then
                known[resp.canonical .. "\0" .. vs] = fresh
            end
        end
    end
    fill_lookup = function(canonical, vs)
        local copied = known[canonical .. "\0" .. vs]
        if type(copied) == "number" then
            return copied
        end
        return read_quote("stale:" .. pair_fresh_key(canonical, vs))
    end
    local missing = price_pairs.missing(parsed_price, local_quote)
    local missing_detail = "simple/price quotes missing"
    local after_detail = "simple/price quote missing after upstream"
    local encode_detail = "simple/price encode failed"
    local query = price_pairs.upstream_query
    if parsed_price.kind == "token" then
        missing_detail = "token_price quotes missing"
        after_detail = "token_price quote missing after upstream"
        encode_detail = "token_price encode failed"
        query = price_pairs.upstream_contracts
    end
    -- The fresh check above can lose to another worker when this request
    -- does not hold the lock. The numbers are already in `known`. Serving
    -- them is a hit. A 502 here would reject a list that is fresh.
    if #missing == 0 then
        local assembled = price_pairs.assemble(parsed_price, local_quote)
        if assembled == nil or not send_assembled(assembled, "HIT", nil) then
            return unlock_and_fail(502, missing_detail, nil)
        end
        return
    end
    local res = capture(query(missing))
    if res.status ~= 200 then
        return fail_or_stale(res, "upstream HTTP " .. tostring(res.status))
    end
    local data, detail = decode_upstream(res)
    if detail then
        return fail_or_stale(res, detail)
    end
    for _, quote in ipairs(price_pairs.numeric_quotes(data, missing)) do
        remember_pair(quote.canonical, quote.vs, quote.value)
        known[quote.canonical .. "\0" .. quote.vs] = quote.value
    end
    local assembled = price_pairs.assemble(parsed_price, local_quote)
    if assembled == nil then
        return unlock_and_fail(502, after_detail, res.status)
    end
    local body = cjson.encode(assembled)
    if type(body) ~= "string" then
        return unlock_and_fail(502, encode_detail, res.status)
    end
    -- Stale copy only. A fresh whole-query entry would extend a copied quote.
    remember("stale:" .. cache_key, body, STALE_TTL)
    release_lock()
    send(200, "MISS", body)
    return
end

local res = capture(capture_args)

if res.status ~= 200 then
    return fail_or_stale(res, "upstream HTTP " .. tostring(res.status))
end

local data, detail = decode_upstream(res)
if detail then
    return unlock_and_fail(502, detail, res.status)
end

local body = res.body
if aliased_usd then
    if type(data.tether) ~= "table" then
        return unlock_and_fail(502, "aliased usd: upstream tether object missing", res.status)
    end
    data.usd = data.tether
    if not requested_tether then
        data.tether = nil
    end
    body = cjson.encode(data)
end

remember_body(body)
release_lock()

send(200, "MISS", body)
