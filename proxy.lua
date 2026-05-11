-- Pricing-proxy request handler.
--
-- Selects a per-route upstream config (host, optional API key, internal
-- subrequest location), caches upstream responses for at most 60s
-- (project-wide hard limit), and only caches after validating the body.
-- A response that looks like an upstream error must never be served as
-- a valid price.

local CACHE_TTL = 60

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
    ngx.log(ngx.WARN, "pricing-proxy reject ", upstream_name, " ", cache_key, ": ", detail or "")
    send(status, "MISS", cjson.encode({
        proxy_error = "upstream invalid",
        upstream = upstream_name,
        upstream_status = upstream_status,
        detail = detail,
    }))
end

-- Inject the API key (if any) and the upstream hostname as request-scoped
-- nginx variables so the internal subrequest can place the key on the
-- upstream header and feed the hostname to a variable-based proxy_pass.
-- The latter forces nginx to use the runtime resolver (with `ipv6=off`)
-- per request instead of the boot-time DNS, which on this network
-- otherwise hands IPv6 endpoints to proxy_pass and breaks with
-- `connect() failed (101: Network unreachable)`.
local capture_vars = { upstream = upstream_cfg.host }
if upstream_cfg.api_key_var then
    capture_vars[upstream_cfg.api_key_var] = os.getenv(upstream_cfg.api_key_env) or ""
end

local res = ngx.location.capture(upstream_cfg.internal_location .. upstream_path, {
    args = args,
    vars = capture_vars,
})

if res.status ~= 200 then
    return unlock_and_fail(502, "upstream HTTP " .. tostring(res.status), res.status)
end

local data = cjson.decode(res.body or "")
if data == nil then
    local snippet = (res.body or ""):sub(1, 200):gsub("\n", " ")
    ngx.log(ngx.WARN, "pricing-proxy non-JSON body ", upstream_name, " ", cache_key,
        " upstream_status=", tostring(res.status),
        " body_len=", tostring(#(res.body or "")),
        " body[0..200]=", snippet)
    return unlock_and_fail(502, "non-JSON body", res.status)
end
if type(data) ~= "table" then
    return unlock_and_fail(502, "non-object body", res.status)
end

-- Reject any top-level field whose name starts with "error". CoinGecko Pro
-- returns HTTP 200 with an `error_message` envelope on quota exhaustion or
-- bad params; GeckoTerminal wraps failures in an `errors` array. The
-- wildcard catches both without per-upstream conditionals.
for k, _ in pairs(data) do
    if type(k) == "string" and k:sub(1, 5) == "error" then
        return unlock_and_fail(502, "top-level " .. k .. " field present", res.status)
    end
end

-- CoinGecko Pro also wraps quota errors in `status.error_message`, which
-- the wildcard above does not catch because the outer key is `status`.
if type(data.status) == "table" and data.status.error_message then
    return unlock_and_fail(502, "status.error_message: " .. tostring(data.status.error_message), res.status)
end

local ok, err = cache:set(cache_key, res.body, CACHE_TTL)
if not ok then
    ngx.log(ngx.WARN, "pricing-proxy cache:set failed for ", cache_key, ": ", err)
end
if lock then lock:unlock() end

send(200, "MISS", res.body)
