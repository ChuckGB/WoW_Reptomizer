-- Unit tests for RepOptimizer.Optimizer, runnable outside WoW: lua run_tests.lua
package.path = "../?.lua;" .. package.path
dofile("../Optimizer.lua")
local O = RepOptimizer.Optimizer
local INF = math.huge
local fails, checks = 0, 0

local function check(label, got, want)
    checks = checks + 1
    local ok = (got == want)
    if not ok then fails = fails + 1 end
    print(string.format("   %-52s %14s  %s", label, tostring(got),
        ok and "OK" or ("<<< FAIL want " .. tostring(want))))
end

local function lots(t)
    local out = {}
    for i = 1, #t do out[i] = { qty = t[i][1], price = t[i][2] } end
    return out
end

local function singles(n, price)
    local t = {}
    for i = 1, n do t[i] = { qty = 1, price = price } end
    return t
end

print("COST CURVE — whole lots, not unit prices")
local L = lots{ {5, 100000}, {1, 25000} }   -- stack of 5 @10g, single @2.5g
local c = O.CostCurve(L, 7)
check("cost for >=1 item (the single, 2.5g)", c[1], 25000)
check("cost for >=2 items (stack forced, 10g)", c[2], 100000)
check("cost for >=5 items", c[5], 100000)
check("cost for >=6 items (both)", c[6], 125000)
check("cost for >=7 items (only 6 exist)", c[7], INF)

print("\nCOST CURVE — monotone and exact on a mixed book")
local L2 = lots{ {1,20000}, {1,30000}, {3,60000}, {2,50000} }
local c2 = O.CostCurve(L2, 7)
check("1 item  = cheapest single 2g", c2[1], 20000)
check("2 items = 2g+3g", c2[2], 50000)
check("3 items = 3x for 6g", c2[3], 60000)
check("4 items = 6g+2g", c2[4], 80000)
check("monotone: c[3] <= c[4]", c2[3] <= c2[4], true)

print("\nSOLVE — Zandalar, tokens NOT auto-consumed")
-- bijou: 75 base + 50 token; coin set: 25 base + 50 token
local bij  = { components = { { lots = singles(40, 45000), perTurnin = 1 } } }
local set1 = { components = {
    { lots = singles(40, 10000), perTurnin = 1 },
    { lots = singles(40, 10000), perTurnin = 1 },
    { lots = singles(40, 10000), perTurnin = 1 } } }
local bc = O.SourceCurve(bij, 40)
local sc = O.SourceCurve(set1, 40)
check("1 bijou costs 4.5g (not the whole book)", bc[1], 45000)
check("40 bijous cost 40 x 4.5g", bc[40], 40*45000)
check("40 coin sets cost 40 x 3g", sc[40], 3*40*10000)

local res = O.Solve(2760, {
    { name = "Bijou",    repBase = 75, tokenRep = 50, curve = bc, maxN = 40 },
    { name = "Coin set", repBase = 25, tokenRep = 50, curve = sc, maxN = 40 },
})
check("solve returns a result", res ~= nil, true)
check("reputation reached >= target", res.repAchieved >= 2760, true)
check("base rep = 75b + 25s", res.baseRep,
      75*res.counts[1] + 25*res.counts[2])
check("tokens made = turn-ins", res.tokensMade, res.turnins)
check("tokens kept = made - used", res.tokensKept, res.tokensMade - res.tokensUsed)
check("overage is under one token (50)", res.overage < 50, true)
check("picks the known optimum: 21 bijous", res.counts[1], 21)
check("picks the known optimum: 2 coin sets", res.counts[2], 2)
check("at the known optimal cost 100g50s", res.cost, 1005000)

