--[[ UI.lua --------------------------------------------------------------------
A single window: pick a faction and a target, scan, read the shopping list.

Layout rules, learned the hard way:
  * nothing sits at a fixed offset that variable-length text can grow into --
    every block anchors to the bottom of the one above it;
  * the shopping list lives in its own fixed-height region above the buttons,
    so a long list can never collide with them;
  * quantities are right-aligned in their own column, because
    "60 / 50 / 90 / 9840" is unreadable when the digits do not line up;
  * the window reports numbers and does not editorialise about them.

Buying stays manual: PlaceAuctionBid needs a hardware event, so nothing here
clicks for you.
--------------------------------------------------------------------------- ]]

local RO = _G.RepOptimizer
local Core = RO.Core

local WIDTH, HEIGHT = 470, 530
local PAD = 16
local INNER = WIDTH - PAD * 2
local ROW_H = 15
local MAX_ROWS = 11

local f = CreateFrame("Frame", "RepOptimizerFrame", UIParent, "BasicFrameTemplateWithInset")
f:SetSize(WIDTH, HEIGHT)
f:SetPoint("CENTER")
f:SetMovable(true)
f:EnableMouse(true)
f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", f.StartMoving)
f:SetScript("OnDragStop", f.StopMovingOrSizing)
f:SetFrameStrata("HIGH")
f:Hide()
RO.Frame = f
RO.Skin.Register("frames", f)
if f.CloseButton then RO.Skin.Register("closes", f.CloseButton) end
tinsert(UISpecialFrames, "RepOptimizerFrame")   -- Escape closes it

f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
f.title:SetPoint("TOP", f.TitleBg, "TOP", 0, -4)
f.title:SetText("Reputation Optimizer")

--- Thousands separators. "9840 x Dark Iron Scraps" is hard to read at a glance.
local function comma(n)
    if type(n) ~= "number" then return tostring(n) end
    local s = tostring(math.floor(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end
RO.Comma = comma

local function newText(font, width)
    local fs = f:CreateFontString(nil, "OVERLAY", font)
    fs:SetWidth(width or INNER)
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    fs:SetWordWrap(true)
    return fs
end

local function divider(anchorTo, gap)
    local line = f:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1)
    line:SetColorTexture(1, 1, 1, 0.12)
    line:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, -(gap or 8))
    line:SetPoint("TOPRIGHT", anchorTo, "BOTTOMRIGHT", 0, -(gap or 8))
    return line
end

-- ---- copy box ------------------------------------------------------------
-- WoW gives addons no clipboard access, so the standard trick is an EditBox
-- with the text pre-selected and the player presses Ctrl+C. It is the only way
-- to hand anything to a replacement auction UI such as TSM, which exposes no
-- search API at all.
local copyBox = CreateFrame("Frame", "RepOptimizerCopyFrame", UIParent, "BasicFrameTemplateWithInset")
copyBox:SetSize(430, 132)
copyBox:SetPoint("CENTER", 0, 140)
copyBox:SetFrameStrata("FULLSCREEN_DIALOG")
copyBox:EnableMouse(true)
copyBox:SetMovable(true)
copyBox:RegisterForDrag("LeftButton")
copyBox:SetScript("OnDragStart", copyBox.StartMoving)
copyBox:SetScript("OnDragStop", copyBox.StopMovingOrSizing)
copyBox:Hide()
copyBox.caption = copyBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
copyBox.caption:SetPoint("TOPLEFT", 16, -32)
copyBox.caption:SetWidth(398)
copyBox.caption:SetJustifyH("LEFT")
copyBox.caption:SetJustifyV("TOP")
RO.Skin.Register("frames", copyBox)
if copyBox.CloseButton then RO.Skin.Register("closes", copyBox.CloseButton) end
copyBox.edit = CreateFrame("EditBox", nil, copyBox, "InputBoxTemplate")
RO.Skin.Register("editboxes", copyBox.edit)
copyBox.edit:SetSize(390, 22)
copyBox.edit:SetPoint("BOTTOMLEFT", 22, 36)
copyBox.edit:SetAutoFocus(true)
copyBox.edit:SetScript("OnEscapePressed", function() copyBox:Hide() end)
copyBox.edit:SetScript("OnEnterPressed", function() copyBox:Hide() end)
copyBox.hint = copyBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
copyBox.hint:SetPoint("BOTTOMLEFT", 22, 16)
copyBox.hint:SetText("Ctrl+C to copy, Escape to close.")

