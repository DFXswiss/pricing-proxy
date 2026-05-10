-- Pricing-proxy request handler (CoinGecko only).
-- Caches upstream responses after validating the body. A response that
-- looks like an upstream error must never be served as a valid price.
--
-- TTL tiers:
--   * /coins/{id}/history?date=...  — unbounded (date-pinned, immutable)
--   * everything else               — 60s hard cap

local CACHE_TTL_DEFAULT = 60

-- /coins/{id}/history?date=DD-MM-YYYY returns a date-pinned snapshot that is
-- immutable once the day is over. Cache those forever (TTL 0 = no expiry in
-- lua_shared_dict; entries fall out only on container restart or LRU pressure
-- on the 50m shared dict). Caveat: a /history?date=<today> request will pin
-- the intraday snapshot until restart.
local HISTORY_PATTERN = "^/api/v3/coins/[^/]+/history$"

local upstream = ngx.var.proxy_upstream
if upstream ~= "coingecko" then
    ngx.status = 500
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({ proxy_error = "unknown upstream", upstream = upstream }))
    return
end

local cache = ngx.shared.pricing_cache
local upstream_path = ngx.re.sub(ngx.var.uri, "^/coingecko/", "/", "jo")
local args = ngx.var.args or ""
local cache_key = "coingecko:" .. upstream_path .. "?" .. args

local function send(status, cache_status, body)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json"
    ngx.header["X-Cache-Status"] = cache_status
    ngx.print(body)
end

local cached = cache:get(cache_key)
if cached then
    send(200, "HIT", cached)
    return
end

-- Coalesce concurrent misses so only one request per key reaches upstream
local resty_lock = require "resty.lock"
local lock = resty_lock:new("pricing_locks", { timeout = 5, exptime = 10 })
local elapsed
if lock then elapsed = lock:lock(cache_key) end

if elapsed and elapsed > 0 then
    cached = cache:get(cache_key)
    if cached then
        if lock then lock:unlock() end
        send(200, "HIT", cached)
        return
    end
end

local function unlock_and_fail(status, detail, upstream_status)
    if lock then lock:unlock() end
    ngx.log(ngx.WARN, "pricing-proxy reject coingecko ", cache_key, ": ", detail or "")
    send(status, "MISS", cjson.encode({
        proxy_error = "upstream invalid",
        upstream = "coingecko",
        upstream_status = upstream_status,
        detail = detail,
    }))
end

-- Inject the API key and the upstream hostname as request-scoped nginx
-- variables so the internal subrequest can place the key on the upstream
-- header and feed the hostname to a variable-based proxy_pass. The
-- latter forces nginx to use the runtime resolver (with `ipv6=off`)
-- per request instead of the boot-time DNS, which on this network
-- otherwise hands IPv6 endpoints to proxy_pass and breaks with
-- `connect() failed (101: Network unreachable)`.
local res = ngx.location.capture("/_internal/coingecko" .. upstream_path, {
    args = args,
    vars = {
        cg_key = os.getenv("COINGECKO_API_KEY") or "",
        upstream = "pro-api.coingecko.com",
    },
})

if res.status ~= 200 then
    return unlock_and_fail(502, "upstream HTTP " .. tostring(res.status), res.status)
end

local data = cjson.decode(res.body or "")
if data == nil then
    local snippet = (res.body or ""):sub(1, 200):gsub("\n", " ")
    ngx.log(ngx.WARN, "pricing-proxy non-JSON body ", cache_key,
        " upstream_status=", tostring(res.status),
        " body_len=", tostring(#(res.body or "")),
        " body[0..200]=", snippet)
    return unlock_and_fail(502, "non-JSON body", res.status)
end
if type(data) ~= "table" then
    return unlock_and_fail(502, "non-object body", res.status)
end

-- CoinGecko Pro returns 200 with an error envelope for quota / bad params
if data.status and type(data.status) == "table" and data.status.error_message then
    return unlock_and_fail(502, "coingecko: " .. tostring(data.status.error_message), res.status)
end
if data.error_message then
    return unlock_and_fail(502, "coingecko: " .. tostring(data.error_message), res.status)
end
if data.error then
    return unlock_and_fail(502, "coingecko error field present", res.status)
end

local ttl = CACHE_TTL_DEFAULT
if ngx.re.find(upstream_path, HISTORY_PATTERN, "jo") then
    ttl = 0
end

local ok, err = cache:set(cache_key, res.body, ttl)
if not ok then
    ngx.log(ngx.WARN, "pricing-proxy cache:set failed for ", cache_key, ": ", err)
end
if lock then lock:unlock() end

send(200, "MISS", res.body)
