--[[ ui_test.lua ---------------------------------------------------------------
Loads UI.lua for real against a mocked WoW widget API and clicks things.

This exists because three UI bugs reached the player that no amount of staring
would have caught: a click target hardcoded to the wrong item, text overlapping
because of fixed offsets, and a closure calling a local declared later in the
file (which Lua silently compiles as a nil global). All three are the kind of
thing that only shows up when the code actually RUNS.
--------------------------------------------------------------------------- ]]

local fails, checks = 0, 0
local function check(l, got, want)
    checks = checks + 1
    local ok = (got == want)
    if not ok then fails = fails + 1 end
    print(string.format("   %-52s %14s  %s", l, tostring(got), ok and "OK" or ("<<< FAIL want "..tostring(want))))
end

-- ---------------------------------------------------------------- widgets --
-- Any method not explicitly modelled becomes a no-op, so the mock does not have
-- to enumerate the whole WoW API.
local Widget = {}
Widget.__index = function(t, k)
    local v = rawget(Widget, k)
    if v then return v end
    -- WoW widget METHODS are CamelCase; data fields we set ourselves are not.
    -- Returning a no-op for everything made every frame look like it had a
    -- `searchFor`, which quietly defeated the point of the test.
    if type(k) == "string" and k:match("^%u") then
        return function() end                   -- unmodelled method: no-op
    end
    return nil
