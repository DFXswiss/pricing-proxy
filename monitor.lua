-- Pricing-proxy quota monitor.
--
-- Polls CoinGecko's `/api/v3/key` endpoint at a fixed cadence, classifies the
-- remaining monthly credit into healthy / warning / critical, and pushes
-- Telegram messages on every state transition plus a periodic re-alert while
-- the system stays in a non-healthy state.
--
-- Architecture note: ngx.location.capture is not callable from a timer
-- callback, so the timer cannot do the upstream work directly. Instead the
-- timer issues a loopback TCP request to /_internal/quota_probe, which is a
-- normal request location whose content_by_lua_block calls run_check() in a
-- real request context where subrequests work. The probe location is
-- firewalled to 127.0.0.1 in pricing.conf so an external caller cannot
-- trigger an alert.
--
-- Runs only when both TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID are set in the
-- environment; otherwise the proxy keeps working but no alerts are sent. All
-- monitor state lives in the `monitor_state` shared dict so a worker restart
-- resets it — acceptable because the next probe inside CHECK_INTERVAL_S will
-- re-derive the level and alert if the condition still holds.

local CHECK_INTERVAL_S    = 1800       -- 30 min between probes
local STARTUP_DELAY_S     = 60         -- give the listener + resolver time
local REALERT_INTERVAL_S  = 86400      -- 24 h re-alert while still in WARN/CRIT
local WARN_THRESHOLD_PCT  = 80
local CRIT_THRESHOLD_PCT  = 95

-- Levels are ordered so we can compare numerically: 0=healthy, 1=warn, 2=crit.
local LEVEL_HEALTHY = 0
local LEVEL_WARN    = 1
local LEVEL_CRIT    = 2

local STATE_LAST_LEVEL    = "last_level"
local STATE_LAST_ALERT_TS = "last_alert_ts"
local STATE_LAST_PCT      = "last_pct"

local _M = {}

local function env(name)
    local v = os.getenv(name)
    if v == nil or v == "" then return nil end
    return v
end

local function level_for(pct)
    if pct >= CRIT_THRESHOLD_PCT then return LEVEL_CRIT end
    if pct >= WARN_THRESHOLD_PCT then return LEVEL_WARN end
    return LEVEL_HEALTHY
end

local function send_telegram(text)
    local token = env("TELEGRAM_BOT_TOKEN")
    local chat_id = env("TELEGRAM_CHAT_ID")
    if not token or not chat_id then
        ngx.log(ngx.WARN, "monitor: telegram credentials not set, skipping send")
        return false
    end

    local body = cjson.encode({
        chat_id = chat_id,
        text = text,
        parse_mode = "Markdown",
        disable_web_page_preview = true,
    })

    local res = ngx.location.capture("/_internal/telegram_send", {
        method = ngx.HTTP_POST,
        body = body,
        vars = { tg_token = token },
    })

    if not res or res.status ~= 200 then
        ngx.log(ngx.ERR, "monitor: telegram send failed status=",
            res and res.status or "nil")
        return false
    end
    return true
end

local function fetch_quota()
    -- Bypass the public /coingecko/ location on purpose so the probe never
    -- lands in the 60 s response cache. Going straight to the internal
    -- upstream still reuses the same key plumbing, runtime resolver, and
    -- gzip stripping.
    local res = ngx.location.capture("/_internal/coingecko/api/v3/key", {
        vars = {
            cg_key = env("COINGECKO_API_KEY") or "",
            upstream = "pro-api.coingecko.com",
        },
    })

    if not res or res.status ~= 200 then
        ngx.log(ngx.WARN, "monitor: quota probe upstream status=",
            res and res.status or "nil")
        return nil
    end

    local data = cjson.decode(res.body or "")
    if type(data) ~= "table" then
        ngx.log(ngx.WARN, "monitor: quota probe returned non-object body")
        return nil
    end

    local credit    = tonumber(data.monthly_call_credit)
    local remaining = tonumber(data.current_remaining_monthly_calls)
    local used      = tonumber(data.current_total_monthly_calls)
    if not credit or not remaining or credit <= 0 then
        ngx.log(ngx.WARN, "monitor: quota probe missing fields")
        return nil
    end

    return {
        plan = data.plan or "unknown",
        credit = credit,
        used = used or (credit - remaining),
        remaining = remaining,
        used_pct = ((credit - remaining) / credit) * 100,
    }
end

local function format_alert(level, q)
    return string.format(
        "%s *CoinGecko quota %s* — %s plan\n\n" ..
        "Used: *%s* of *%s* (%.1f%%)\nRemaining: *%s*",
        level == LEVEL_CRIT and "🚨" or "⚠️",
        level == LEVEL_CRIT and "CRITICAL" or "WARNING",
        q.plan,
        tostring(q.used), tostring(q.credit), q.used_pct,
        tostring(q.remaining)
    )
