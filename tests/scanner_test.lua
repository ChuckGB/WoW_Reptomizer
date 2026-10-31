-- Reproduce the AUCTION_ITEM_LIST_UPDATE crash with a mocked WoW frame API.
local fails, checks = 0, 0
local function check(l, got, want)
    checks = checks + 1
    local ok = (got == want)
    if not ok then fails = fails + 1 end
    print(string.format("   %-52s %12s  %s", l, tostring(got), ok and "OK" or ("<<< FAIL want "..tostring(want))))
end

-- ---- mock frames + auction API ------------------------------------------
local theFrame
function CreateFrame()
    local f = { scripts = {}, events = {} }
    function f:SetScript(k, fn) self.scripts[k] = fn end
    function f:RegisterEvent(e) self.events[e] = true end
    function f:UnregisterEvent(e) self.events[e] = nil end
    theFrame = f
    return f
end
local now = 0
function GetTime() return now end

local BOOK = {}          -- item name -> array of {count, buyout}
local lastQuery
function CanSendAuctionQuery() return true end
function QueryAuctionItems(text, _, _, page) lastQuery = { text = text, page = page } end
function GetNumAuctionItems() local b = BOOK[lastQuery.text] or {} return #b, #b end
function GetAuctionItemInfo(_, i)
    local row = (BOOK[lastQuery.text] or {})[i]
    if not row then return end
    return lastQuery.text, nil, row[1], nil, nil, nil, nil, nil, nil, row[2]
end
AuctionFrame = { IsShown = function() return true end }

_G.RepOptimizer = { }
dofile("../Scanner.lua")
local S = RepOptimizer.Scanner

-- ---- the exact shape that crashed: one item, one page, 32 results --------
BOOK["Gold Hakkari Bijou"] = {}
for i = 1, 32 do BOOK["Gold Hakkari Bijou"][i] = { 1, 45000 } end

print("SINGLE ITEM, ONE PAGE (the case that crashed on live)")
local done, payload = false, nil
S.NotifyAuctionHouseOpen(true)
S.Start({ "Gold Hakkari Bijou" }, function(ok, res) done = true; payload = { ok, res } end)

local ok, err = pcall(function()
    -- drive the OnUpdate/OnEvent loop the way the client would
    for tick = 1, 12 do
        now = now + 0.6
        if theFrame.scripts.OnUpdate then theFrame.scripts.OnUpdate() end
        if theFrame.scripts.OnEvent then theFrame.scripts.OnEvent(theFrame, "AUCTION_ITEM_LIST_UPDATE") end
        if done then break end
    end
end)
check("no Lua error while finishing the scan", ok, true)
if not ok then print("      error was: " .. tostring(err)) end
check("callback fired", done, true)
check("callback reported success", payload and payload[1], true)
check("harvested all 32 listings", payload and payload[2] and #payload[2]["Gold Hakkari Bijou"], 32)
check("scan no longer running", S.IsRunning(), false)

print("\nA STRAY EVENT AFTER THE SCAN ENDED MUST BE IGNORED")
local ok2 = pcall(function() theFrame.scripts.OnEvent(theFrame, "AUCTION_ITEM_LIST_UPDATE") end)
check("late event does not error", ok2, true)
local ok3 = pcall(function() theFrame.scripts.OnUpdate() end)
check("idle OnUpdate does not error", ok3, true)

print("\nAUCTION HOUSE CLOSED MID-SCAN")
BOOK["Zulian Coin"] = { {1, 10000} }
local done2, res2 = false, nil
S.NotifyAuctionHouseOpen(true)
S.Start({ "Gold Hakkari Bijou", "Zulian Coin" }, function(ok, r) done2 = true; res2 = r end)
now = now + 0.6
theFrame.scripts.OnUpdate()
S.NotifyAuctionHouseOpen(false)          -- player walks away
local ok4 = pcall(function() now = now + 0.6; theFrame.scripts.OnUpdate() end)
check("closing the AH does not error", ok4, true)
check("scan stopped", S.IsRunning(), false)
check("caller was told why", type(res2) == "string", true)

print("\nTWO SCANS IN A ROW (the OnUpdate pump must survive the first)")
local function runScan(items)
    local fin, out = false, nil
    S.NotifyAuctionHouseOpen(true)
    S.Start(items, function(ok, r) fin = true; out = { ok, r } end)
    for tick = 1, 40 do
        now = now + 0.6
        if theFrame.scripts.OnUpdate then theFrame.scripts.OnUpdate() end
        if theFrame.scripts.OnEvent then theFrame.scripts.OnEvent(theFrame, "AUCTION_ITEM_LIST_UPDATE") end
        if fin then break end
    end
    return fin, out
end
local f1 = runScan({ "Gold Hakkari Bijou" })
check("first scan completes", f1, true)
local f2, o2 = runScan({ "Gold Hakkari Bijou", "Zulian Coin" })
check("SECOND scan also completes", f2, true)
check("second scan returned data", o2 and o2[1], true)
check("second scan got both items", o2 and o2[2] and
      (#o2[2]["Gold Hakkari Bijou"] + #o2[2]["Zulian Coin"]), 33)
local f3 = runScan({ "Gold Hakkari Bijou" })
check("third scan completes too", f3, true)

print("\nSCAN REFUSED WHEN THE AUCTION HOUSE IS SHUT")
local msg
S.NotifyAuctionHouseOpen(false)
S.Start({ "Gold Hakkari Bijou" }, function(ok, r) msg = r end)
check("refused", type(msg) == "string", true)

print()
if fails == 0 then print(string.format("ALL %d CHECKS PASSED", checks))
else print(string.format("%d of %d CHECKS FAILED", fails, checks)) end
os.exit(fails == 0 and 0 or 1)
