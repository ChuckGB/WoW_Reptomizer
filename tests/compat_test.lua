-- Compat.lua against both auction-house flavours, mocked.
--
-- The point of this file is the SAFETY of the divisibility answer. Treating an
-- indivisible item as divisible is how a shopping list ends up naming a
-- quantity nobody can buy, so "we could not tell" must never read as "yes".
local fails, checks = 0, 0
local function check(l, got, want)
    checks = checks + 1
    local ok = (got == want)
    if not ok then fails = fails + 1 end
    print(string.format("   %-52s %14s  %s", l, tostring(got), ok and "OK" or ("<<< FAIL want "..tostring(want))))
end

_G.RepOptimizer = {}
dofile("../Compat.lua")
local Compat = RepOptimizer.Compat

local function clearAH()
    _G.QueryAuctionItems, _G.GetAuctionItemInfo, _G.C_AuctionHouse = nil, nil, nil
end

print("NO AUCTION HOUSE AT ALL")
clearAH()
check("flavour is none", Compat.Flavour(), "none")
check("not classic", Compat.HasClassicAH(), false)
check("not modern", Compat.HasModernAH(), false)
check("nothing is divisible", Compat.IsDivisible(2589), false)

print("\nCLASSIC ERA — the original paged API")
clearAH()
_G.QueryAuctionItems = function() end
_G.GetAuctionItemInfo = function() end
check("flavour is classic", Compat.Flavour(), "classic")
check("classic detected", Compat.HasClassicAH(), true)
check("modern not detected", Compat.HasModernAH(), false)
check("nothing is divisible on Classic", Compat.IsDivisible(2589), false)

print("\nFOREVER — the retail C_AuctionHouse API")
clearAH()
local COMMODITY = { [2589] = 2, [19698] = 1 }    -- Linen is a commodity, a bijou is not
_G.C_AuctionHouse = {
    SendSearchQuery = function() end,
    MakeItemKey = function(id) return { itemID = id } end,
    GetItemCommodityStatus = function(key) return COMMODITY[key.itemID] end,
}
check("flavour is modern", Compat.Flavour(), "modern")
check("modern detected", Compat.HasModernAH(), true)
check("classic not detected", Compat.HasClassicAH(), false)
check("cloth is divisible", Compat.IsDivisible(2589), true)
check("a bijou is not", Compat.IsDivisible(19698), false)

print("\n  UNKNOWN must never read as divisible")
check("an item the client has no status for", Compat.IsDivisible(1234), nil)
_G.C_AuctionHouse.GetItemCommodityStatus = function() error("secret item") end
check("a raising API answers nil, it does not propagate", Compat.IsDivisible(2589), nil)
_G.C_AuctionHouse.GetItemCommodityStatus = nil
check("a missing status call answers nil", Compat.IsDivisible(2589), nil)
check("  and the flavour is still modern", Compat.Flavour(), "modern")

print("\n  both APIs present: modern wins")
_G.QueryAuctionItems = function() end
_G.GetAuctionItemInfo = function() end
_G.C_AuctionHouse.GetItemCommodityStatus = function(key) return COMMODITY[key.itemID] end
check("flavour prefers modern", Compat.Flavour(), "modern")

print()
if fails == 0 then print(string.format("ALL %d CHECKS PASSED", checks))
else print(string.format("%d of %d CHECKS FAILED", fails, checks)) end
os.exit(fails == 0 and 0 or 1)
