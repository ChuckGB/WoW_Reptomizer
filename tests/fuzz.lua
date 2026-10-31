-- Randomised differential test: Solve() vs exhaustive brute force over lot subsets.
dofile("../Optimizer.lua")
local O = RepOptimizer.Optimizer
local INF = math.huge
math.randomseed(20260831)

-- brute force: try every count of each source, cost from the true lot curves
local function brute(need, srcs)
    local best = INF
    local m1 = srcs[1].maxN
    local m2 = srcs[2] and srcs[2].maxN or 0
    for a = 0, m1 do
        for b = 0, m2 do
            local rep = a*(srcs[1].repBase + srcs[1].tokenRep)
                      + (srcs[2] and b*(srcs[2].repBase + srcs[2].tokenRep) or 0)
            if rep >= need then
                local c1 = srcs[1].curve[a]
                local c2 = srcs[2] and srcs[2].curve[b] or 0
                if c1 < INF and c2 < INF and c1 + c2 < best then best = c1 + c2 end
            end
        end
    end
    return best
end

local function randomLots(n)
    local t = {}
    for i = 1, n do
        t[i] = { qty = math.random(1, 4), price = math.random(1, 30) * 10000 }
    end
    return t
end

local bad, n = 0, 0
for trial = 1, 400 do
    local bl = randomLots(math.random(4, 14))
    local c1 = randomLots(math.random(4, 12))
    local c2 = randomLots(math.random(4, 12))
    local c3 = randomLots(math.random(4, 12))
    local bijCurve = O.SourceCurve({ components = { { lots = bl, perTurnin = 1 } } }, 20)
    local setCurve = O.SourceCurve({ components = {
        { lots = c1, perTurnin = 1 }, { lots = c2, perTurnin = 1 }, { lots = c3, perTurnin = 1 } } }, 20)
    local srcs = {
        { name = "Bijou",    repBase = 75, tokenRep = 50, curve = bijCurve, maxN = 20 },
        { name = "Coin set", repBase = 25, tokenRep = 50, curve = setCurve, maxN = 20 },
    }
    local need = math.random(100, 2000)
    local res = O.Solve(need, srcs)
    local ref = brute(need, srcs)
    n = n + 1
    if ref == INF then
        if res ~= nil then bad = bad + 1; print("trial", trial, "returned a result when none exists") end
    else
        if res == nil then
            bad = bad + 1; print("trial", trial, "returned nil but", ref, "was possible")
        elseif res.cost ~= ref then
            bad = bad + 1
            print(string.format("trial %d MISMATCH need=%d solve=%d brute=%d", trial, need, res.cost, ref))
        elseif res.repAchieved < need then
            bad = bad + 1; print("trial", trial, "under-delivers rep")
        elseif res.tokensKept ~= res.tokensMade - res.tokensUsed then
            bad = bad + 1; print("trial", trial, "token accounting inconsistent")
        end
    end
end
print(string.format("randomised: %d/%d matched exhaustive brute force (%d mismatches)", n - bad, n, bad))

-- ---------------------------------------------------------------------------
-- Reconstruction validity. A plan that names an auction twice is worse than a
-- suboptimal plan: it tells the player to buy stock that does not exist.
local rbad, rn = 0, 0
for trial = 1, 300 do
    local lots = randomLots(math.random(3, 18))
    local total = 0
    for _, l in ipairs(lots) do total = total + l.qty end
    local curve, meta = O.CostCurve(lots, total)
    for want = 1, total do
        local picked = O.Reconstruct(meta, want)
        rn = rn + 1
        if picked == nil then
            if curve[want] < math.huge then rbad = rbad + 1 end
        else
            local seen, qty, cost = {}, 0, 0
            local dup = false
            for _, idx in ipairs(picked) do
                if seen[idx] then dup = true end
                seen[idx] = true
                if not lots[idx] then dup = true break end
                qty = qty + lots[idx].qty
                cost = cost + lots[idx].price
            end
            if dup or qty < want or cost ~= curve[want] then
                rbad = rbad + 1
                if rbad <= 3 then
                    print(string.format("  BAD trial=%d want=%d dup=%s qty=%d cost=%d curve=%d",
                        trial, want, tostring(dup), qty, cost, curve[want]))
                end
            end
        end
    end
end
print(string.format("reconstruction: %d/%d plans valid (no repeated auctions, cost matches, covers target)",
    rn - rbad, rn))
os.exit((bad == 0 and rbad == 0) and 0 or 1)
