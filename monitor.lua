-- Pricing-proxy quota monitor.
--
-- Polls the CoinGecko Pro `/api/v3/key` endpoint at a fixed cadence, compares
-- the remaining monthly credit against two thresholds, and pushes a Telegram
-- message when a threshold is crossed. Self-deduplicates per threshold so a
-- persistent over-quota condition does not spam the channel, and emits a
-- single recovery notification when the quota drops back below WARN.
--
-- Runs only when both TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID are set in the
-- environment; otherwise the proxy keeps working but no alerts are sent.
--
-- All state lives in the `monitor_state` shared dict (see nginx.conf) so a
-- worker restart resets the dedup window — acceptable because the next probe
-- inside CHECK_INTERVAL_S will re-alert if the condition still holds.

local CHECK_INTERVAL_S    = 1800       -- 30 min between probes
local STARTUP_DELAY_S     = 60         -- give the proxy time to warm up
local ALERT_DEDUPE_S      = 86400      -- 24 h per (threshold, key) tuple
local WARN_THRESHOLD_PCT  = 80         -- soft warning at 80% used
local CRIT_THRESHOLD_PCT  = 95         -- critical at 95% used
local STATE_KEY_LAST_ALERT_WARN = "last_alert_warn"
local STATE_KEY_LAST_ALERT_CRIT = "last_alert_crit"
local STATE_KEY_LAST_PCT  = "last_pct"

local _M = {}

local function env(name)
    local v = os.getenv(name)
    if v == nil or v == "" then return nil end
    return v
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
            res and res.status or "nil", " body=", (res and res.body) or "nil")
        return false
    end
    return true
end

local function fetch_quota()
    -- Reuse the existing /_internal/coingecko upstream so the same key plumbing
    -- (request-scoped vars, runtime resolver, gzip-strip) handles this probe.
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
        level == "critical" and "🚨" or "⚠️",
        level == "critical" and "CRITICAL" or "WARNING",
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

local function should_alert(state, key, now)
    local last = state:get(key)
    if last and (now - last) < ALERT_DEDUPE_S then return false end
    return true
end

local function check()
    local state = ngx.shared.monitor_state
    if not state then
        ngx.log(ngx.ERR, "monitor: shared dict monitor_state not configured")
        return
    end

    local q = fetch_quota()
    if not q then return end

    local now = ngx.time()
    local prev_pct = tonumber(state:get(STATE_KEY_LAST_PCT) or "0")
    state:set(STATE_KEY_LAST_PCT, tostring(q.used_pct))

    ngx.log(ngx.NOTICE, string.format(
        "monitor: quota %s plan used=%d/%d (%.1f%%) remaining=%d",
        q.plan, q.used, q.credit, q.used_pct, q.remaining))

    if q.used_pct >= CRIT_THRESHOLD_PCT then
        if should_alert(state, STATE_KEY_LAST_ALERT_CRIT, now) then
            if send_telegram(format_alert("critical", q)) then
                state:set(STATE_KEY_LAST_ALERT_CRIT, now)
            end
        end
    elseif q.used_pct >= WARN_THRESHOLD_PCT then
        if should_alert(state, STATE_KEY_LAST_ALERT_WARN, now) then
            if send_telegram(format_alert("warning", q)) then
                state:set(STATE_KEY_LAST_ALERT_WARN, now)
            end
        end
    else
        -- Recovery path: if we were above WARN previously and dropped below it,
        -- emit a single recovery message and clear the dedup so the next breach
        -- alerts again immediately.
        if prev_pct >= WARN_THRESHOLD_PCT then
            send_telegram(format_recovery(q))
            state:delete(STATE_KEY_LAST_ALERT_WARN)
            state:delete(STATE_KEY_LAST_ALERT_CRIT)
        end
    end
end

function _M.start()
    -- Only one worker runs the timer; otherwise N workers would probe and
    -- alert in parallel.
    if ngx.worker.id() ~= 0 then return end

    -- Defer the first probe so the proxy is fully up (resolver primed, locks
    -- ready) before we issue an internal subrequest.
    local ok, err = ngx.timer.at(STARTUP_DELAY_S, function(premature)
        if premature then return end
        check()
        local ok2, err2 = ngx.timer.every(CHECK_INTERVAL_S, function(p) if not p then check() end end)
        if not ok2 then ngx.log(ngx.ERR, "monitor: timer.every failed: ", err2) end
    end)
    if not ok then ngx.log(ngx.ERR, "monitor: timer.at failed: ", err) end
end

-- Expose the latest snapshot for the /quota debug endpoint.
function _M.snapshot()
    local state = ngx.shared.monitor_state
    if not state then return nil end
    local pct = tonumber(state:get(STATE_KEY_LAST_PCT) or "")
    return { last_pct = pct }
end

return _M
