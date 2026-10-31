--[[ Compat.lua ----------------------------------------------------------------
Which auction house are we talking to, and what does that change?

Classic Era has the original API: QueryAuctionItems, paged browse results, and
one row per AUCTION. You buy a whole auction or none of it.

Forever has the retail C_AuctionHouse API. Verified by reading Blackthorne's
own scanner on a live Forever install -- it calls SendSearchQuery, MakeItemKey,
GetNumCommoditySearchResults / GetCommoditySearchResultInfo for commodities and
GetNumItemSearchResults / GetItemSearchResultInfo for everything else, and
waits on COMMODITY_SEARCH_RESULTS_UPDATED / ITEM_SEARCH_RESULTS_UPDATED.

The difference that matters to the optimizer is NOT the function names.

    On a modern auction house a COMMODITY IS DIVISIBLE.

Cloth, ore, fragments -- the stackable trade goods every big reputation grind
runs on -- are sold by the unit from a shared pool. "Buy 128 Runecloth" is a
single, legal purchase. The whole covering-knapsack-over-lots apparatus exists
because Classic cannot do that, and on Forever commodities simply do not need
it: the cheapest way to buy n units is to walk the price ladder, which is a
prefix sum and exact.

So the Forever port makes the hardest factions EASIER, not harder, and the
duplicate-auction class of bug cannot arise for commodities at all. Non-
commodity items on Forever still behave like Classic auctions and still need
the lot solver, so both paths have to stay.
--------------------------------------------------------------------------- ]]

local RO = _G.RepOptimizer or {}
_G.RepOptimizer = RO

local Compat = {}
RO.Compat = Compat

--- The original paged auction API.
function Compat.HasClassicAH()
    return type(_G.QueryAuctionItems) == "function"
       and type(_G.GetAuctionItemInfo) == "function"
end

--- The retail-style C_AuctionHouse API, as Forever uses.
function Compat.HasModernAH()
    local C = _G.C_AuctionHouse
    return type(C) == "table"
       and type(C.SendSearchQuery) == "function"
       and type(C.MakeItemKey) == "function"
end

--- "classic", "modern", or "none" when neither is present (no AH open, or a
--- client we have not met). Never raises.
function Compat.Flavour()
    if Compat.HasModernAH() then return "modern" end
    if Compat.HasClassicAH() then return "classic" end
    return "none"
end

--- Is this item bought by the unit rather than by the whole auction?
--
-- Only ever true on a modern auction house. Answering nil means "we could not
-- tell", which callers must treat as indivisible: assuming divisibility when
-- it does not hold is exactly how a plan ends up telling someone to buy a
-- quantity that cannot be bought.
--
-- @return true, false, or nil when unknown
function Compat.IsDivisible(itemID)
    if not itemID or not Compat.HasModernAH() then return false end
    local C = _G.C_AuctionHouse
    if type(C.GetItemCommodityStatus) ~= "function"
    or type(C.MakeItemKey) ~= "function" then
        return nil
    end
    local ok, status = pcall(function()
        return C.GetItemCommodityStatus(C.MakeItemKey(itemID))
    end)
    if not ok or status == nil then return nil end
    -- Enum.ItemCommodityStatus: 1 = Item, 2 = Commodity
    if status == 2 then return true end
    if status == 1 then return false end
    return nil
end

return Compat
