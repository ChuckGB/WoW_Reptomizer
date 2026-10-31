-- End-to-end: Data + Core + Optimizer against a mocked WoW API.
local fails, checks = 0, 0
local function check(l, got, want)
    checks = checks + 1
    local ok = (got == want)
    if not ok then fails = fails + 1 end
    print(string.format("   %-50s %14s  %s", l, tostring(got), ok and "OK" or ("<<< FAIL want "..tostring(want))))
end

-- ---- mock the bits of the WoW API that Core touches ----------------------
local FACTIONS = {
    { name = "Zandalar Tribe", standingID = 6, barMin = 9000, barMax = 21000, barValue = 18240 },
    { name = "Cenarion Circle", standingID = 4, barMin = 0, barMax = 3000, barValue = 0 },
}
function GetNumFactions() return #FACTIONS end
function GetFactionInfo(i)
    local f = FACTIONS[i]
    if not f then return end
    return f.name, "", f.standingID, f.barMin, f.barMax, f.barValue, false, false, false, false
end
function ExpandFactionHeader() end
function CollapseFactionHeader() end
local RACE = "Orc"
function UnitRace() return RACE, RACE end
RepOptimizerDB = {}

dofile("../Optimizer.lua")
dofile("../Data.lua")
dofile("../Core.lua")
local RO, Core = RepOptimizer, RepOptimizer.Core

print("STANDING read from the game, nothing typed in")
local zand = RO.Factions[1]
local standing, into, total = Core.GetStanding(zand.factionID, zand.name)
check("standing id (Honored)", standing, 6)
check("rep into Honored", into, 9240)
check("total rep", total, 18240)
local need = Core.RepNeeded(total, 7)          -- target Revered
check("rep needed to Revered (21000-18240)", need, 2760)

