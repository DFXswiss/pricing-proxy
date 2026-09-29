-- Split CoinGecko /simple/price into one cacheable quote per coin and
-- currency, and /simple/token_price/<platform> into one quote per
-- contract address and currency. Callers that ask for different lists
-- then share the quotes they have in common. The `usd` coin id is not
-- the US dollar; it is stored under `tether` and still answered as
-- `usd`. Token addresses are not rewritten.

local M = {}

local function as_string(v)
    if type(v) == "string" then
        return v
    end
    if type(v) ~= "table" then
        return nil
    end
    local parts = {}
    for i = 1, #v do
        if type(v[i]) ~= "string" then
            return nil
        end
        parts[#parts + 1] = v[i]
    end
    return table.concat(parts, ",")
end

-- Lowercase, trim, drop empties and duplicates. Reject anything that is
-- not a single CoinGecko id token so a weird query keeps the old path.
local function tokens(raw)
    if type(raw) ~= "string" or raw == "" then
        return nil
    end
    local out, seen = {}, {}
    for token in raw:gmatch("[^,]+") do
        local t = token:match("^%s*(.-)%s*$")
        if t and t ~= "" then
            if not t:match("^[%w_%-%.]+$") then
                return nil
            end
            local lower = string.lower(t)
            if not seen[lower] then
                seen[lower] = true
                out[#out + 1] = lower
            end
        end
    end
    if #out == 0 then
        return nil
    end
    return out
end

-- nil means "do not share quotes": missing ids/vs, or any other parameter
-- (precision, market cap, …) whose body is not a single number per pair.
function M.parse(args)
    if type(args) ~= "table" then
        return nil
    end
    for key in pairs(args) do
        if key ~= "ids" and key ~= "vs_currencies" then
            return nil
        end
    end
    local ids = tokens(as_string(args.ids))
    local vs = tokens(as_string(args.vs_currencies))
    if not ids or not vs then
        return nil
    end

    local responses, seen_key = {}, {}
    for _, id in ipairs(ids) do
        local canonical, key
        if id == "usd" then
            canonical, key = "tether", "usd"
        else
            canonical, key = id, id
        end
        if not seen_key[key] then
            seen_key[key] = true
            responses[#responses + 1] = {
                key = key,
                canonical = canonical,
                vs = vs,
            }
        end
    end
    return { responses = responses }
end

-- Addresses must be 20-byte hex. One bad address, or an empty slot,
-- keeps the old path. A trailing comma is an empty slot.
local function contract_addresses(raw)
    if type(raw) ~= "string" or raw == "" then
        return nil
    end
    local out, seen = {}, {}
    local i = 1
    while i <= #raw + 1 do
        local comma = raw:find(",", i, true)
        local token
        if comma then
            token = raw:sub(i, comma - 1)
            i = comma + 1
        else
            token = raw:sub(i)
            i = #raw + 2
        end
        local t = token:match("^%s*(.-)%s*$")
        if not t or t == "" then
            return nil
        end
        local lower = string.lower(t)
        -- Lua patterns have no counted repetition. 0x plus 40 hex digits is 42 characters.
        if #lower ~= 42 or not lower:match("^0x[0-9a-f]+$") then
            return nil
        end
        if not seen[lower] then
            seen[lower] = true
            out[#out + 1] = lower
        end
    end
    if #out == 0 then
        return nil
    end
    return out
end

-- nil means "do not share quotes": bad platform, missing
-- contract_addresses/vs, or any other parameter.
function M.parse_token(platform, args)
    if type(platform) ~= "string" or not platform:match("^[%w_%-]+$") then
        return nil
    end
    if type(args) ~= "table" then
        return nil
    end
    for key in pairs(args) do
        if key ~= "contract_addresses" and key ~= "vs_currencies" then
            return nil
        end
    end
    local addresses = contract_addresses(as_string(args.contract_addresses))
    local vs = tokens(as_string(args.vs_currencies))
    if not addresses or not vs then
        return nil
    end

    local responses, seen_key = {}, {}
    for _, address in ipairs(addresses) do
        if not seen_key[address] then
            seen_key[address] = true
            responses[#responses + 1] = {
                key = address,
                canonical = address,
                vs = vs,
            }
        end
    end
    return {
        kind = "token",
        platform = string.lower(platform),
        responses = responses,
    }
end

function M.lock_key(parsed, cache_key)
    if parsed then
        if parsed.kind == "token" then
            return "coingecko:token-price"
        end
        return "coingecko:simple-price" -- pair fills share one lock so two query strings for the same quote cannot both miss.
    end
    return cache_key
end

function M.missing(parsed, lookup)
    local missing, seen = {}, {}
    for _, resp in ipairs(parsed.responses) do
        for _, vs in ipairs(resp.vs) do
            local dedupe = resp.canonical .. "\0" .. vs
            if not seen[dedupe] and lookup(resp.canonical, vs) == nil then
                seen[dedupe] = true
                missing[#missing + 1] = { canonical = resp.canonical, vs = vs }
            end
        end
    end
    return missing
end

local function missing_query(missing, id_name)
    local ids, vs = {}, {}
    local seen_id, seen_vs = {}, {}
    for _, pair in ipairs(missing) do
        if not seen_id[pair.canonical] then
            seen_id[pair.canonical] = true
            ids[#ids + 1] = pair.canonical
        end
        if not seen_vs[pair.vs] then
            seen_vs[pair.vs] = true
            vs[#vs + 1] = pair.vs
        end
    end
    table.sort(ids)
    table.sort(vs)
    return id_name .. "=" .. table.concat(ids, ",") .. "&vs_currencies=" .. table.concat(vs, ",")
end

function M.upstream_query(missing)
    return missing_query(missing, "ids")
end

function M.upstream_contracts(missing)
    return missing_query(missing, "contract_addresses")
end

function M.numeric_quotes(data, missing)
    local got = {}
    if type(data) ~= "table" then
        return got
    end
    for _, pair in ipairs(missing) do
        local coin = data[pair.canonical]
        if type(coin) == "table" and type(coin[pair.vs]) == "number" then
            got[#got + 1] = {
                canonical = pair.canonical,
                vs = pair.vs,
                value = coin[pair.vs],
            }
        end
    end
    return got
end

-- nil if any requested quote is absent. Otherwise a JSON-ready object
-- keyed the way the client asked (`usd` stays `usd`).
function M.assemble(parsed, lookup)
    local out = {}
    for _, resp in ipairs(parsed.responses) do
        local quotes = {}
        for _, vs in ipairs(resp.vs) do
            local value = lookup(resp.canonical, vs)
            if type(value) ~= "number" then
                return nil
            end
            quotes[vs] = value
        end
        out[resp.key] = quotes
    end
    return out
end

-- This drops pairs the lookup cannot serve because upstream omits entries without a price,
-- and rejecting the whole list would discard quotes that did arrive. M.assemble must stay
-- strict: nil tells callers to go upstream and tells the stale path it cannot cover the request.
function M.assemble_available(parsed, lookup)
    local out = {}
    for _, resp in ipairs(parsed.responses) do
        local quotes = {}
        for _, vs in ipairs(resp.vs) do
            local value = lookup(resp.canonical, vs)
            if type(value) == "number" then
                quotes[vs] = value
            end
        end
        if next(quotes) ~= nil then
            out[resp.key] = quotes
        end
    end
    return out
end

function M.uses_stale(parsed, fresh_lookup)
    for _, resp in ipairs(parsed.responses) do
        for _, vs in ipairs(resp.vs) do
            if fresh_lookup(resp.canonical, vs) == nil then
                return true
            end
        end
    end
    return false
end

return M
