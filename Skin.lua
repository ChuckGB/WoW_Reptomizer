--[[ Skin.lua ------------------------------------------------------------------
Make the window look like the rest of the UI. The UI builds its frames from
plain Blizzard templates and registers them here; we hand them to whichever UI
suite is running:

  EllesmereUI  (Forever / Retail)  its public skinning API, EllesmereUI.RegisterSkin
  ElvUI        (every version)     its Skins module, S:HandleFrame / HandleButton / ...
  neither                          left as Blizzard's look

Only one is applied. Ellesmere wins if both are loaded, because a player
running it has chosen it as their look. Every call is pcall-wrapped: a skin
failing must never stop the addon from working.
--------------------------------------------------------------------------- ]]
local RO = _G.RepOptimizer
local Skin = {}
RO.Skin = Skin

-- filled by UI.lua
Skin.widgets = { frames = {}, buttons = {}, checks = {}, dropdowns = {}, editboxes = {}, scrollbars = {}, closes = {}, panels = {} }

function Skin.Register(kind, obj, extra)
    local list = Skin.widgets[kind]
    list[#list + 1] = { obj = obj, extra = extra }
end

local function each(kind, fn)
    for _, w in ipairs(Skin.widgets[kind]) do
        if w.obj then pcall(fn, w.obj, w.extra) end
    end
end

local function applyEllesmere(S)
    each("frames", function(f) S.Shell(f) end)
    each("panels", function(f) S.Panel(f, { inset = true }) end)
    each("closes", function(b) S.CloseButton(b) end)
    each("buttons", function(b) S.Button(b) end)
    each("checks", function(c) S.Checkbox(c) end)
    each("dropdowns", function(d) S.Dropdown(d) end)
    each("editboxes", function(e) S.EditBox(e) end)
    each("scrollbars", function(s) S.ScrollBar(s) end)
    Skin.active = "EllesmereUI"
end

local function applyElvUI()
    local E = unpack(ElvUI)
    local S = E and E:GetModule("Skins", true)
    if not S then return false end
    each("frames", function(f) S:HandleFrame(f, true) end)
    each("panels", function(f) f:SetTemplate("Transparent") end)
    each("closes", function(b) S:HandleCloseButton(b) end)
    each("buttons", function(b) S:HandleButton(b) end)
    each("checks", function(c) S:HandleCheckBox(c) end)
    each("dropdowns", function(d, width) S:HandleDropDownBox(d, width) end)
    each("editboxes", function(e) S:HandleEditBox(e) end)
    each("scrollbars", function(s) S:HandleScrollBar(s) end)
    Skin.active = "ElvUI"
    return true
end

--- Called once at PLAYER_LOGIN, after the UI has registered its widgets.
function Skin.Apply()
    if EllesmereUI and EllesmereUI.RegisterSkin then
        -- Runs now (we are past login) or not at all if the player turned
        -- third-party skinning off for us in EllesmereUI's options.
        -- If EllesmereUI's own login handler has not run yet, the callback
        -- comes a moment later; either way ElvUI must not paint over it.
        EllesmereUI.RegisterSkin("RepOptimizer", applyEllesmere)
        Skin.active = Skin.active or "EllesmereUI"
        return
    end
    if ElvUI then
        local ok = pcall(applyElvUI)
        if ok and Skin.active then return end
    end
    Skin.active = "Blizzard"
end
