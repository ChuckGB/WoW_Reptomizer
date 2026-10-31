-- Guards against the Argent Dawn freeze: a faction with ten turn-ins made the
-- solver's enumeration exponential and WoW killed the script mid-frame.
local fails, checks = 0, 0
local function check(l, got, want)
    checks = checks + 1
    local ok = (got == want); if not ok then fails = fails + 1 end
    print(string.format("   %-52s %14s  %s", l, tostring(got), ok and "OK" or ("<<< FAIL want "..tostring(want))))
end

local FACTIONS = {
    { name = "Argent Dawn", standingID = 5, barMin = 3000, barMax = 9000, barValue = 5016 },
}
function GetNumFactions() return #FACTIONS end
function GetFactionInfo(i)
    local f = FACTIONS[i]; if not f then return end
    return f.name, "", f.standingID, f.barMin, f.barMax, f.barValue, false, false, false, false
end
function ExpandFactionHeader() end
function CollapseFactionHeader() end
function UnitRace() return "Human", "Human" end
RepOptimizerDB = {}
_G.RepOptimizer = {}
dofile("../Optimizer.lua"); dofile("../Data.lua"); dofile("../Core.lua")
local RO, Core = RepOptimizer, RepOptimizer.Core

local ad
for _, f in ipairs(RO.Factions) do if f.key == "argentdawn" then ad = f end end
check("Argent Dawn has many sources (the trap)", #ad.sources >= 10, true)

local function singles(n, price)
    local t = {} for i = 1, n do t[i] = { qty = 1, price = price } end return t
end
-- a deep book for all five commission items, like a real high-pop realm
local scan = {}
for i, nm in ipairs({"Bone Fragments","Savage Frond","Crypt Fiend Parts",
                     "Dark Iron Scraps","Core of Elements"}) do
    scan[nm] = singles(900, 400 + i * 30)
end

print("SOLVE Argent Dawn to Exalted (the case that froze the client)")
local need = Core.RepNeeded(5016, 8)          -- 42000 - 5016
check("reputation needed", need, 36984)

local t0 = os.clock()
local res, err, sources = Core.Optimize(ad, scan, need)
local elapsed = os.clock() - t0
print(string.format("   solved in %.3f seconds", elapsed))
check("completes well inside one frame budget", elapsed < 0.5, true)
check("returns something usable", res ~= nil or err ~= nil, true)

if res then
    check("grouped 10 sources into few dimensions", #sources <= 4, true)
    local rows = Core.ShoppingRows(res, sources)
    check("still produces a shopping list", #rows > 0, true)
    local named = true
    for _, r in ipairs(rows) do if not scan[r.item] then named = false end end
    check("every row names a real listed item", named, true)
end

print("\nA FEASIBLE TARGET uses the five one-time quests first")
local t1 = os.clock()
local res2, _, src2 = Core.Optimize(ad, scan, 1000)
local e2 = os.clock() - t1
print(string.format("   solved in %.3f seconds", e2))
check("fast", e2 < 0.5, true)
check("reaches the target", res2 and res2.repAchieved >= 1000, true)
check("not flagged partial", res2 and res2.partial, false)

print("\nDEEP SUPPLY must not be truncated by the search cap")
do
    -- Bone Fragments is cheapest and deeply stocked; the others are dearer.
    -- The old hard cap of 500 turn-ins truncated the plan to ~1 turn-in of
    -- Bone Fragments and then reported the auction house as short of stock.
    local deep = {}
    deep["Bone Fragments"] = {}
    for i = 1, 120 do deep["Bone Fragments"][i] = { qty = 30, price = 30 * 300 } end
    for _, nm in ipairs({"Savage Frond","Crypt Fiend Parts","Dark Iron Scraps","Core of Elements"}) do
        deep[nm] = {}
        for i = 1, 40 do deep[nm][i] = { qty = 30, price = 30 * 900 } end
    end
    local t2 = os.clock()
    local r, e, s = Core.Optimize(ad, deep, 13211)
    local el = os.clock() - t2
    print(string.format("   solved in %.3f seconds", el))
    check("fast", el < 0.5, true)
    check("returns a plan", r ~= nil, true)

    local rowsD = Core.ShoppingRows(r, s)
    local boneQty = 0
    for _, rw in ipairs(rowsD) do
        if rw.item == "Bone Fragments" then boneQty = boneQty + rw.qty end
    end
    print(string.format("   bone fragments bought: %d of 3600 listed", boneQty))
    check("uses the cheap deep stock, not 30 of it", boneQty > 1000, true)

    check("flagged partial (8,400 items really is not enough)", r.partial, true)
    check("shortfall is honest", r.shortfall > 0, true)
    check("and it is the LISTINGS that are short, not our cap", r.capLimited, false)
end

print("\nCLOTH: a 20-item turn-in on a realm awash with Runecloth")
-- Exalted from Neutral is ~10,840 Runecloth, and a busy realm really can list
-- that much. CostCurve is O(lots x quantity), so without the axis cap the
-- quantity axis alone would run to five figures and stall the client.
do
    local sw
    for _, fx in ipairs(RO.Factions) do if fx.key == "stormwind" then sw = fx end end
    check("Stormwind is present to test", sw ~= nil, true)

    local deep = {}
    for _, item in ipairs(RO.ItemsForFaction(sw)) do deep[item] = {} end
    -- 1,200 stacks of 20 Runecloth, plus plenty of the lower cloths
    for i = 1, 1200 do
        deep["Runecloth"][i] = { qty = 20, price = 20 * (400 + (i % 50)) }
    end
    for _, item in ipairs({"Wool Cloth", "Silk Cloth", "Mageweave Cloth"}) do
        for i = 1, 200 do deep[item][i] = { qty = 20, price = 20 * 100 } end
    end

    FACTIONS[1].name = sw.name
    local t = os.clock()
    local r = Core.Optimize(sw, deep, 42000)
    local d = os.clock() - t
    print(string.format("   24,000 Runecloth listed, target Exalted: %.3fs", d))
    check("does not stall the client", d < 0.5, true)
    check("still returns a plan", r ~= nil, true)
    -- 4,000 items is 200 turn-ins = 15,000 rep, so 42,000 cannot be reached
    -- within the cap. That must be reported as OUR limit, never the market's.
    check("says the search was capped", r and r.searchCapped, true)
    check("and does not blame the auction house", r and r.capLimited, false)
end

print("\nWORST CASE: every faction, deep book, big target")
local worst = 0
for _, fac in ipairs(RO.Factions) do
    local s = {}
    for _, item in ipairs(RO.ItemsForFaction(fac)) do s[item] = singles(600, 500) end
    FACTIONS[1].name = fac.name
    local t = os.clock()
    Core.Optimize(fac, s, 40000)
    local d = os.clock() - t
    if d > worst then worst = d end
    print(string.format("   %-24s %.3fs", fac.name, d))
end
check("slowest faction under half a second", worst < 0.5, true)

print()
if fails == 0 then print(string.format("ALL %d CHECKS PASSED", checks))
else print(string.format("%d of %d CHECKS FAILED", fails, checks)) end
os.exit(fails == 0 and 0 or 1)