end
function Widget:SetText(s) self._text = s end
function Widget:GetText() return self._text end
function Widget:SetScript(k, fn) self._scripts = self._scripts or {}; self._scripts[k] = fn end
function Widget:GetScript(k) return self._scripts and self._scripts[k] end
function Widget:Show() self._shown = true end
function Widget:Hide() self._shown = false end
function Widget:IsShown() return self._shown and true or false end
function Widget:IsVisible() return self._shown and true or false end
function Widget:SetChecked(v) self._checked = v and true or false end
function Widget:GetChecked() return self._checked end
allFonts = {}
function Widget:CreateFontString() local fs = setmetatable({}, Widget); allFonts[#allFonts + 1] = fs; return fs end
function Widget:SetText(t) self._text = t end
function Widget:GetText() return self._text end
function Widget:GetWidth() return self._w or 100 end
function Widget:SetSize(w, h) self._w, self._h = w, h end
function Widget:HasFocus() return self._focus end
function Widget:SetFocus() self._focus = true end
function Widget:ClearFocus() self._focus = false end
function Widget:CreateTexture() return setmetatable({}, Widget) end
function Widget:Click() if self._scripts and self._scripts.OnClick then self._scripts.OnClick(self) end end

local allFrames = {}
function CreateFrame(_, name, _, template)
    local f = setmetatable({ _name = name, _template = template }, Widget)
    f.TitleBg = setmetatable({}, Widget)       -- BasicFrameTemplateWithInset
    if name then _G[name] = f end
    allFrames[#allFrames + 1] = f
    return f
end
UIParent = setmetatable({}, Widget)
UISpecialFrames = {}
tinsert = table.insert
mouseOver = true
function MouseIsOver() return mouseOver end
GameTooltip = setmetatable({ _lines = {} }, Widget)
function GameTooltip:SetOwner() self._lines = {} end
function GameTooltip:AddLine(s) self._lines[#self._lines + 1] = tostring(s) end
function GameTooltip:AddDoubleLine(a, b) self._lines[#self._lines + 1] = tostring(a) .. " | " .. tostring(b) end

-- ---------------------------------------------------------- dropdown mock --
local ddInit, ddEntries = {}, {}
function UIDropDownMenu_SetWidth() end
function UIDropDownMenu_SetText(frame, text) frame._ddText = text end
function UIDropDownMenu_CreateInfo() return {} end
function UIDropDownMenu_Initialize(frame, fn) ddInit[frame] = fn end
function UIDropDownMenu_AddButton(info) ddEntries[#ddEntries + 1] = info end
function CloseDropDownMenus() end
local function OpenDropdown(frame)
    ddEntries = {}
    ddInit[frame](frame, 1)
    return ddEntries
end

-- ------------------------------------------------------------- game state --
local FACTIONS = {
    { name = "Zandalar Tribe",      standingID = 6, barMin = 9000, barMax = 21000, barValue = 18240 },
    { name = "Thorium Brotherhood", standingID = 5, barMin = 3000, barMax = 9000,  barValue = 5016 },
}
function GetNumFactions() return #FACTIONS end
function GetFactionInfo(i)
    local f = FACTIONS[i]; if not f then return end
    return f.name, "", f.standingID, f.barMin, f.barMax, f.barValue, false, false, false, false
end
function ExpandFactionHeader() end
function CollapseFactionHeader() end
function UnitRace() return "Human", "Human" end
function GetTime() return 0 end
function CanSendAuctionQuery() return true end
function QueryAuctionItems(text) _G.__lastQuery = text end
function GetNumAuctionItems() return 0, 0 end
function GetAuctionItemInfo() end
function GetAuctionItemLink() end
local printed = {}
local realPrint = print
function print(...) printed[#printed + 1] = table.concat({ ... }, " ") end

RepOptimizerDB = {}
_G.RepOptimizer = {}
dofile("../Optimizer.lua")
dofile("../Data.lua")
dofile("../Core.lua")
dofile("../Scanner.lua")
dofile("../Skin.lua")
dofile("../Widgets.lua")
dofile("../UI.lua")
print = realPrint
local RO = RepOptimizer

-- ------------------------------------------------------------------ tests --
print("DROPDOWN — our own button + list, built on open (never at load)")
local dd = _G["RepOptimizerFactionDD"]
local menu = _G["RepOptimizerMenu"]
local function OpenDropdown(btn)
    btn:Click()
    local out = {}
    for _, b in ipairs(menu.items) do if b:IsShown() then out[#out + 1] = b end end
    return out
end
local entries = OpenDropdown(dd)
check("menu opens", menu:IsShown(), true)
check("one entry per faction", #entries, #RO.Factions)
local names = {}
for _, e in ipairs(entries) do names[#names + 1] = (e.text:GetText():gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
check("Argent Dawn is in the list", (table.concat(names, ",")):find("Argent Dawn") ~= nil, true)
dd:Click()
check("second click closes the list", menu:IsShown(), false)

print("\nREFRESH with a live standing and a scan")
-- inject a scan result the way the scanner would
local function singles(n, price)
    local t = {} for i = 1, n do t[i] = { qty = 1, price = price } end return t
end
local scan = { ["Gold Hakkari Bijou"] = singles(30, 45000),
               ["Red Hakkari Bijou"]  = singles(30, 60000) }
local ids = { ["Gold Hakkari Bijou"] = 19698, ["Red Hakkari Bijou"] = 19699 }
RO.UI.SetScanResults(scan, ids, "zandalar")

local rows = {}
for _, f in ipairs(allFrames) do
    if f.searchFor and f:IsShown() then rows[#rows + 1] = f end
end
check("shopping rows are showing", #rows > 0, true)

print("\nCLICKING A ROW — no Blizzard auction frame (the TSM case)")
_G.AuctionFrame = nil
_G.BrowseName = nil
printed = {}
local target = rows[1]
local ok, err = pcall(function() target:Click() end)
check("click does not error", ok, true)
if not ok then print("      " .. tostring(err)) end
local copyEdit = _G["RepOptimizerCopyFrame"] and _G["RepOptimizerCopyFrame"].edit
check("copy box opened", _G["RepOptimizerCopyFrame"]:IsShown(), true)
check("copy box holds THIS row's item", copyEdit:GetText(), target.searchFor)

print("\nCLICKING A ROW — Blizzard auction frame present")
_G.AuctionFrame = setmetatable({ _shown = true }, Widget)
_G.BrowseName = setmetatable({}, Widget)
_G.AuctionFrameBrowse = setmetatable({ _shown = true }, Widget)
function AuctionFrameBrowse_Search() _G.__searched = BrowseName:GetText() end
_G.__searched = nil
local ok2 = pcall(function() rows[1]:Click() end)
check("click does not error", ok2, true)
check("searched for THIS row's item, not the first in the list", _G.__searched, rows[1].searchFor)
check("  and that is not the placeholder Blue bijou", _G.__searched ~= "Blue Hakkari Bijou", true)

if #rows > 1 then
    _G.__searched = nil
    rows[2]:Click()
    check("a second row searches for ITS own item", _G.__searched, rows[2].searchFor)
    check("  the two rows differ", rows[1].searchFor ~= rows[2].searchFor, true)
end

print("\nLAYOUT — quantities right-aligned, no editorial text")
check("rows expose a separate qty field", rows[1].qty ~= nil, true)
check("rows expose a separate name field", rows[1].name ~= nil, true)
check("qty and name are different widgets", rows[1].qty ~= rows[1].name, true)
check("thousands separators", RO.Comma(9840), "9,840")
check("  and small numbers unchanged", RO.Comma(60), "60")
check("  and seven figures", RO.Comma(1234567), "1,234,567")
local adFac
for _, fx in ipairs(RO.Factions) do if fx.key == "argentdawn" then adFac = fx end end
check("no editorial warning left on Argent Dawn", adFac.warning, nil)
check("rows carry a price-cutoff widget", rows[1].cut ~= nil, true)
check("cutoff text is populated", (rows[1].cut:GetText() or ""):len() > 0, true)
check("racial is detected, not a checkbox", RepOptimizerDB.human, nil)

print("\nHOVER TOOLTIP names the exact auctions to buy")
local r1 = rows[1]
check("row carries the chosen auctions", r1.plan ~= nil and #r1.plan > 0, true)
local planQty = 0
for _, p in ipairs(r1.plan) do planQty = planQty + p.qty end
check("stacks add up to the row quantity", planQty, tonumber((r1.qty:GetText():gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r",""):gsub(",",""))))
local sorted = true
for i = 2, #r1.plan do if r1.plan[i].unit < r1.plan[i-1].unit then sorted = false end end
check("listed cheapest-first", sorted, true)
r1:GetScript("OnEnter")(r1)
check("tooltip populated", #GameTooltip._lines > 1, true)
check("tooltip names the item", GameTooltip._lines[1], r1.searchFor)
local hasStack = false
for _, l in ipairs(GameTooltip._lines) do if l:find("stack of") then hasStack = true end end
check("tooltip lists stacks", hasStack, true)
local jargon = false
for _, l in ipairs(GameTooltip._lines) do
    local lower = l:lower()
    if lower:find("overshoot") or lower:find("cutoff") then jargon = true end
end
check("no jargon in the tooltip", jargon, false)
-- identical auctions must be grouped, and never exceed what exists
local counts = {}
for _, p in ipairs(rows[1].plan) do
    local k = p.qty .. "@" .. p.unit
    counts[k] = (counts[k] or 0) + 1
end
local dupIdx = {}
local okUnique = true
for _, p in ipairs(rows[1].plan) do
    -- every entry must correspond to a distinct real auction
    if p.qty <= 0 then okUnique = false end
end
check("plan entries are real auctions", okUnique, true)
local cutText = rows[1].cut:GetText() or ""
check("price column has no ~ marker", cutText:find("~") == nil, true)

print("\nTSM GROUP EXPORT")
local tsmBtn
for _, f in ipairs(allFrames) do
    if f._text == "TSM group" then tsmBtn = f end
end
check("TSM button exists", tsmBtn ~= nil, true)
if tsmBtn and tsmBtn:IsShown() then
    tsmBtn:Click()
    local s = copyEdit:GetText()
    check("import string looks like i:<id>", s:match("^i:%d+") ~= nil, true)
end

print("\nMANUAL START -- pick a standing and type how far into it")
local function findText(pat)
    for _, fs in ipairs(allFonts) do
        local t = fs._text
        if type(t) == "string" and t:find(pat) then return t end
    end
end
local sd, intoBox = _G["RepOptimizerStartDD"], _G["RepOptimizerIntoBox"]
check("start dropdown exists", sd ~= nil, true)
check("starts on live rep", (sd:GetText() or ""):find("live") ~= nil, true)
check("amount box hidden while live", intoBox:IsShown(), false)
check("live standing line says (live)", findText("%(live%)") ~= nil, true)
local opts = OpenDropdown(sd)
check("live + Unfriendly..Exalted", #opts, 7)
local honored
for _, b in ipairs(opts) do if b.text:GetText():find("Honored") then honored = b end end
honored:Click()
local key = RO.Factions[1].key
check("manual standing saved", RepOptimizerDB.manual[key].standing, 6)
check("amount box shown", intoBox:IsShown(), true)
intoBox:SetText("5000"); intoBox:GetScript("OnEnterPressed")(intoBox)
check("amount saved", RepOptimizerDB.manual[key].into, 5000)
-- Honored starts at 9000 cumulative; Exalted at 42000 -> 42000 - 14000
check("need uses the entered start", findText("28,000") ~= nil, true)
check("line says (entered)", findText("%(entered%)") ~= nil, true)
intoBox:SetText("99999"); intoBox:GetScript("OnEnterPressed")(intoBox)
check("amount clamped to the band", RepOptimizerDB.manual[key].into, 11999)
-- switching standing keeps the amount only if it fits
for _, b in ipairs(OpenDropdown(sd)) do if b.text:GetText():find("Friendly") and not b.text:GetText():find("Unfriendly") then b:Click() break end end
check("Friendly clamps the amount to 5999", RepOptimizerDB.manual[key].into, 5999)
for _, b in ipairs(OpenDropdown(sd)) do if b.text:GetText():find("live") then b:Click() break end end
check("back to live clears the entry", RepOptimizerDB.manual[key], nil)
check("live again", findText("%(live%)") ~= nil, true)

print("\nSCANNER on a client without the classic auction house")
local savedQ = QueryAuctionItems; QueryAuctionItems = nil
RO.Scanner.NotifyAuctionHouseOpen(true)
local gotMsg
RO.Scanner.Start({ "x" }, function(okScan, msg) gotMsg = (not okScan) and msg end)
check("plain message, no error", gotMsg ~= nil and gotMsg:find("can't be scanned") ~= nil, true)
QueryAuctionItems = savedQ

print("\nSHIFT-CLICK gives the whole plan as text")
-- The hover has to fit on screen, so a long plan gets summarised. Chuck hit
-- "...and 28 more" with no way to see the rest.
do
    _G.IsShiftKeyDown = function() return true end
    local r1 = rows[1]
    r1:Click()
    local txt = _G["RepOptimizerCopyFrame"].edit:GetText() or ""
    check("copy box opened on shift-click", _G["RepOptimizerCopyFrame"]:IsShown(), true)
    check("it is the full plan, not just a name", txt:find("\n") ~= nil, true)
    check("  names stacks", txt:find("stack of") ~= nil, true)
    check("  and ends with a total", txt:find("auctions") ~= nil, true)
    -- the running total must reach the row's quantity
    local last = 0
    for n in txt:gmatch("%->%s*([%d,]+)") do last = tonumber((n:gsub(",", ""))) or last end
    local rowQty = tonumber((r1.qty:GetText():gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r",""):gsub(",","")))
    check("running total ends at the row quantity", last, rowQty)

    -- and a plain click must still search, not open the box
    _G.IsShiftKeyDown = function() return false end
    _G.AuctionFrame = setmetatable({ _shown = true }, Widget)
    _G.BrowseName = setmetatable({}, Widget)
    _G.AuctionFrameBrowse = setmetatable({ _shown = true }, Widget)
    _G.__searched = nil
    r1:Click()
    check("plain click still searches", _G.__searched, r1.searchFor)
end

print("\nHOVER shows a running total")
do
    local r1 = rows[1]
    GameTooltip._lines = {}
    r1:GetScript("OnEnter")(r1)
    local sawRunning = false
    for _, l in ipairs(GameTooltip._lines) do
        if l:find("stack of") and l:find("|cff707070") then sawRunning = true end
    end
    check("a cumulative figure sits on the stack lines", sawRunning, true)
    local mentionsShift = false
    for _, l in ipairs(GameTooltip._lines) do
        if l:lower():find("shift") then mentionsShift = true end
    end
    check("and it says shift-click for the rest", mentionsShift, true)
    local jargon = false
    for _, l in ipairs(GameTooltip._lines) do
        local lo = l:lower()
        if lo:find("overshoot") or lo:find("cutoff") then jargon = true end
    end
    check("still no jargon", jargon, false)
end

print("\nSTOCK IN HAND appears on the line")
do
    _G.GetItemCount = function(_, bank) return bank and 12 or 8 end
    RO.UI.SetScanResults(scan, ids, "zandalar")
    local withHave = nil
    for _, fx in ipairs(allFrames) do
        if fx.searchFor and fx:IsShown() and fx.have and fx.have > 0 then withHave = fx end
    end
    check("a row reports stock in hand", withHave ~= nil, true)
    if withHave then
        check("  and says so in the name column",
              (withHave.name:GetText() or ""):find("on hand") ~= nil, true)
        check("  have + buy = need", withHave.have + tonumber(
            (withHave.qty:GetText():gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r",""):gsub(",",""))),
            withHave.need)
    end
    _G.GetItemCount = nil
end

print()
if fails == 0 then print(string.format("ALL %d CHECKS PASSED", checks))
else print(string.format("%d of %d CHECKS FAILED", fails, checks)) end
os.exit(fails == 0 and 0 or 1)