local function ShowCopy(caption, text)
    copyBox.caption:SetText(caption)
    copyBox.edit:SetText(text)
    copyBox:Show()
    copyBox.edit:SetFocus()
    copyBox.edit:HighlightText()
end
RO.ShowCopy = ShowCopy

-- ---- header --------------------------------------------------------------
local selectedFaction = RO.Factions[1]
local selectedTarget = 8                                  -- Exalted

-- Header row. Our own dropdowns (Widgets.lua), at fixed offsets.
local UI = {}
RO.UI = UI

-- How many grouped auction lines a hover will show before it has to summarise.
-- A tooltip must fit on screen; shift-click gives the rest as copyable text.
local MAX_TIP_LINES = 16

--- The whole plan for one row, as plain text with a running total.
--
-- Declared here, not further down: a closure that calls a local declared later
-- in the file compiles as a nil global, which has bitten this file before.
function UI.PlanText(row)
    if not row or not row.plan or #row.plan == 0 then
        return row and row.searchFor or ""
    end
    local grouped, order = {}, {}
    for _, p in ipairs(row.plan) do
        local key = p.qty .. "@" .. p.unit
        if not grouped[key] then
            grouped[key] = { qty = p.qty, unit = p.unit, n = 0 }
            order[#order + 1] = key
        end
        grouped[key].n = grouped[key].n + 1
    end
    local strip = function(s) return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
    local out, running = {}, 0
    if row.have and row.have > 0 then
        out[#out + 1] = string.format("%s on hand (bags + bank)", RO.Comma(row.have))
    end
    for _, key in ipairs(order) do
        local g = grouped[key]
        running = running + g.qty * g.n
        out[#out + 1] = string.format("%s x stack of %s @ %s each   -> %s",
            RO.Comma(g.n), RO.Comma(g.qty), strip(RO.Money(g.unit)), RO.Comma(running))
    end
    out[#out + 1] = string.format("buy %s in %d auctions%s",
        RO.Comma(row.qty or running), #row.plan,
        row.cutoff and row.cutoff > 0
            and (", none above " .. strip(RO.Money(row.cutoff))) or "")
    return table.concat(out, "\n")
end

local dd = RO.Widgets.Dropdown(f, "RepOptimizerFactionDD", 210, function()
    local items = {}
    for _, fac in ipairs(RO.Factions) do
        items[#items + 1] = { text = fac.name, selected = fac.key == selectedFaction.key,
                              onClick = function() selectedFaction = fac; UI.Refresh() end }
    end
    return items
end)
dd:SetPoint("TOPLEFT", PAD, -32)

local td = RO.Widgets.Dropdown(f, "RepOptimizerTargetDD", 130, function()
    local items = {}
    for id = 5, 8 do
        items[#items + 1] = { text = RO.StandingName[id], selected = id == selectedTarget,
                              onClick = function() selectedTarget = id; UI.Refresh() end }
    end
    return items
end)
td:SetPoint("LEFT", dd, "RIGHT", 10, 0)

-- ---- starting point: live from the game, or typed in ---------------------
-- Live is the default. Entering a standing and an amount is for planning ahead
-- (another character, or "what will it cost from Honored?") and is remembered
-- per faction until set back to live.
local function manualFor(fac)
    local m = RepOptimizerDB and RepOptimizerDB.manual and RepOptimizerDB.manual[fac.key]
    if m and RO.StandingStart[m.standing] then return m end
end
local function setManual(fac, m)
    RepOptimizerDB.manual = RepOptimizerDB.manual or {}
    RepOptimizerDB.manual[fac.key] = m
end
--- Rep needed to go from the start of a standing to the next one.
local function bandSize(standing)
    local nextStart = RO.StandingStart[standing + 1]
    return nextStart and (nextStart - RO.StandingStart[standing]) or 1000   -- Exalted: 999 is the cap
end
UI.bandSize = bandSize

local startLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
startLabel:SetPoint("TOPLEFT", dd, "BOTTOMLEFT", 0, -12)
startLabel:SetText("Start from:")

local intoBox, intoLabel
local sd = RO.Widgets.Dropdown(f, "RepOptimizerStartDD", 150, function()
    local m = manualFor(selectedFaction)
    local items = { { text = "My current rep (live)", selected = m == nil,
                      onClick = function() setManual(selectedFaction, nil); UI.Refresh() end } }
    for id = 3, 8 do
        items[#items + 1] = { text = RO.StandingName[id], selected = m ~= nil and m.standing == id,
            onClick = function()
                local into = m and math.min(m.into, bandSize(id) - 1) or 0
                setManual(selectedFaction, { standing = id, into = into })
                UI.Refresh()
                intoBox:SetFocus()
                intoBox:HighlightText()
            end }
    end
    return items
end)
sd:SetPoint("LEFT", startLabel, "RIGHT", 8, 0)

intoBox = CreateFrame("EditBox", "RepOptimizerIntoBox", f, "InputBoxTemplate")
intoBox:SetSize(60, 20)
intoBox:SetPoint("LEFT", sd, "RIGHT", 14, 0)
intoBox:SetAutoFocus(false)
intoBox:SetNumeric(true)
intoBox:SetMaxLetters(5)
intoBox:SetJustifyH("RIGHT")
RO.Skin.Register("editboxes", intoBox)
intoLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
intoLabel:SetPoint("LEFT", intoBox, "RIGHT", 6, 0)

local function commitInto(self)
    local m = manualFor(selectedFaction)
    if m then
        local n = tonumber(self:GetText() or "") or 0
        m.into = math.max(0, math.min(n, bandSize(m.standing) - 1))
    end
    self:ClearFocus()
    UI.Refresh()
end
intoBox:SetScript("OnEnterPressed", commitInto)
intoBox:SetScript("OnEditFocusLost", function(self)
    local m = manualFor(selectedFaction)
    if m and tonumber(self:GetText() or "") ~= m.into then commitInto(self) end
end)
intoBox:SetScript("OnEscapePressed", function(self) self:ClearFocus(); UI.Refresh() end)

local standingLine = newText("GameFontNormalSmall")
standingLine:SetPoint("TOPLEFT", startLabel, "BOTTOMLEFT", 0, -14)

local div1 = divider(standingLine, 8)

-- ---- headline result -----------------------------------------------------
local verdictLine = newText("GameFontHighlightSmall")
verdictLine:SetPoint("TOPLEFT", div1, "BOTTOMLEFT", 0, -10)

local costLine = newText("GameFontNormalLarge")
costLine:SetPoint("TOPLEFT", verdictLine, "BOTTOMLEFT", 0, -6)

local detailLine = newText("GameFontDisableSmall")
detailLine:SetPoint("TOPLEFT", costLine, "BOTTOMLEFT", 0, -6)

-- ---- shopping list, in its own fixed region ------------------------------
-- Fixed region means a long list can never grow into the buttons below, which
-- is exactly what the previous layout did.
local listAnchor = CreateFrame("Frame", nil, f)
listAnchor:SetPoint("BOTTOMLEFT", PAD, 74)
listAnchor:SetSize(INNER, ROW_H * MAX_ROWS)

local listHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
listHeader:SetPoint("BOTTOMLEFT", listAnchor, "TOPLEFT", 0, 8)
listHeader:SetJustifyH("LEFT")

-- column labels, aligned to the data columns below them
local colQty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
colQty:SetPoint("TOPLEFT", listAnchor, "TOPLEFT", 4, 11)
colQty:SetWidth(48)
colQty:SetJustifyH("RIGHT")
colQty:SetText("qty")

local colName = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
colName:SetPoint("LEFT", colQty, "RIGHT", 8, 0)
colName:SetWidth(170)
colName:SetJustifyH("LEFT")
colName:SetText("item")

local colCut = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
colCut:SetPoint("LEFT", colName, "RIGHT", 6, 0)
colCut:SetWidth(INNER - 240)
colCut:SetJustifyH("RIGHT")
colCut:SetText("don't pay over")

local rows = {}
for i = 1, MAX_ROWS do
    local b = CreateFrame("Button", nil, listAnchor)
    b:SetSize(INNER, ROW_H)
    b:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

    b.qty = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.qty:SetPoint("LEFT", 4, 0)
    b.qty:SetWidth(48)
    b.qty:SetJustifyH("RIGHT")           -- digits line up

    b.name = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.name:SetPoint("LEFT", b.qty, "RIGHT", 8, 0)
    b.name:SetWidth(170)
    b.name:SetJustifyH("LEFT")

    -- The actionable part: a quantity cannot be bought directly, a price
    -- cutoff can. This column is the per-item buyout to stop at.
    b.cut = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.cut:SetPoint("LEFT", b.name, "RIGHT", 6, 0)
    b.cut:SetWidth(INNER - 240)
    b.cut:SetJustifyH("RIGHT")

    -- The row is a summary; the tooltip is the precise instruction. Buying
    -- cheapest-first until you have enough overshoots (21% on a real book),
    -- so which stacks to take actually matters.
    b:SetScript("OnEnter", function(self)
        if not self.plan or #self.plan == 0 then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(self.searchFor or "")
        GameTooltip:AddLine(string.format("Buy these %d auctions:", #self.plan),
                            0.8, 0.8, 0.8)
        -- group identical auctions, matching the "Posts" column in the
        -- auction browser: "4 x stack of 10" reads better than four lines
        local grouped, order = {}, {}
        for _, p in ipairs(self.plan) do
            local key = p.qty .. "@" .. p.unit
            if not grouped[key] then
                grouped[key] = { qty = p.qty, unit = p.unit, n = 0 }
                order[#order + 1] = key
            end
            grouped[key].n = grouped[key].n + 1
        end
        -- A RUNNING TOTAL, because the instruction is "work down this list
        -- until you have the number" and doing that arithmetic by hand off a
        -- truncated list is the whole complaint.
        local running, shown = 0, 0
        for _, key in ipairs(order) do
            local gq = grouped[key]
            running = running + gq.qty * gq.n
            shown = shown + 1
            if shown > MAX_TIP_LINES then
                local restGroups, restItems = 0, 0
                for j = shown, #order do
                    local g2 = grouped[order[j]]
                    restGroups = restGroups + 1
                    restItems = restItems + g2.qty * g2.n
                end
                -- name what is missing in ITEMS, not just groups: "28 more
                -- auctions" does not tell you how much is left to buy.
                GameTooltip:AddLine(string.format(
                    "...and %d more auctions (%s items) -- shift-click for the full list",
                    restGroups, comma(restItems)), 0.6, 0.6, 0.6)
                break
            end
            local label = (gq.n > 1)
                and string.format("%d x stack of %s", gq.n, comma(gq.qty))
                or  string.format("stack of %s", comma(gq.qty))
            GameTooltip:AddDoubleLine(
                string.format("%s  |cff707070(%s)|r", label, comma(running)),
                RO.Money(gq.unit) .. " each",
                1, 1, 1, 1, 0.82, 0)
        end
        if shown <= MAX_TIP_LINES then
            GameTooltip:AddLine("shift-click to copy the full list", 0.45, 0.45, 0.45)
        end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)

    b:SetScript("OnClick", function(self)
        if not self.searchFor then return end
        -- Shift-click hands over the WHOLE plan as text. The tooltip has to
        -- fit on screen, so for a long list it is the only way to see every
        -- auction -- and a copy box can be scrolled and read at leisure.
        if IsShiftKeyDown and IsShiftKeyDown() then
            ShowCopy(self.searchFor .. " -- the exact auctions to buy:",
                     UI.PlanText(self))
            return
        end
        -- Only Blizzard's browse pane can be driven this way. TSM and other
        -- replacement UIs hide it, so fall back to a copy box rather than
        -- erroring or silently searching for the wrong thing.
        if BrowseName and AuctionFrame and AuctionFrame:IsShown() then
            if AuctionFrameBrowse and not AuctionFrameBrowse:IsVisible() and AuctionFrameTab1 then
                AuctionFrameTab1:Click()
            end
            BrowseName:SetText(self.searchFor)
            if AuctionFrameBrowse_Search then
                AuctionFrameBrowse_Search()
            elseif QueryAuctionItems then
                QueryAuctionItems(self.searchFor, nil, nil, 0, false, nil, false, false)
            end
        else
            ShowCopy("Your auction UI has no search this addon can drive. " ..
                     "Copy the name and paste it into its search box:", self.searchFor)
        end
    end)
    b:Hide()
    rows[i] = b
end

local overflowLine = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
overflowLine:SetPoint("TOPLEFT", listAnchor, "BOTTOMLEFT", 4, -3)
overflowLine:SetJustifyH("LEFT")

-- ---- buttons -------------------------------------------------------------
local scanBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
scanBtn:SetSize(150, 22)
scanBtn:SetPoint("BOTTOMLEFT", PAD, 16)
scanBtn:SetText("Scan auction house")

RO.Skin.Register("buttons", scanBtn)
local tsmBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
RO.Skin.Register("buttons", tsmBtn)
tsmBtn:SetSize(110, 22)
tsmBtn:SetPoint("BOTTOMRIGHT", -PAD, 16)
tsmBtn:SetText("TSM group")
tsmBtn:Hide()

-- No racial checkbox: UnitRace() already knows. Shown as a fact, not a control.
local racialNote = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
racialNote:SetPoint("LEFT", scanBtn, "RIGHT", 12, 0)
racialNote:SetJustifyH("LEFT")

-- ---- state ---------------------------------------------------------------
local lastScan, lastScanFaction, lastItemIds = nil, nil, nil



local function clearResults()
    verdictLine:SetText("")
    costLine:SetText("")
    detailLine:SetText("")
    listHeader:SetText("")
    overflowLine:SetText("")
    for i = 1, MAX_ROWS do rows[i]:Hide() end
    tsmBtn:Hide()
end

local function fillList(list)
    for i = 1, MAX_ROWS do rows[i]:Hide() end
    if not list or #list == 0 then
        listHeader:SetText("")
        overflowLine:SetText("")
        colQty:SetText(""); colName:SetText(""); colCut:SetText("")
        return
    end
    colQty:SetText("qty"); colName:SetText("item"); colCut:SetText("don't pay over")
    listHeader:SetText("|cffffd100BUY THESE|r   |cff707070hover a line for the exact auctions, " ..
                       "click it to search|r")
    local shown = math.min(#list, MAX_ROWS)
    for i = 1, shown do
        local r = list[i]
        rows[i].qty:SetText("|cff00ff00" .. comma(r.qty) .. "|r")
        -- Stock already in your bags and bank is counted, so say so on the
        -- line: "Dark Iron Scraps  (340 in bags)" explains why the number to
        -- buy is lower than the turn-ins would suggest.
        if r.have and r.have > 0 then
            rows[i].name:SetText(string.format("%s |cff707070(%s on hand)|r",
                r.item, comma(r.have)))
        else
            rows[i].name:SetText(r.item)
        end
        rows[i].cut:SetText((r.cutoff and r.cutoff > 0) and RO.Money(r.cutoff) or "")
        rows[i].searchFor = r.item
        rows[i].plan = r.lots
        rows[i].exact = r.exact
        rows[i].have = r.have
        rows[i].need = r.need
        rows[i]:Show()
    end
    overflowLine:SetText(#list > MAX_ROWS
        and string.format("+ %d more not shown", #list - MAX_ROWS) or "")
end

function UI.Refresh()
    dd:SetText(selectedFaction.name)
    td:SetText("Target: " .. RO.StandingName[selectedTarget])
    racialNote:SetText(Core.IsHuman()
        and "|cff40c040Human Diplomacy +10% applied|r" or "")

    local manual = manualFor(selectedFaction)
    local standingID, into, total
    if manual then
        standingID, into = manual.standing, manual.into
        total = RO.StandingStart[standingID] + into
        sd:SetText(RO.StandingName[standingID])
        intoBox:Show(); intoLabel:Show()
        if not intoBox:HasFocus() then intoBox:SetText(tostring(into)) end
        intoLabel:SetText(string.format("/ %s into it", comma(bandSize(standingID))))
    else
        sd:SetText("My current rep (live)")
        intoBox:Hide(); intoLabel:Hide()
        standingID, into, total = Core.GetStanding(selectedFaction.factionID, selectedFaction.name)
    end
    if not standingID then
        standingLine:SetText("|cffff8080No standing with " .. selectedFaction.name ..
                             " yet -- meet them once, or set \"Start from\" above.|r")
        clearResults()
        return
    end

    local need = Core.RepNeeded(total, selectedTarget)
    standingLine:SetText(string.format(
        "|cffffd100%s|r  %s into it %s    ->     |cffffd100%s|r  needs |cff00ff00%s|r more",
        RO.StandingName[standingID], comma(into), manual and "|cff909090(entered)|r" or "|cff909090(live)|r",
        RO.StandingName[selectedTarget], comma(need)))

    if need <= 0 then
        clearResults()
        verdictLine:SetText("|cff00ff00Already at or past that standing.|r")
        return
    end
    if not lastScan or lastScanFaction ~= selectedFaction.key then
        clearResults()
        verdictLine:SetText("Open the auction house and press |cffffffffScan|r.\n\n" ..
            "The scan reads every individual listing, because the cheapest mix depends on " ..
            "how deep the cheap stock goes -- not just the lowest price.")
        return
    end

    local result, err, sources = Core.Optimize(selectedFaction, lastScan, need)
    if not result then
        clearResults()
        verdictLine:SetText("|cffff8080" .. (err or "no combination found") .. "|r")
        return
    end

    if result.partial and result.capLimited then
        -- our own limit, not the market's -- say so plainly
        verdictLine:SetText(string.format(
            "Planning stopped at |cffffffff%s|r of |cffffffff%s|r to keep the search fast " ..
            "(the listings could go further). Cheapest way to buy this much:",
            comma(result.repAchieved), comma(result.requested)))
    elseif result.partial then
        verdictLine:SetText(string.format(
            "Listings cover |cffffffff%s|r of |cffffffff%s|r -- |cffff8080%s short|r. " ..
            "Cheapest way to buy what is listed:",
            comma(result.repAchieved), comma(result.requested), comma(result.shortfall)))
    else
        verdictLine:SetText("Cheapest way to get there:")
    end
    costLine:SetText("|cffffd100" .. RO.Money(result.cost) .. "|r")

    -- one dim line of detail, not a wall of turn-in names
    local bits = { comma(result.turnins) .. " turn-ins" }
    if not result.partial then
        bits[#bits + 1] = comma(result.repAchieved) .. " rep, " .. comma(result.overage) .. " over"
    end
    if result.tokensMade > 0 then
        local t = comma(result.tokensKept) .. " " .. (selectedFaction.tokenName or "tokens") .. " kept"
        local sink = selectedFaction.tokenSinks and selectedFaction.tokenSinks[1]
        if sink and result.tokensKept >= sink.cost then
            t = t .. " (" .. math.floor(result.tokensKept / sink.cost) .. " x " .. sink.name .. ")"
        end
        bits[#bits + 1] = t
    end
    -- A one-time quest already handed in pays the repeatable's rate, not the
    -- one-time's. Saying which were dropped stops the plan looking wrong.
    if result.questsDone and #result.questsDone > 0 then
        bits[#bits + 1] = string.format("|cffcf8080%d one-time quest%s already done, excluded|r",
            #result.questsDone, #result.questsDone == 1 and "" or "s")
    end
    if result.questUnknown then
        bits[#bits + 1] = "|cffcf8080assumes the one-time quests are undone|r"
    end
    if result.approximate then
        bits[#bits + 1] = "|cffcf8080search stopped early|r"
    end
    detailLine:SetText(table.concat(bits, "   |cff585858|||r   "))

    local list = Core.ShoppingRows(result, sources)
    fillList(list)

    local importString = Core.TSMImportString(list, lastItemIds)
    if importString then
        tsmBtn:Show()
        tsmBtn:SetScript("OnClick", function()
            ShowCopy("Paste into TSM: Groups > Import/Export > Import. Then use Shopping to " ..
                     "search that group -- one search covering the whole list.", importString)
        end)
    else
        tsmBtn:Hide()
    end
end

scanBtn:SetScript("OnClick", function()
    if RO.Scanner.IsRunning() then
        RO.Scanner.Abort()
        scanBtn:SetText("Scan auction house")
        return
    end
    local items = RO.ItemsForFaction(selectedFaction)
    local facKey = selectedFaction.key
    scanBtn:SetText("Cancel scan")
    RO.Scanner.Start(items,
        function(ok, res, itemIds)
            scanBtn:SetText("Scan auction house")
            if ok then
                UI.SetScanResults(res, itemIds, facKey)
            else
                standingLine:SetText("|cffff8080" .. tostring(res) .. "|r")
            end
        end,
        function(i, total, name)
            standingLine:SetText(string.format("Scanning %d/%d -- %s", i, total, name))
        end)
end)

--- Load a completed scan and redraw. Called by the scan callback.
function UI.SetScanResults(scan, itemIds, factionKey)
    lastScan, lastItemIds, lastScanFaction = scan, itemIds, factionKey
    UI.Refresh()
end

function UI.Toggle()
    if f:IsShown() then f:Hide() else f:Show() UI.Refresh() end
end
