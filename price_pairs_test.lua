-- Plain Lua assertions for price_pairs. Run with: lua price_pairs_test.lua
package.path = "./?.lua;" .. package.path
local P = require("price_pairs")

local function fail(msg)
    io.stderr:write(msg, "\n")
    os.exit(1)
end

local function eq(actual, expected, msg)
    if actual ~= expected then
        fail(msg .. ": got " .. tostring(actual) .. ", expected " .. tostring(expected))
    end
end

local function has_quote(obj, coin, vs, value, msg)
    if type(obj) ~= "table" or type(obj[coin]) ~= "table" then
        fail(msg .. ": missing " .. coin)
    end
    eq(obj[coin][vs], value, msg .. " " .. coin .. "/" .. vs)
end

local store = {}
local function lookup(canonical, vs)
    return store[canonical .. ":" .. vs]
end

local function reset()
    store = {}
end

-- Combined currencies and a single currency are the same quotes.
local combined = P.parse({ ids = "tether", vs_currencies = "eur,btc" })
local eur_only = P.parse({ ids = "tether", vs_currencies = "eur" })
if combined == nil or eur_only == nil then
    fail("plain queries must parse")
end
eq(#P.missing(combined, lookup), 2, "both quotes missing")
eq(P.upstream_query(P.missing(combined, lookup)), "ids=tether&vs_currencies=btc,eur", "upstream sorts vs")

store["tether:eur"] = 0.92
eq(#P.missing(combined, lookup), 1, "eur is already known")
eq(P.missing(combined, lookup)[1].vs, "btc", "only btc is fetched")
eq(P.assemble(eur_only, lookup).tether.eur, 0.92, "single eur reuses the shared quote")
eq(P.assemble(combined, lookup), nil, "btc still missing")

store["tether:btc"] = 0.00001
local body = P.assemble(combined, lookup)
has_quote(body, "tether", "eur", 0.92, "combined")
has_quote(body, "tether", "btc", 0.00001, "combined")
eq(P.uses_stale(combined, lookup), false, "both fresh")

-- ids=usd is the tether quote, answered under the key the client used.
reset()
local as_usd = P.parse({ ids = "usd", vs_currencies = "eur,chf" })
local as_tether = P.parse({ ids = "Tether", vs_currencies = "chf" })
eq(as_usd.responses[1].canonical, "tether", "usd id is stored as tether")
eq(as_usd.responses[1].key, "usd", "client still sees usd")
store["tether:eur"] = 0.9
store["tether:chf"] = 0.8
body = P.assemble(as_usd, lookup)
has_quote(body, "usd", "eur", 0.9, "aliased")
has_quote(body, "usd", "chf", 0.8, "aliased")
eq(body.tether, nil, "tether key omitted when not requested")
has_quote(P.assemble(as_tether, lookup), "tether", "chf", 0.8, "case-folded tether")

local both = P.parse({ ids = "usd,tether", vs_currencies = "eur" })
eq(#both.responses, 2, "usd and tether are both answered")
body = P.assemble(both, lookup)
eq(body.usd.eur, 0.9, "usd side")
eq(body.tether.eur, 0.9, "tether side")

-- usd-coin is not the usd alias. Extra parameters stay on the old path.
local usdc = P.parse({ ids = "usd-coin", vs_currencies = "usd" })
eq(usdc.responses[1].canonical, "usd-coin", "usd-coin is not rewritten")
eq(P.parse({ ids = "tether", vs_currencies = "eur", include_24hr_change = "true" }), nil, "extra param")
eq(P.parse({ ids = "tether" }), nil, "vs required")
eq(P.parse({ ids = "bad id", vs_currencies = "eur" }), nil, "unsafe id")

local got = P.numeric_quotes({
    tether = { eur = 0.91, btc = "nope", chf = 0.7 },
    bitcoin = { eur = 50000 },
}, {
    { canonical = "tether", vs = "eur" },
    { canonical = "tether", vs = "btc" },
})
eq(#got, 1, "only numeric requested quotes")
eq(got[1].value, 0.91, "eur value")

reset()
store["tether:btc"] = 0.00002
eq(P.uses_stale(combined, function(canonical, vs)
    if canonical == "tether" and vs == "eur" then
        return nil
    end
    return lookup(canonical, vs)
end), true, "missing fresh quote needs stale")

eq(P.lock_key({ responses = {} }, "coingecko:/api/v3/simple/price?ids=tether&vs_currencies=eur"), "coingecko:simple-price", "pair fills share one lock")
eq(P.lock_key(nil, "coingecko:/api/v3/simple/token_price/ethereum?contract_addresses=0xabc&vs_currencies=usd"), "coingecko:/api/v3/simple/token_price/ethereum?contract_addresses=0xabc&vs_currencies=usd", "non-pair lock is the cache key")

print("ok")