print("\nSOLVE — leftover tokens are reported, not counted as waste")
-- 31 bijous only, need 3775: base 2325, 31 tokens, consume 29, keep 2
local bijOnly = O.SourceCurve({ components = { { lots = singles(31, 230000), perTurnin = 1 } } }, 31)
local r2 = O.Solve(3775, { { name="Bijou", repBase=75, tokenRep=50, curve=bijOnly, maxN=31 } })
check("bijous bought", r2.counts[1], 31)
check("base reputation", r2.baseRep, 2325)
check("tokens produced", r2.tokensMade, 31)
check("tokens consumed", r2.tokensUsed, 29)
check("tokens KEPT", r2.tokensKept, 2)
check("overage", r2.overage, 0)

print("\nSOLVE — no token source (Thorium-style)")
local ore = O.SourceCurve({ components = { { lots = singles(200, 5000), perTurnin = 10 } } }, 20)
local r3 = O.Solve(1000, { { name="Dark Iron Ore", repBase=50, tokenRep=0, curve=ore, maxN=20 } })
check("turn-ins for 1000 rep at 50 each", r3.counts[1], 20)
check("no tokens produced", r3.tokensMade, 0)
check("cost = 200 ore x 50s", r3.cost, 200*5000)

print("\nSOLVE — refuses when the AH cannot cover it")
local thin = O.SourceCurve({ components = { { lots = singles(2, 20000), perTurnin = 1 } } }, 2)
local r4, err = O.Solve(99999, { { name="Bijou", repBase=75, tokenRep=50, curve=thin, maxN=2 } })
check("returns nil", r4, nil)
check("with a reason", err ~= nil, true)

print("\nLADDER CURVE — divisible commodities (Forever's auction house)")
-- 4 units at 3g, 6 at 5g, 10 at 9g
local ladder = { { qty = 6, unit = 50000 }, { qty = 4, unit = 30000 }, { qty = 10, unit = 90000 } }
local lc, lmeta = O.LadderCurve(ladder, 20)
check("nothing costs nothing", lc[0], 0)
check("1 unit takes the cheapest", lc[1], 30000)
check("4 units all at 3g", lc[4], 4 * 30000)
check("5 units spills into 5g", lc[5], 4 * 30000 + 50000)
check("10 units", lc[10], 4 * 30000 + 6 * 50000)
check("all 20 listed", lc[20], 4 * 30000 + 6 * 50000 + 10 * 90000)
check("supply is 20", lmeta.supply, 20)
-- a ladder is exact for divisible units, so it must be CHEAPER than or equal
-- to the lot solver on the same book -- never dearer
do
    local asLots = { { qty = 6, price = 6 * 50000 }, { qty = 4, price = 4 * 30000 },
                     { qty = 10, price = 10 * 90000 } }
    local lotCurve = O.CostCurve(asLots, 20)
    local everAWin, everWorse = false, false
    for n = 1, 20 do
        if lc[n] < lotCurve[n] then everAWin = true end
        if lc[n] > lotCurve[n] then everWorse = true end
    end
    check("divisible is never dearer than whole-lot", everWorse, false)
    check("and is strictly cheaper somewhere", everAWin, true)
end
-- running past the supply must be impossible, not merely expensive
local short = O.LadderCurve(ladder, 25)
check("21 units cannot be bought", short[21], math.huge)

print("\n  and it names the units to buy")
local pick = O.ReconstructLadder(lmeta, 7)
check("three price steps are not needed for 7", #pick, 2)
check("4 at the cheapest", pick[1].qty, 4)
check("  at 3g", pick[1].unit, 30000)
check("3 at the next", pick[2].qty, 3)
check("  at 5g", pick[2].unit, 50000)
do
    local q, c = 0, 0
    for _, p in ipairs(pick) do q = q + p.qty; c = c + p.qty * p.unit end
    check("quantities sum to the request", q, 7)
    check("cost matches the curve", c, lc[7])
end
check("asking past supply returns nil", O.ReconstructLadder(lmeta, 99), nil)

print()
if fails == 0 then print(string.format("ALL %d CHECKS PASSED", checks))
else print(string.format("%d of %d CHECKS FAILED", fails, checks)) end
os.exit(fails == 0 and 0 or 1)
