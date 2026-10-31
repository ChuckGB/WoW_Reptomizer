--[[ Optimizer.lua -------------------------------------------------------------
Pure Lua. No WoW API is touched in this file, so it can be unit-tested outside
the game (see tests/run_tests.lua).

The problem
-----------
You need R reputation. Several turn-ins can supply it. Each turn-in consumes a
fixed number of items, and those items are bought on the Auction House as whole
LOTS -- an auction of 5 bijous for 10g is all-or-nothing, you cannot buy 1 of it.

So "the cost of n items" is not n x unit price, and it is not even a prefix sum
over sorted unit prices. It is a covering knapsack over lots:

    CostCurve(lots)[n] = cheapest set of whole lots totalling at least n items

That curve is the primitive everything else is built on.

Tokens
------
Some turn-ins award base reputation PLUS a token that CAN be converted to more
reputation but does not have to be -- Zandalar Honor Tokens buy Signets, Argent
Dawn Valor Tokens buy the Mantles. So a source has:

    repBase   reputation the turn-in always gives
    tokenRep  reputation you get IF you consume the token (0 if no token)

Maximum reputation from n turn-ins is n*(repBase+tokenRep); minimum is n*repBase.
Feasibility uses the maximum. Tokens consumed is then only what is needed to
reach the target, and the remainder is reported as kept, not as waste.

Units
-----
Solve treats `need`, `repBase` and `tokenRep` as OPAQUE INTEGERS and only ever
adds, multiplies and compares them. It does not care what one unit means.

Core exploits that: it passes reputation in hundredths of a point with the
racial bonus already folded in (Core.Units), so a Human's 25-rep turn-in is
2750 rather than a rounded 27, and the whole search stays exact integer
arithmetic. Core floors the total back to reputation once, at the end. Do not
introduce rounding or float division here -- that is precisely the bug this
arrangement exists to prevent.
--------------------------------------------------------------------------- ]]

local ADDON = ...
local RO = _G.RepOptimizer or {}
_G.RepOptimizer = RO

local Optimizer = {}
RO.Optimizer = Optimizer

local INF = math.huge
local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max

