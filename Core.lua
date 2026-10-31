--[[ Core.lua ------------------------------------------------------------------
Glue: reads your live standing, turns a scan into cost curves, runs the
optimizer, and formats the answer.
--------------------------------------------------------------------------- ]]

local RO = _G.RepOptimizer
local Core = {}
RO.Core = Core

local INF = math.huge

function RO.Money(copper)
    if not copper or copper >= INF then return "--" end
    copper = math.floor(copper + 0.5)
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    return string.format("|cffffd700%d|rg |cffc7c7cf%02d|rs |cffeda55f%02d|rc", g, s, c)
end

--- Current standing straight from the game, so nothing has to be typed in.
-- @return standingID, repIntoStanding, totalRep, factionName
function Core.GetStanding(factionID, factionName)
    -- GetFactionInfo only walks VISIBLE rows, so a collapsed header hides the
    -- faction entirely. Expand everything first, then restore.
    local collapsed = {}
    local i = 1
    while i <= GetNumFactions() do
        local _, _, _, _, _, _, _, _, isHeader, isCollapsed = GetFactionInfo(i)
        if isHeader and isCollapsed then
            collapsed[#collapsed + 1] = i
            ExpandFactionHeader(i)
        else
            i = i + 1
        end
    end
    local found = { Core.FindStanding(factionName) }
    for n = #collapsed, 1, -1 do CollapseFactionHeader(collapsed[n]) end
    if found[1] then return found[1], found[2], found[3], found[4] end
    return nil
end

function Core.FindStanding(factionName)
    for i = 1, GetNumFactions() do
        local name, _, standingID, barMin, barMax, barValue = GetFactionInfo(i)
        if name == factionName then
            return standingID, barValue - barMin, barValue, name
        end
    end
    return nil
end

--- Reputation still required to reach a target standing.
function Core.RepNeeded(totalRep, targetStandingID)
    local target = RO.StandingStart[targetStandingID]
    if not target then return nil end
    return math.max(0, target - totalRep)
end

--- Is this character Human? The game knows, so never ask the player.
local isHuman = nil
function Core.IsHuman()
    if isHuman == nil then
        if UnitRace then
            local _, raceFile = UnitRace("player")
            isHuman = (raceFile == "Human")
        else
            isHuman = false
        end
    end
    return isHuman
end

--- Forget the cached race. Only needed by the tests.
function Core.RefreshRace() isHuman = nil end

--- The reputation bonus as a whole percent. Human "Diplomacy" is +10 on
--- Classic. Forever replaces the racial with the "Diplomat" legacy talent --
--- five ranks of +2% each, open to every race -- so there it is a 0-10 ladder
--- rather than a yes/no. Set RO.BonusPercent to override.
function Core.BonusPercent()
    if RO.BonusPercent ~= nil then return RO.BonusPercent end
    return Core.IsHuman() and 10 or 0
end

-- Reputation is carried in UNITS of one hundredth of a point.
--
-- The bonus is NOT applied to each award and rounded there. The server keeps
-- the exact value and floors the RUNNING TOTAL, which is why a Human handing
-- in a 25-rep item sees 27, then 28, then 27, then 28 -- 25 x 1.1 is 27.5, and
-- the half carries. Flooring each turn-in to 27 made the addon plan against
-- 2% less reputation than it actually earns, so it bought too much and the bar
-- dinged early with items still on the list.
--
-- Holding everything as base x (100 + percent) keeps the whole calculation in
-- exact integers, with a single floor at the very end. No floats anywhere.
local UNIT = 100
Core.UNIT = UNIT

function Core.Units(value)
    return (value or 0) * (UNIT + Core.BonusPercent())
end

function Core.FromUnits(units)
    return math.floor((units or 0) / UNIT)
end

--- What a single award shows in the combat log. DISPLAY ONLY -- never plan
--- with this, because the dropped fraction accumulates.
function Core.Effective(value)
    return Core.FromUnits(Core.Units(value))
end

-- Largest quantity axis we will build a cost curve over, per component.
--
-- CostCurve is O(lots x quantity), so a faction whose turn-in takes 20 or 200
-- items at a time (cloth, Silithid Carapace Fragments) can push the axis into
-- five figures on a busy realm and stall the client mid-frame. Clamping the
-- axis makes the plan PARTIAL rather than slow, and the window already says
-- plainly when our own cap is what stopped us rather than the market.
local AXIS_CAP = 4000
Core.AXIS_CAP = AXIS_CAP

--- Has this character already handed in a one-time quest?
--
-- This matters more than it looks. The Argent Dawn commission quests pay 200
-- rep ONCE and 10 rep every time after, and the repeatable is gated behind the
-- one-time version (quest 9127 requires 9126). A character who did them years
-- ago gets the 10, so a plan built on the 200 promises eight times the
-- reputation the game will actually pay. That shipped: it had Chuck buy 30 each
-- of four items for about 44 rep against ~800 promised.
--
-- @return true, false, or nil when the client cannot tell us
function Core.QuestDone(questID)
    if not questID then return false end
    local fn = (_G.C_QuestLog and _G.C_QuestLog.IsQuestFlaggedCompleted)
               or _G.IsQuestFlaggedCompleted
    if type(fn) ~= "function" then return nil end
    local ok, done = pcall(fn, questID)
    if not ok then return nil end
    return done and true or false
end

--- How many of an item the character already has, bags and bank together.
-- @return count, or nil when the client cannot tell us
function Core.OwnedCount(itemName)
    if not itemName then return nil end
    if type(_G.GetItemCount) ~= "function" then return nil end
    local ok, n = pcall(_G.GetItemCount, itemName, true)   -- true = include bank
    if not ok or type(n) ~= "number" then return nil end
    return n
end

--- Which items does more than one source of this faction draw on?
--
-- This matters because each source builds its OWN pool from the same scan, so
-- two sources that share an item can both spend the same auctions. Proved 31
-- Oct: Argent Dawn's one-time and repeatable Bone Fragment quests together
-- "bought" 90 items from 60 distinct auctions, taking 30 of them twice.
--
-- The real fix is to model a one-time plus its repeatable as ONE source whose
-- first turn-in pays more, which needs non-linear reputation in Solve. Until
-- then: stock you already own is only credited to an item NO other source
-- competes for, so owned stock can never be counted twice.
-- Takes the sources that actually survive into the plan, not the whole
-- faction: once a one-time quest is excluded as already done, the item it used
-- is no longer contested. That is exactly Chuck's case -- his Argent Dawn
-- one-times are done, so Dark Iron Scraps has a single claimant and his stock
-- in hand can be credited.
local function SharedItems(liveSources)
    local uses, shared = {}, {}
    for _, src in ipairs(liveSources) do
        local seen = {}
        for _, comp in ipairs(src.components) do
            for _, item in ipairs(comp.items) do
                if not seen[item] then
                    seen[item] = true
                    uses[item] = (uses[item] or 0) + 1
                    if uses[item] > 1 then shared[item] = true end
                end
            end
        end
    end
    return shared
end

--- Turn raw scan results into solver sources.
-- @return sources, axisCapped, skipped (names of one-time quests already done),
--         unknown (true when the client could not tell us), owned (per item)
function Core.BuildSources(faction, scan, maxTurnins)
    local Opt = RO.Optimizer
    local sources = {}
    local axisCapped = false
    local skipped, unknown = {}, false

    -- FIRST decide which turn-ins are still available to this character. A
    -- one-time quest already handed in is not a source at all, and dropping it
    -- here also frees up the items it would have competed for.
    local live = {}
    for _, src in ipairs(faction.sources) do
        local keep = true
        if src.questID then
            local done = Core.QuestDone(src.questID)
            if done == true then
                keep = false
                skipped[#skipped + 1] = src.name
            elseif done == nil then
                -- The client cannot tell us. Keep the source -- dropping it
                -- would wreck a fresh character's plan -- but let the window
                -- say the assumption is unverified.
                unknown = true
            end
        end
        if keep then live[#live + 1] = src end
    end

    -- What the character already has. Reported for every item so the window
    -- can always show it, but only CREDITED (as a free lot) for items no
    -- surviving source competes for -- see SharedItems.
    local shared = SharedItems(live)
    local owned, credited = {}, {}
    for _, item in ipairs(RO.ItemsForFaction(faction)) do
        local n = Core.OwnedCount(item)
        if n and n > 0 then
            owned[item] = n
            credited[item] = not shared[item]
        end
    end

    for _, src in ipairs(live) do
        local components = {}
        local usable = true
        for _, comp in ipairs(src.components) do
            -- all named items in a component are interchangeable (bijou colours),
            -- so their listings go into one pool
            local pool = {}
            for _, itemName in ipairs(comp.items) do
                -- Stock in hand first, as a single free lot. The cost curve
                -- then spends it before any gold, and the solver can prefer a
                -- source whose materials you already hold.
                if credited[itemName] then
                    pool[#pool + 1] = { qty = owned[itemName], price = 0,
                                        item = itemName, owned = true }
                end
                local lots = scan[itemName]
                if lots then
                    for _, lot in ipairs(lots) do
                        -- copy so we can tag provenance without touching the scan
                        pool[#pool + 1] = { qty = lot.qty, price = lot.price, item = itemName }
                    end
                end
            end
            if #pool == 0 then usable = false break end
            components[#components + 1] = { lots = pool, perTurnin = comp.perTurnin }
        end
        if usable then
            -- Never build a curve bigger than the auction house can justify. The
            -- quantity axis was previously maxTurnins * perTurnin (e.g. 500 * 30
            -- = 15,000) even when only 900 items were listed, and the cost-curve
            -- DP is O(lots x quantity). That is what made Argent Dawn crawl.
            local feasible = maxTurnins
            for _, comp in ipairs(components) do
                local have = 0
                for _, lot in ipairs(comp.lots) do have = have + lot.qty end
                feasible = math.min(feasible, math.floor(have / comp.perTurnin))
            end
            -- and never let the quantity axis itself grow without bound
            for _, comp in ipairs(components) do
                local byAxis = math.floor(AXIS_CAP / comp.perTurnin)
                if byAxis < feasible then
                    feasible = byAxis
                    axisCapped = true
                end
            end
            if feasible < 1 then feasible = 0 end

            local built = { components = components }
            local curve = Opt.SourceCurve(built, feasible)
            sources[#sources + 1] = {
                name     = src.name,
                -- in UNITS (see Core.Units): exact, bonus already folded in
                repBase  = Core.Units(src.repBase),
                tokenRep = Core.Units(src.tokenRep or 0),
                curve    = curve,
                -- a one-time quest can only ever be done once
                maxN     = math.min(feasible, src.limit or feasible),
                limit    = src.limit,
                def      = src,
                built    = built,          -- carries the reconstruction tables
            }
        end
    end
    return sources, axisCapped, skipped, unknown, owned
end

--- Collapse sources that award identical reputation into one solver dimension.
-- Argent Dawn has ten turn-ins; enumerating ten dimensions froze the client.
-- Five of them pay 200 once and five pay 10 repeatably, so they are really two
-- choices, not ten.
function Core.GroupSources(sources, maxTurnins)
    local Opt = RO.Optimizer
    local byRep, order = {}, {}
    for _, s in ipairs(sources) do
        local key = s.repBase .. "/" .. (s.tokenRep or 0) .. "/" .. tostring(s.limit)
        if not byRep[key] then byRep[key] = {} order[#order + 1] = key end
        local g = byRep[key]
        g[#g + 1] = s
    end
    local groups = {}
    for _, key in ipairs(order) do
        local members = byRep[key]
        if #members == 1 then
            local s = members[1]
            s.members, s.unpack = { s }, function(n) return { n } end
            groups[#groups + 1] = s
        else
            -- cap the merge: no point costing more turn-ins than are listed
            local reach = 0
            for _, s in ipairs(members) do
                reach = reach + RO.Optimizer.CurveMax(s.curve, s.maxN)
            end
            local cap = math.min(maxTurnins, reach)
            -- Truncate each member to ITS OWN maxN before merging. The raw curve
            -- runs to whatever the auction house could supply, but a one-time
            -- quest has maxN = 1; merging the untruncated curve let the solver
            -- "do" a single-completion quest several times.
            local curves = {}
            for i, s in ipairs(members) do
                local limited = {}
                for n = 0, cap do
                    limited[n] = (n <= s.maxN) and s.curve[n] or math.huge
                end
                curves[i] = limited
            end
            local merged, unpack_ = Opt.MergeGroup(curves, cap)
            groups[#groups + 1] = {
                name     = members[1].name,
                repBase  = members[1].repBase,
                tokenRep = members[1].tokenRep,
                curve    = merged,
                maxN     = cap,
                limit    = members[1].limit,
                members  = members,
                unpack   = unpack_,
                def      = members[1].def,
            }
        end
    end
    return groups
end

--- Full run: needs an already-completed scan.
function Core.Optimize(faction, scan, need)
    if need <= 0 then return nil, "you are already at or past that standing" end
    -- The search must be able to reach `need` using the WEAKEST source, or the
    -- optimum could sit outside the searched range. Cap it for performance and
    -- say so if the cap bites.
    --
    -- Everything below is in UNITS (Core.Units), so the bonus never gets
    -- rounded per turn-in. One floor at the end, in FromUnits.
    local needUnits = need * UNIT

    local weakest = nil
    for _, src in ipairs(faction.sources) do
        local full = Core.Units(src.repBase) + Core.Units(src.tokenRep or 0)
        if full > 0 and (weakest == nil or full < weakest) then weakest = full end
    end
    weakest = weakest or 1
    -- Enough turn-ins of the WEAKEST source to reach the target. The previous
    -- hard cap of 500 silently truncated the plan and then reported the auction
    -- house as short of stock, which was simply untrue.
    local wanted = math.ceil(needUnits / weakest)
    local maxTurnins = math.min(4000, wanted)

    local raw, axisCapped, skipped, questUnknown, owned =
        Core.BuildSources(faction, scan, maxTurnins)
    if #raw == 0 then
        if skipped and #skipped > 0 then
            return nil, "every turn-in for this faction is either unlisted or already completed on this character"
        end
        return nil, "nothing for this faction is listed on the auction house right now"
    end
    local sources = Core.GroupSources(raw, maxTurnins)
    -- What could the auction house supply even if we bought the lot? Telling
    -- someone "not enough listed" and stopping is useless -- if the AH can only
    -- get them 60% of the way, they still want to know the cheapest way to buy
    -- that 60%.
    local available = 0
    for _, s in ipairs(sources) do
        local reach = RO.Optimizer.CurveMax(s.curve, s.maxN)
        available = available + reach * (s.repBase + (s.tokenRep or 0))
    end

    if available <= 0 then
        return nil, "nothing for this faction is listed on the auction house right now"
    end

    -- `available` is what the LISTINGS can supply. If the search cap is what
    -- limits us instead, say that -- do not blame the auction house.
    local capBound = 0
    for _, s in ipairs(sources) do
        capBound = capBound + s.maxN * (s.repBase + (s.tokenRep or 0))
    end

    local result, err
    if available < needUnits then
        -- The auction house cannot cover the target, so the answer is simply
        -- "buy everything listed". Searching for it is not just wasted work --
        -- with the cost bound useless the search explodes, which is what froze
        -- the client on Argent Dawn.
        result = Core.BuyEverything(sources)
        result.partial = true
    else
        -- Solve treats reputation as opaque integers, so handing it units is
        -- all that is needed to make it exact.
        result, err = RO.Optimizer.Solve(needUnits, sources)
        if not result then return nil, err, sources end
        result.partial = false
    end

    -- Back to reputation, flooring the TOTAL exactly once.
    result.repAchievedUnits = result.repAchieved
    result.baseRepUnits     = result.baseRep
    result.repAchieved      = Core.FromUnits(result.repAchieved)
    result.baseRep          = Core.FromUnits(result.baseRep)
    result.overage          = result.partial and 0
                              or math.max(0, result.repAchieved - need)

    result.questsDone   = skipped
    result.questUnknown = questUnknown
    result.owned        = owned
    result.searchCapped = (maxTurnins < wanted) or axisCapped
    result.capLimited   = result.partial and (capBound < needUnits) and (available >= needUnits)
    result.shortfall    = result.partial and math.max(0, need - result.repAchieved) or 0
    result.requested    = need
    return result, nil, sources
end

--- Everything the auction house has, with the usual token accounting.
function Core.BuyEverything(sources)
    local counts, cost, baseRep, tokens, turnins = {}, 0, 0, 0, 0
    local tokenRep = 0
    for i, s in ipairs(sources) do
        local n = RO.Optimizer.CurveMax(s.curve, s.maxN)
        counts[i] = n
        local c = s.curve[n]
        if c and c < math.huge then cost = cost + c end
        baseRep = baseRep + n * s.repBase
        turnins = turnins + n
        if (s.tokenRep or 0) > 0 then
            tokens = tokens + n
            tokenRep = s.tokenRep
        end
    end
    -- nothing is being held back when we cannot reach the target anyway
    local finalRep = baseRep + tokens * tokenRep
    return {
        cost = cost, counts = counts, turnins = turnins, baseRep = baseRep,
        tokensMade = tokens, tokensUsed = tokens, tokensKept = 0,
        repAchieved = finalRep, overage = 0,
    }
end

--- Shopping list as STRUCTURED ROWS -- one row per distinct item to buy.
--
-- A bare quantity ("128 x Green Hakkari Bijou") is not actionable: the auction
-- house sells whole auctions, so you cannot buy 128 of anything directly. What
-- you can act on is a PRICE CUTOFF -- "buy every one listed at or below X" --
-- because that is how the auction browser is sorted. So each row also reports
-- the highest unit price among the auctions the solver actually chose, and how
-- many auctions that is.
--
-- @return rows  { item, qty, source, cutoff (copper per item), auctions, exact }
--         summary { name, turnins }
function Core.ShoppingRows(result, sources)
    local Opt = RO.Optimizer
    local rows, summary, byItem, itemOrder = {}, {}, {}, {}

    local function entry(name, sourceName)
        if not byItem[name] then
            byItem[name] = { item = name, qty = 0, source = sourceName,
                             cutoff = 0, auctions = 0, lots = {}, _pool = nil,
                             have = 0, need = 0 }
            itemOrder[#itemOrder + 1] = name
        end
        return byItem[name]
    end

    -- unit price as the auction browser shows it (per item, truncated)
    local function unitPrice(lot)
        if not lot.qty or lot.qty <= 0 then return lot.price or 0 end
        return math.floor((lot.price or 0) / lot.qty)
    end

    for i, grp in ipairs(sources) do
        local total = result.counts[i]
        if total and total > 0 then
            local members = grp.members or { grp }
            local per = (grp.unpack and grp.unpack(total)) or { total }
            for mi, src in ipairs(members) do
                local k = per[mi] or 0
                if k > 0 then
                    summary[#summary + 1] = { name = src.name, turnins = k }
                    for ci, comp in ipairs(src.def.components) do
                        local want = k * comp.perTurnin
                        local built = src.built and src.built.components[ci]
                        local froms = src.built and src.built.froms and src.built.froms[ci]
                        local picked = froms and Opt.Reconstruct(froms, want) or nil
                        if picked and built then
                            -- Stock in hand is drawn on, not consumed whole: a
                            -- 500-stack covering a 300 requirement leaves 200
                            -- in the bag. An AUCTION is different -- you buy
                            -- the whole lot -- so only the owned side is capped.
                            local ownedLeft = want
                            for _, lotIdx in ipairs(picked) do
                                local lot = built.lots[lotIdx]
                                local e = entry(lot.item or comp.items[1], src.name)
                                e._pool = built.lots
                                -- stock already in your bags is not a purchase
                                -- (no goto: WoW runs Lua 5.1)
                                if lot.owned then
                                    local use = lot.qty
                                    if use > ownedLeft then use = ownedLeft end
                                    if use < 0 then use = 0 end
                                    e.have = e.have + use
                                    e.need = e.need + use
                                    ownedLeft = ownedLeft - use
                                else
                                    e.need = e.need + lot.qty
                                    e.qty = e.qty + lot.qty
                                    e.auctions = e.auctions + 1
                                    local u = unitPrice(lot)
                                    if u > e.cutoff then e.cutoff = u end
                                    -- keep the exact auctions: buying
                                    -- cheapest-first up to the quantity
                                    -- overshoots badly (21% on a real book),
                                    -- so the specific stacks matter
                                    e.lots[#e.lots + 1] = { qty = lot.qty, unit = u }
                                end
                            end
                        else
                            local e = entry(comp.items[1], src.name)
                            e.qty = e.qty + want
                            e.need = e.need + want
                        end
                    end
                end
            end
        end
    end

    -- Is "buy everything at or below the cutoff" exactly this plan? It usually
    -- is, but the solver picks whole lots, so it can skip one at the same price.
    -- Say which, rather than quietly implying a rule that does not hold.
    for _, name in ipairs(itemOrder) do
        local e = byItem[name]
        if e._pool and e.cutoff > 0 then
            local atOrBelow = 0
            for _, lot in ipairs(e._pool) do
                -- stock in hand is not on the auction house, so it must not
                -- count towards "everything at or below the cutoff"
                if lot.item == name and not lot.owned
                   and unitPrice(lot) <= e.cutoff then
                    atOrBelow = atOrBelow + lot.qty
                end
            end
            e.exact = (atOrBelow == e.qty)
        else
            e.exact = false
        end
        e._pool = nil
        table.sort(e.lots, function(a, b) return a.unit < b.unit end)
        rows[#rows + 1] = e
    end
    return rows, summary
end

--- A TSM group import string for exactly the items on the shopping list.
-- TSM_API has no search function (verified against Core/API.lua: 31 functions,
-- none for shopping, search, browse or query), so the practical integration is
-- a group the player imports once and then searches in TSM Shopping.
-- @return string like "i:19698,i:19699" or nil if no IDs were captured
function Core.TSMImportString(rows, itemIds)
    if not rows or not itemIds then return nil end
    local parts, seen = {}, {}
    for _, r in ipairs(rows) do
        local id = itemIds[r.item]
        if id and not seen[id] then
            seen[id] = true
            parts[#parts + 1] = "i:" .. id
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, ",")
end