print("\nITEM LIST the scanner will query")
local items = RO.ItemsForFaction(zand)
check("distinct items for Zandalar (9 bijous + 9 coins)", #items, 18)

print("\nOPTIMIZE against a synthetic auction book")
-- 40 single bijous at 4g50s, and 40 of each coin at 1g -> set = 3g
local function singles(n, price)
    local t = {} for i = 1, n do t[i] = { qty = 1, price = price } end return t
end
-- a realistic mixed book: cheap Gold, dearer Red, plus a 3-stack
local scan = { ["Gold Hakkari Bijou"] = singles(18, 45000),
               ["Red Hakkari Bijou"]  = singles(10, 60000) }
table.insert(scan["Gold Hakkari Bijou"], { qty = 3, price = 3 * 47000 })
for _, coin in ipairs({"Zulian Coin","Razzashi Coin","Hakkari Coin"}) do
    scan[coin] = singles(40, 10000)
end
local res, err, sources = Core.Optimize(zand, scan, need)
check("returns a result", res ~= nil, true)
check("cost = 18x4.5g + 3-stack@4.7g + 2 sets", res and res.cost, 18*45000 + 3*47000 + 2*30000)
check("reputation reached", res and res.repAchieved, 2775)
check("overage under one token", res and (res.overage < 50), true)
check("search not capped", res and res.searchCapped, false)

local counts = {}
for i, s in ipairs(sources) do counts[s.name] = res.counts[i] end
check("21 bijous", counts["Bijou"], 21)
check("2 Zulian/Razzashi/Hakkari sets", counts["Zulian/Razzashi/Hakkari set"], 2)

print("\nSHOPPING LIST — one row per ITEM, each with its own search term")
local rows, summary = Core.ShoppingRows(res, sources)
for _, r in ipairs(rows) do
    print(string.format("     %-4d x %-24s (%s)", r.qty, r.item, r.source))
end
check("a row per distinct item, not one merged line", #rows >= 3, true)

-- every row must name an item that was actually LISTED, and its own name
local listed = {}
for name in pairs(scan) do listed[name] = true end
local allListed, allDistinct, seen = true, true, {}
for _, r in ipairs(rows) do
    if not listed[r.item] then allListed = false end
    if seen[r.item] then allDistinct = false end
    seen[r.item] = true
end
check("every row names an item that is on the AH", allListed, true)
check("no item appears twice", allDistinct, true)
check("no row invents Blue Hakkari Bijou", seen["Blue Hakkari Bijou"] == nil, true)

-- THE REGRESSION: the click target must be the row's own item, not items[1]
local firstItemOfComponent = zand.sources[1].components[1].items[1]
check("component list still starts with Blue (the trap)", firstItemOfComponent, "Blue Hakkari Bijou")
local anyRowIsBlue = false
for _, r in ipairs(rows) do if r.item == firstItemOfComponent then anyRowIsBlue = true end end
check("no row silently searches for the first-listed name", anyRowIsBlue, false)

-- quantities must add up to what the solver actually bought
local bijouQty = 0
for _, r in ipairs(rows) do
    if r.source == "Bijou" then bijouQty = bijouQty + r.qty end
end
check("bijou rows total the turn-ins bought", bijouQty, res.counts[1])
check("summary lists the sources used", #summary, 2)

print("\nPRICE CUTOFF and exact stacks")
do
    -- a book where buying everything at or below the cutoff OVERSHOOTS,
    -- which is the case that makes a bare cutoff misleading
    local trap = { ["Gold Hakkari Bijou"] = {
        { qty = 2,  price = 2  * 37586 },
        { qty = 20, price = 20 * 37588 },
        { qty = 50, price = 50 * 39143 },
        { qty = 33, price = 33 * 39143 },
        { qty = 1,  price = 1  * 39999 },
    } }
    local rr = Core.Optimize(zand, trap, 1000)
    local rw = Core.ShoppingRows(rr, select(3, Core.Optimize(zand, trap, 1000)))
    local row = rw[1]
    check("row has a cutoff", row.cutoff > 0, true)
    check("row lists the exact auctions", #row.lots > 0, true)
    local q = 0
    for _, l in ipairs(row.lots) do q = q + l.qty end
    check("stacks sum to the row quantity", q, row.qty)
    local maxUnit = 0
    for _, l in ipairs(row.lots) do if l.unit > maxUnit then maxUnit = l.unit end end
    check("cutoff equals the dearest chosen auction", row.cutoff, maxUnit)
    check("auction count matches", row.auctions, #row.lots)
end

print("\nHUMAN RACIAL is detected from the character, not a checkbox")
RACE = "Human"; Core.RefreshRace()
local res2 = Core.Optimize(zand, scan, need)
check("detects Human", Core.IsHuman(), true)
check("bijou effective rep 75->82 base", Core.Effective(75), 82)
check("token 50->55", Core.Effective(50), 55)
check("cheaper with the racial on", res2.cost <= res.cost, true)
RACE = "Orc"; Core.RefreshRace()

print("\nDEGRADED CASES")
local r3, e3 = Core.Optimize(zand, {}, need)
check("empty scan -> nil", r3, nil)
check("empty scan -> explains why", e3 ~= nil, true)
local r4, e4 = Core.Optimize(zand, scan, 0)
check("already at target -> nil", r4, nil)
-- A thin auction house must NOT just refuse: report the best partial buy.
local thin = { ["Gold Hakkari Bijou"] = singles(2, 45000) }
local r5 = Core.Optimize(zand, thin, 99999)
check("thin AH still returns a plan", r5 ~= nil, true)
check("flagged as partial", r5 and r5.partial, true)
check("buys everything listed (2 bijous)", r5 and r5.counts[1], 2)
check("reports what was requested", r5 and r5.requested, 99999)
check("reports the shortfall", r5 and (r5.shortfall > 0), true)
check("shortfall = requested - achieved", r5 and r5.shortfall, r5 and (99999 - r5.repAchieved))
local r6 = Core.Optimize(zand, {}, 99999)
check("truly empty AH still refuses", r6, nil)

print("\nARGENT DAWN — one-time quests must be capped at ONE each")
local ad
for _, fx in ipairs(RO.Factions) do if fx.key == "argentdawn" then ad = fx end end
check("Argent Dawn is in the faction list", ad ~= nil, true)
check("no editorial warning -- the numbers speak", ad and ad.warning, nil)
local adScan = {}
for _, nm in ipairs({"Bone Fragments","Savage Frond","Crypt Fiend Parts",
                     "Dark Iron Scraps","Core of Elements"}) do
    adScan[nm] = singles(600, 500)          -- plenty listed, 5s each
end
local adRes, adErr, adSources = Core.Optimize(ad, adScan, 1000)
check("solves for the 1,000 rep of one-time quests", adRes ~= nil, true)
check("ten sources collapse to few solver dimensions", #adSources <= 4, true)

-- the summary unpacks merged groups back to individual quests, which is where
-- the per-quest "once only" limit has to hold
local _, adSummary = Core.ShoppingRows(adRes, adSources)
local oneTime, repeatable = 0, 0
for _, s in ipairs(adSummary) do
    if s.name:find("one%-time") then
        oneTime = oneTime + s.turnins
        check("  " .. s.name .. " done at most once", s.turnins <= 1, true)
    else
        repeatable = repeatable + s.turnins
    end
end
check("uses the five one-time quests", oneTime, 5)
check("and needs no dismal repeatables", repeatable, 0)
check("reaching exactly 1,000 rep", adRes.repAchieved, 1000)

-- past 1,000 it should fall back to the 10-rep repeatables, honestly
local adRes2, _, adSources2 = Core.Optimize(ad, adScan, 1600)
check("past the one-times it uses repeatables", adRes2 ~= nil, true)
if adRes2 then
    local _, sum2 = Core.ShoppingRows(adRes2, adSources2)
    local one2, rpt2 = 0, 0
    for _, s in ipairs(sum2) do
        if s.name:find("one%-time") then one2 = one2 + s.turnins
        else rpt2 = rpt2 + s.turnins end
    end
    check("  still only five one-time turn-ins", one2, 5)
    check("  60 repeatable turn-ins for the last 600 rep", rpt2, 60)
end

print("\nONE-TIME QUESTS ALREADY DONE must not be planned (Chuck, 29 Oct)")
-- It told him to buy 30 each of four Argent Dawn items for ~800 rep. He had
-- already handed those quests in years ago, so the game paid the repeatable's
-- 10 each: about 44 rep, ~700 short, 120 items wasted.
do
    local DONE = {}
    _G.C_QuestLog = { IsQuestFlaggedCompleted = function(id) return DONE[id] == true end }

    local adScan2 = {}
    for _, nm in ipairs({"Bone Fragments","Savage Frond","Crypt Fiend Parts",
                         "Dark Iron Scraps","Core of Elements"}) do
        adScan2[nm] = singles(600, 500)
    end

    -- nothing done yet: the five one-times are the whole answer, as before
    local rA, _, sA = Core.Optimize(ad, adScan2, 1000)
    check("fresh character still uses the one-times", rA ~= nil, true)
    check("  and reaches 1,000 rep", rA and rA.repAchieved, 1000)
    check("  with nothing excluded", rA and #rA.questsDone, 0)

    -- now Chuck's character: all five handed in long ago
    for _, q in ipairs({9124, 9126, 9128, 9131, 9136}) do DONE[q] = true end
    local rB, _, sB = Core.Optimize(ad, adScan2, 1000)
    check("still returns a plan", rB ~= nil, true)
    check("  reports all five as already done", rB and #rB.questsDone, 5)
    local _, sumB = Core.ShoppingRows(rB, sB)
    local oneTime = 0
    for _, s in ipairs(sumB) do
        if s.name:find("one%-time") then oneTime = oneTime + s.turnins end
    end
    check("  plans ZERO one-time turn-ins", oneTime, 0)
    check("  reaches the target honestly on repeatables", rB and (rB.repAchieved >= 1000), true)
    -- 1,000 rep at 10 a turn-in is 100 turn-ins of 30 items
    check("  which is 100 turn-ins, not 5", rB and rB.turnins, 100)
    check("  so it is far dearer, and says so", rB and (rB.cost > rA.cost), true)

    -- the honest-shortfall path: thin book AND the one-times gone
    local thinAD = { ["Bone Fragments"] = singles(60, 500) }
    local rC = Core.Optimize(ad, thinAD, 1000)
    check("thin book + quests done -> partial, not a lie", rC and rC.partial, true)
    check("  only 20 rep reachable from 60 fragments", rC and rC.repAchieved, 20)

    -- a client that cannot answer must keep the one-times and SAY so
    _G.C_QuestLog = nil
    local rD = Core.Optimize(ad, adScan2, 1000)
    check("no API -> one-times kept", rD and rD.turnins, 5)
    check("  and flagged as an assumption", rD and rD.questUnknown, true)
    check("  with nothing claimed as excluded", rD and #rD.questsDone, 0)
    check("Core.QuestDone says 'unknown', not 'no'", Core.QuestDone(9126), nil)

    -- an API that raises must not take the addon down with it
    _G.C_QuestLog = { IsQuestFlaggedCompleted = function() error("protected") end }
    check("a raising API is survivable", Core.QuestDone(9126), nil)
    _G.C_QuestLog = nil
end

print("\nSTOCK IN HAND — bags and bank are counted (Chuck, 31 Oct)")
-- It told him to buy 1,260 Dark Iron Scraps without looking in his bags.
do
    local BAGS = {}
    _G.GetItemCount = function(name, includeBank)
        local n = BAGS[name] or 0
        if includeBank then n = n + (BAGS[name .. "@bank"] or 0) end
        return n
    end
    local DONE = { [9124]=true, [9126]=true, [9128]=true, [9131]=true, [9136]=true }
    _G.C_QuestLog = { IsQuestFlaggedCompleted = function(id) return DONE[id] == true end }

    local adScan3 = { ["Dark Iron Scraps"] = singles(600, 1000) }

    -- owning nothing: the plan is whatever the auction house can do
    local r0, _, s0 = Core.Optimize(ad, adScan3, 100)
    local rows0 = Core.ShoppingRows(r0, s0)
    check("owning nothing, buys the lot", rows0[1].qty, 300)
    check("  and reports no stock in hand", rows0[1].have, 0)

    -- now 120 in bags and 60 in the bank
    BAGS["Dark Iron Scraps"] = 120
    BAGS["Dark Iron Scraps@bank"] = 60
    local r1, _, s1 = Core.Optimize(ad, adScan3, 100)
    local rows1 = Core.ShoppingRows(r1, s1)
    check("counts bags AND bank", rows1[1].have, 180)
    check("  so it buys 180 fewer", rows1[1].qty, 300 - 180)
    check("  total still covers the turn-ins", rows1[1].need, 300)
    check("  have + buy = need", rows1[1].have + rows1[1].qty, rows1[1].need)
    check("  and it is cheaper", r1.cost < r0.cost, true)
    check("  by exactly the 180 cheapest", r0.cost - r1.cost, 180 * 1000)

    -- free stock must not be counted as an auction to click
    local auctionItems = 0
    for _, l in ipairs(rows1[1].lots) do auctionItems = auctionItems + l.qty end
    check("the stack list covers only what is bought", auctionItems, rows1[1].qty)
    check("  and the auction count matches", rows1[1].auctions, #rows1[1].lots)
    check("stock in hand is not priced into the cutoff", rows1[1].cutoff > 0, true)

    -- owning enough outright
    BAGS["Dark Iron Scraps"] = 500
    BAGS["Dark Iron Scraps@bank"] = 0
    local r2, _, s2 = Core.Optimize(ad, adScan3, 100)
    local rows2 = Core.ShoppingRows(r2, s2)
    check("already holding enough -> buy nothing", rows2[1] and rows2[1].qty, 0)
    check("  at no cost", r2.cost, 0)
    check("  but still 300 needed", rows2[1] and rows2[1].need, 300)

    -- a client with no GetItemCount must behave exactly as before
    BAGS = {}
    _G.GetItemCount = nil
    local r3, _, s3 = Core.Optimize(ad, adScan3, 100)
    local rows3 = Core.ShoppingRows(r3, s3)
    check("no API -> plans as if you own nothing", rows3[1].qty, 300)
    check("Core.OwnedCount says unknown", Core.OwnedCount("Dark Iron Scraps"), nil)
    _G.GetItemCount = function() error("protected") end
    check("  a raising API is survivable", Core.OwnedCount("Dark Iron Scraps"), nil)

    -- SAFETY: while a one-time quest is still open, two sources compete for the
    -- same item, and crediting stock to both would double-count it
    _G.GetItemCount = function(name) return name == "Bone Fragments" and 90 or 0 end
    _G.C_QuestLog = nil
    local r4, _, s4 = Core.Optimize(ad, { ["Bone Fragments"] = singles(300, 1000) }, 220)
    local rows4 = Core.ShoppingRows(r4, s4)
    check("contested item: stock is NOT credited", rows4[1].have, 0)
    _G.GetItemCount = nil
    _G.C_QuestLog = nil
end

print("\nEXACT ROUNDING — the bonus accumulates, it is NOT rounded per turn-in")
-- Chuck saw a 25-rep item award 27, then 28, alternating. 25 x 1.1 = 27.5, so
-- the server keeps the half and floors the running total. Rounding each award
-- down to 27 made the addon plan against 2% less rep than it earns, so it
-- overbought and the bar dinged early with items still on the list.
RACE = "Human"; Core.RefreshRace()
check("bonus is a percent, not a multiplier", Core.BonusPercent(), 10)
check("25 rep is carried as 2750 units", Core.Units(25), 2750)
do
    local seq, prev = {}, 0
    for n = 1, 4 do
        local now = Core.FromUnits(Core.Units(25) * n)
        seq[n], prev = now - prev, now
    end
    check("award 1 is 27", seq[1], 27)
    check("award 2 is 28", seq[2], 28)
    check("award 3 is 27", seq[3], 27)
    check("award 4 is 28", seq[4], 28)
end
check("four 25-rep turn-ins total 110, not 108", Core.FromUnits(Core.Units(25) * 4), 110)
check("a non-Human is untouched", (function()
    RACE = "Orc"; Core.RefreshRace()
    local v = Core.FromUnits(Core.Units(25) * 4)
    RACE = "Human"; Core.RefreshRace()
    return v
end)(), 100)

print("\n  and the overbuy it caused, end to end")
-- Coins only, so the one usable source is a set: 25 base + 50 token = 75,
-- which is 82.5 for a Human. The old code floored each part (27 + 55 = 82)
-- and so demanded an eleventh set to cover 825 rep. Ten is enough.
do
    local coinsOnly = {}
    for _, coin in ipairs({"Zulian Coin","Razzashi Coin","Hakkari Coin"}) do
        coinsOnly[coin] = singles(40, 10000)
    end
    local r, _, srcs = Core.Optimize(zand, coinsOnly, 825)
    check("solves", r ~= nil, true)
    local sets = 0
    for i, s in ipairs(srcs) do
        if s.name:find("Zulian") then sets = r.counts[i] end
    end
    check("ten sets, not the old eleven", sets, 10)
    check("lands exactly on 825 rep", r and r.repAchieved, 825)
    check("no overage at all", r and r.overage, 0)
    check("so it buys 10 of each coin", r and r.cost, 3 * 10 * 10000)
end

print("\n  and a Forever-style fractional bonus")
RO.BonusPercent = 6                      -- Diplomat rank 3
check("6% of 25 is held exactly", Core.Units(25), 2650)
check("four turn-ins give 106", Core.FromUnits(Core.Units(25) * 4), 106)
RO.BonusPercent = nil
RACE = "Orc"; Core.RefreshRace()

print("\nALLIANCE CAPITAL CLOTH FACTIONS")
local sw
for _, fx in ipairs(RO.Factions) do if fx.key == "stormwind" then sw = fx end end
check("Stormwind is in the faction list", sw ~= nil, true)
do
    local keys = {}
    for _, fx in ipairs(RO.Factions) do keys[fx.key] = true end
    check("all four Alliance capitals", (keys.stormwind and keys.ironforge
          and keys.darnassus and keys.gnomeregan) == true, true)
end
check("five turn-ins", #sw.sources, 5)
do
    local once, rpt = 0, 0
    for _, s in ipairs(sw.sources) do
        if s.limit == 1 then once = once + 1 else rpt = rpt + 1 end
    end
    check("four one-time donations", once, 4)
    check("one repeatable", rpt, 1)
end
check("four distinct cloths to scan", #RO.ItemsForFaction(sw), 4)

do
    local clothScan = {
        ["Wool Cloth"]      = singles(60, 100),
        ["Silk Cloth"]      = singles(60, 200),
        ["Mageweave Cloth"] = singles(60, 300),
        ["Runecloth"]       = singles(400, 500),
    }
    local r, _, srcs = Core.Optimize(sw, clothScan, 1400)
    check("solves the four donations", r ~= nil, true)
    check("exactly 4 x 350 rep", r and r.repAchieved, 1400)
    local _, sum = Core.ShoppingRows(r, srcs)
    local once, rpt = 0, 0
    for _, s in ipairs(sum) do
        if s.name:find("one%-time") then
            once = once + s.turnins
            check("  " .. s.name .. " at most once", s.turnins <= 1, true)
        else
            rpt = rpt + s.turnins
        end
    end
    check("uses all four donations", once, 4)
    check("and no repeatables yet", rpt, 0)

    -- past the donations, the 20-Runecloth repeatable takes over
    local r2, _, srcs2 = Core.Optimize(sw, clothScan, 1550)
    check("past the donations it solves too", r2 ~= nil, true)
    local _, sum2 = Core.ShoppingRows(r2, srcs2)
    local rpt2 = 0
    for _, s in ipairs(sum2) do
        if not s.name:find("one%-time") then rpt2 = rpt2 + s.turnins end
    end
    check("two more repeatables for the last 150 rep", rpt2, 2)
    check("which is 40 more Runecloth", r2 and r2.repAchieved, 1550)
end

print("\nMONEY FORMATTING")
local strip = function(s) return (s:gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r","")) end
check("1005000 copper", strip(RO.Money(1005000)), "100g 50s 00c")
check("9000 copper", strip(RO.Money(9000)), "0g 90s 00c")
check("1 copper", strip(RO.Money(1)), "0g 00s 01c")

print()
if fails == 0 then print(string.format("ALL %d CHECKS PASSED", checks))
else print(string.format("%d of %d CHECKS FAILED", fails, checks)) end
os.exit(fails == 0 and 0 or 1)