--- Cheapest way to obtain at least n items, buying whole lots.
--
-- Reconstruction correctness note. The obvious approach -- record a parent
-- pointer whenever dp[m] improves -- is WRONG for 0/1 knapsack. dp[n] can be
-- improved later by a different lot, so following the chain can re-enter a
-- state that already spent the lot you just took, and the same auction comes
-- out twice. That shipped, and it told the player to buy seven stacks of ten
-- when only four such auctions existed.
--
-- The fix: record improvements PER LAYER (per lot). When backtracking from a
-- state, take the LAST layer that improved it, then continue searching only in
-- strictly earlier layers. Layers strictly decrease, so no lot can repeat.
--
-- @return curve  array 0..maxN of the cheapest cost to obtain AT LEAST n
--         meta   opaque, pass to Reconstruct
function Optimizer.CostCurve(lots, maxN)
    local dp = {}                       -- dp[n] = cheapest subset summing to exactly n
    for n = 0, maxN do dp[n] = INF end
    dp[0] = 0
    local taken = {}                    -- taken[i][m] = predecessor n, at layer i

    for i = 1, #lots do
        local q, p = lots[i].qty, lots[i].price
        local layer = nil
        -- price 0 is legitimate: it is how Core represents stock you already
        -- own. Only the quantity has to be positive.
        if q and p and q > 0 and p >= 0 then
            layer = {}
            -- descending so each lot is considered at most once
            for n = maxN, 0, -1 do
                if dp[n] < INF then
                    local m = n + q
                    if m > maxN then m = maxN end
                    if dp[n] + p < dp[m] then
                        dp[m] = dp[n] + p
                        layer[m] = n
                    end
                end
            end
        end
        taken[i] = layer
    end

    -- "at least n" is the cheapest exact total of n or more; remember which
    -- exact total achieves it so reconstruction starts from the right state
    local curve, argAt = {}, {}
    local bestCost, bestAt = INF, nil
    for n = maxN, 0, -1 do
        if dp[n] < bestCost then bestCost, bestAt = dp[n], n end
        curve[n] = bestCost
        argAt[n] = bestAt
    end

    return curve, { dp = dp, taken = taken, argAt = argAt, count = #lots }
end

--- Which auctions make up the cheapest way to obtain at least n items.
-- @return array of lot indices (each appearing at most once), or nil
function Optimizer.Reconstruct(meta, n)
    if not meta or not meta.argAt then return nil end
    local state = meta.argAt[n]
    if state == nil then return nil end
    local picked = {}
    local layer = meta.count
    while state > 0 and layer >= 1 do
        local t = meta.taken[layer]
        local prev = t and t[state]
        if prev ~= nil then
            picked[#picked + 1] = layer
            state = prev
        end
        layer = layer - 1               -- strictly earlier layers only
    end
    if state ~= 0 then return nil end   -- could not fully explain the cost
    return picked
end

--- Cheapest way to obtain at least n units when the units are DIVISIBLE.
--
-- A modern auction house (Forever) sells commodities by the unit out of a
-- shared pool, so you are not buying whole auctions and the covering knapsack
-- above does not apply. Walking the price ladder cheapest-first IS optimal
-- here, and it is O(maxN) rather than O(lots x maxN) -- which is what makes
-- the five-figure grinds (cloth to Exalted, Silithid Carapace Fragments)
-- affordable on Forever when they are not on Classic.
--
-- Do NOT use this for Classic lots. A ladder cannot say whether forty units at
-- one price are four stacks of ten or forty singles, and picking the wrong one
-- is how the shopping list ends up naming auctions that do not exist.
--
-- @param ladder array of { qty = units at this price, unit = copper each }
-- @return curve 0..maxN, meta for ReconstructLadder
function Optimizer.LadderCurve(ladder, maxN)
    local steps = {}
    for i = 1, #ladder do
        local s = ladder[i]
        local q, u = s.qty, s.unit
        if q and u and q > 0 and u >= 0 then
            steps[#steps + 1] = { qty = q, unit = u }
        end
    end
    table.sort(steps, function(a, b) return a.unit < b.unit end)

    local curve = { [0] = 0 }
    local filled, cost = 0, 0
    for i = 1, #steps do
        local take = steps[i].qty
        if filled + take > maxN then take = maxN - filled end
        for _ = 1, take do
            filled = filled + 1
            cost = cost + steps[i].unit
            curve[filled] = cost
        end
        if filled >= maxN then break end
    end
    for n = filled + 1, maxN do curve[n] = INF end

    return curve, { steps = steps, supply = filled }
end

--- Which units to buy, as { qty, unit } cheapest-first totalling n.
function Optimizer.ReconstructLadder(meta, n)
    if not meta or not meta.steps or n == nil or n < 0 then return nil end
    if n > (meta.supply or 0) then return nil end
    local out, left = {}, n
    for i = 1, #meta.steps do
        if left <= 0 then break end
        local take = meta.steps[i].qty
        if take > left then take = left end
        out[#out + 1] = { qty = take, unit = meta.steps[i].unit }
        left = left - take
    end
    if left > 0 then return nil end
    return out
end

--- Cost of n TURN-INS of one source.
-- A source may need several components at once (a Zandalar coin set needs one
-- of each of three coins), and each component has its own lot list and its own
-- per-turn-in quantity.
-- @param source { components = { {lots=..., perTurnin=<n>}, ... } }
-- @param maxTurnins
function Optimizer.SourceCurve(source, maxTurnins)
    local curves, froms = {}, {}
    for c = 1, #source.components do
        local comp = source.components[c]
        local per = comp.perTurnin or 1
        curves[c], froms[c] = Optimizer.CostCurve(comp.lots, maxTurnins * per)
    end
    source.curves, source.froms = curves, froms
    local out = {}
    for n = 0, maxTurnins do
        local total = 0
        for c = 1, #source.components do
            local per = source.components[c].perTurnin or 1
            local v = curves[c][n * per]
            if v == nil or v == INF then total = INF break end
            total = total + v
        end
        out[n] = total
    end
    return out
end

--- Combine two turn-in curves for sources that are interchangeable for rep
-- (e.g. the three Zandalar coin sets all give the same reputation).
-- result[n] = cheapest way to get n turn-ins total from either.
--- Last index at which a curve is finite.
local function finiteMax(curve, maxN)
    local last = -1
    for n = 0, maxN do
        local v = curve[n]
        if v and v < INF then last = n end
    end
    return last
end

function Optimizer.MergeCurves(a, b, maxN)
    -- Only convolve over the range where BOTH curves are finite. A source can
    -- rarely supply more than a few hundred turn-ins, so this turns an O(n^2)
    -- convolution into O(n * memberMax) and keeps big targets affordable.
    local maxA = finiteMax(a, maxN)
    local maxB = finiteMax(b, maxN)
    local out, split = {}, {}
    for n = 0, maxN do
        local best, bestK = INF, 0
        local lo = n - maxB; if lo < 0 then lo = 0 end
        local hi = n; if hi > maxA then hi = maxA end
        for k = lo, hi do
            local x, y = a[k], b[n - k]
            if x and y and x < INF and y < INF and x + y < best then
                best, bestK = x + y, k
            end
        end
        out[n] = best
        split[n] = bestK          -- how many of those n came from `a`
    end
    return out, split
end

--- Merge a list of interchangeable sources into ONE curve.
-- Sources that award identical reputation are interchangeable, so the solver
-- should treat them as a single dimension. Without this, a faction with ten
-- turn-ins (Argent Dawn) makes the enumeration in Solve() exponential and the
-- game client freezes -- which is exactly what happened.
-- @return curve, unpack(n) -> array of counts aligned with `curves`
function Optimizer.MergeGroup(curves, maxN)
    if #curves == 1 then
        return curves[1], function(n) return { n } end
    end
    local acc, splits = curves[1], {}
    for i = 2, #curves do
        local merged, split = Optimizer.MergeCurves(acc, curves[i], maxN)
        acc = merged
        splits[i] = split
    end
    local function unpack_(n)
        local counts = {}
        local remaining = n
        for i = #curves, 2, -1 do
            local fromAcc = splits[i][remaining] or 0
            counts[i] = remaining - fromAcc
            remaining = fromAcc
        end
        counts[1] = remaining
        return counts
    end
    return acc, unpack_
end

--- How many turn-ins of a source are worth considering.
local function CurveMax(curve, maxN)
    local last = 0
    for n = 0, maxN do
        if curve[n] and curve[n] < INF then last = n end
    end
    return last
end
Optimizer.CurveMax = CurveMax

--- Solve for the cheapest mix.
-- @param need reputation still required
-- @param sources array of { name=, repBase=, tokenRep=, curve=<turn-in curve>, maxN= }
-- @return table or nil
function Optimizer.Solve(need, sources, opts)
    opts = opts or {}
    if need <= 0 then return nil, "no reputation needed" end
    local n = #sources
    if n == 0 then return nil, "no sources" end

    -- full value of one turn-in, i.e. consuming the token
    for i = 1, n do
        local s = sources[i]
        s.repFull = s.repBase + (s.tokenRep or 0)
        s.maxN = min(s.maxN or 0, CurveMax(s.curve, s.maxN or 0))
    end

    -- close the LAST source in closed form, enumerate the rest
    -- (ordering: put the best value-per-rep source last so pruning bites early)
    local order = {}
    for i = 1, n do order[i] = i end
    table.sort(order, function(x, y)
        local sx, sy = sources[x], sources[y]
        local cx = (sx.curve[1] or INF) / max(1, sx.repFull)
        local cy = (sy.curve[1] or INF) / max(1, sy.repFull)
        return cx > cy                      -- worst first, best last
    end)
    local closer = order[n]
    local enumerate = {}
    for i = 1, n - 1 do enumerate[i] = order[i] end

    local best = nil
    local counts = {}
    for i = 1, n do counts[i] = 0 end

    local closerSrc = sources[closer]

    local function evaluate(fixedRep, fixedCost)
        local shortfall = need - fixedRep
        local k = 0
        if shortfall > 0 then
            k = ceil(shortfall / closerSrc.repFull)
            if k > closerSrc.maxN then return end
        end
        local c = closerSrc.curve[k]
        if not c or c >= INF then return end
        local total = fixedCost + c
        if best and total >= best.cost then return end
        counts[closer] = k
        local snapshot = {}
        for i = 1, n do snapshot[i] = counts[i] end
        best = { cost = total, counts = snapshot }
    end

    -- Hard ceiling on work done. An exponential search that is merely "usually
    -- fast" is not acceptable inside a game client: WoW kills the script and the
    -- player sees a freeze. If the budget runs out we return the best found so
    -- far and say it is approximate.
    local budget = opts.budget or 150000
    local exhausted = false

    local function recurse(idx, fixedRep, fixedCost)
        if exhausted then return end
        budget = budget - 1
        if budget <= 0 then exhausted = true return end
        if best and fixedCost >= best.cost then return end     -- prune
        if idx > #enumerate then
            evaluate(fixedRep, fixedCost)
            return
        end
        local si = enumerate[idx]
        local src = sources[si]
        for k = 0, src.maxN do
            local c = src.curve[k]
            if not c or c >= INF then break end
            if best and fixedCost + c >= best.cost then break end -- curve is non-decreasing
            counts[si] = k
            recurse(idx + 1, fixedRep + k * src.repFull, fixedCost + c)
        end
        counts[si] = 0
    end

    recurse(1, 0, 0)
    if not best then return nil, "not enough listed on the auction house" end

    -- ---- token accounting (Chuck's correction) --------------------------
    local baseRep, tokens, turnins = 0, 0, 0
    for i = 1, n do
        local k = best.counts[i]
        local s = sources[i]
        baseRep = baseRep + k * s.repBase
        turnins = turnins + k
        if (s.tokenRep or 0) > 0 then tokens = tokens + k end
    end
    -- consume only as many tokens as the target actually requires
    local tokenRep = 0
    for i = 1, n do
        if (sources[i].tokenRep or 0) > 0 then tokenRep = sources[i].tokenRep break end
    end
    local consume = 0
    if tokenRep > 0 and baseRep < need then
        consume = min(tokens, ceil((need - baseRep) / tokenRep))
    end
    local finalRep = baseRep + consume * tokenRep

    return {
        approximate = exhausted,
        cost        = best.cost,
        counts      = best.counts,
        turnins     = turnins,
        baseRep     = baseRep,
        tokensMade  = tokens,
        tokensUsed  = consume,
        tokensKept  = tokens - consume,
        repAchieved = finalRep,
        overage     = finalRep - need,
    }
end

return Optimizer