end

local function format_recovery(q)
    return string.format(
        "✅ *CoinGecko quota recovered* — %s plan\n\n" ..
        "Used: *%s* of *%s* (%.1f%%)",
        q.plan, tostring(q.used), tostring(q.credit), q.used_pct
    )
end

-- Runs in a real request context (called from /_internal/quota_probe), so
-- ngx.location.capture is available here.
function _M.run_check()
    local state = ngx.shared.monitor_state
    if not state then
        ngx.log(ngx.ERR, "monitor: shared dict monitor_state not configured")
        return
    end

    local q = fetch_quota()
    if not q then return end

    local now = ngx.time()
    local level = level_for(q.used_pct)
    local last_level = tonumber(state:get(STATE_LAST_LEVEL) or "") or LEVEL_HEALTHY
    local last_ts = tonumber(state:get(STATE_LAST_ALERT_TS) or "") or 0

    state:set(STATE_LAST_PCT, tostring(q.used_pct))

    ngx.log(ngx.NOTICE, string.format(
        "monitor: quota %s plan used=%d/%d (%.1f%%) remaining=%d level=%d",
        q.plan, q.used, q.credit, q.used_pct, q.remaining, level))

    local function commit(new_level)
        state:set(STATE_LAST_LEVEL, tostring(new_level))
        state:set(STATE_LAST_ALERT_TS, now)
    end

    if level > last_level then
        -- Escalation: healthy→warn, healthy→crit, or warn→crit. Send an
        -- alert at the *current* level and persist the new state only on a
        -- successful Telegram delivery, so a transient failure retries on
        -- the next cycle.
        if send_telegram(format_alert(level, q)) then commit(level) end
    elseif level < last_level then
        -- De-escalation. Two cases:
        --   crit → warn:    send the warn alert (operator should still see it)
        --   warn|crit → healthy: send a recovery message
        local sent
        if level == LEVEL_HEALTHY then
            sent = send_telegram(format_recovery(q))
        else
            sent = send_telegram(format_alert(level, q))
        end
        if sent then commit(level) end
    elseif level ~= LEVEL_HEALTHY and (now - last_ts) >= REALERT_INTERVAL_S then
        -- Same non-healthy level, but the re-alert window has expired.
        if send_telegram(format_alert(level, q)) then commit(level) end
    end
end

-- Loopback trigger — ngx.location.capture is not callable from a timer
-- callback, so the timer pokes the internal probe endpoint over TCP and lets
-- the endpoint do the actual work in a real request context.
local function trigger_probe()
    local sock = ngx.socket.tcp()
    sock:settimeouts(2000, 2000, 30000) -- connect, send, read
    local ok, err = sock:connect("127.0.0.1", 8080)
    if not ok then
        ngx.log(ngx.ERR, "monitor: probe trigger connect failed: ", err)
        return
    end
    local _, err2 = sock:send(
        "GET /_internal/quota_probe HTTP/1.0\r\n" ..
        "Host: localhost\r\n" ..
        "Connection: close\r\n\r\n")
    if err2 then
        ngx.log(ngx.ERR, "monitor: probe trigger send failed: ", err2)
        sock:close()
        return
    end
    -- Drain the response so the connection closes cleanly. Alerting
    -- decisions are made inside the probe location, so the body is not
    -- consumed here.
    sock:receive("*a")
    sock:close()
end

function _M.start()
    -- Only one worker runs the timer; otherwise N workers would probe and
    -- alert in parallel.
    if ngx.worker.id() ~= 0 then return end

    -- Defer the first probe so the listener is up and the resolver is primed
    -- before we connect to ourselves.
    local ok, err = ngx.timer.at(STARTUP_DELAY_S, function(premature)
        if premature then return end
        trigger_probe()
        local ok2, err2 = ngx.timer.every(CHECK_INTERVAL_S, function(p)
            if not p then trigger_probe() end
        end)
        if not ok2 then ngx.log(ngx.ERR, "monitor: timer.every failed: ", err2) end
    end)
    if not ok then ngx.log(ngx.ERR, "monitor: timer.at failed: ", err) end
end

-- Expose the latest snapshot for the /quota debug endpoint.
function _M.snapshot()
    local state = ngx.shared.monitor_state
    if not state then return {} end
    return {
        last_pct = tonumber(state:get(STATE_LAST_PCT) or "") or nil,
        last_level = tonumber(state:get(STATE_LAST_LEVEL) or "") or nil,
        last_alert_ts = tonumber(state:get(STATE_LAST_ALERT_TS) or "") or nil,
    }
end

return _M
