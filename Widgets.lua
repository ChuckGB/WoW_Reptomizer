--[[ Widgets.lua ---------------------------------------------------------------
A small dropdown: a button that opens a list. Used instead of Blizzard's
UIDropDownMenu, which runs its builder at file load and does not survive ElvUI
skinning (both found the hard way in ShuffleOptimizer). A plain button plus a
plain panel skins cleanly under ElvUI and EllesmereUI.
--------------------------------------------------------------------------- ]]
local RO = _G.RepOptimizer
local Widgets = {}
RO.Widgets = Widgets

local ROW = 18

local menu = CreateFrame("Frame", "RepOptimizerMenu", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
menu:SetFrameStrata("FULLSCREEN_DIALOG")
menu:SetClampedToScreen(true)
menu:EnableMouse(true)
menu:Hide()
if menu.SetBackdrop then
    menu:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                       edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                       tile = true, tileSize = 16, edgeSize = 14,
                       insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    menu:SetBackdropColor(0.06, 0.06, 0.06, 0.95)
end
tinsert(UISpecialFrames, "RepOptimizerMenu")
RO.Skin.Register("panels", menu)
menu.items = {}
Widgets.menu = menu

local function item(i)
    local b = menu.items[i]
    if b then return b end
    b = CreateFrame("Button", nil, menu)
    b:SetHeight(ROW)
    b:SetPoint("TOPLEFT", 6, -6 - (i - 1) * ROW)
    b:SetPoint("RIGHT", -6, 0)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetPoint("LEFT", 6, 0)
    b.text:SetPoint("RIGHT", -6, 0)
    b.text:SetJustifyH("LEFT")
    b:SetScript("OnClick", function(self)
        menu:Hide()
        if self.onClick then self.onClick() end
    end)
    menu.items[i] = b
    return b
end

menu:SetScript("OnUpdate", function(self, elapsed)
    if MouseIsOver(self) or (self.owner and MouseIsOver(self.owner)) then
        self.away = 0
    else
        self.away = (self.away or 0) + elapsed
        if self.away > 1.5 then self:Hide() end
    end
end)

--- items: array of { text, selected, onClick }
function Widgets.OpenMenu(owner, items)
    if menu:IsShown() and menu.owner == owner then menu:Hide(); return end
    menu.owner, menu.away = owner, 0
    for i, it in ipairs(items) do
        local b = item(i)
        b.text:SetText(it.selected and ("|cff00ff00" .. it.text .. "|r") or it.text)
        b.onClick = it.onClick
        b:Show()
    end
    for i = #items + 1, #menu.items do menu.items[i]:Hide() end
    menu:SetSize(math.max(owner:GetWidth(), 150), #items * ROW + 12)
    menu:ClearAllPoints()
    menu:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -2)
    menu:Show()
end

--- A dropdown button. buildItems() is called on every open, never at load.
function Widgets.Dropdown(parent, name, width, buildItems)
    local b = CreateFrame("Button", name, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    local fs = b:GetFontString()
    if fs then
        fs:ClearAllPoints()
        fs:SetPoint("LEFT", 8, 0)
        fs:SetPoint("RIGHT", -20, 0)
        fs:SetJustifyH("LEFT")
    end
    b.arrow = b:CreateTexture(nil, "OVERLAY")
    b.arrow:SetSize(14, 14)
    b.arrow:SetPoint("RIGHT", -5, 0)
    b.arrow:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
    b:SetScript("OnClick", function(self) Widgets.OpenMenu(self, buildItems()) end)
    RO.Skin.Register("buttons", b)
    return b
end
