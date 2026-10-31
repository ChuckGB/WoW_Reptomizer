--[[ Init.lua — saved variables, slash command, auction-house hook. ]]
local RO = _G.RepOptimizer

local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("PLAYER_LOGIN")
boot:RegisterEvent("AUCTION_HOUSE_SHOW")
boot:RegisterEvent("AUCTION_HOUSE_CLOSED")
boot:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == "RepOptimizer" then
        RepOptimizerDB = RepOptimizerDB or { autoShow = false }
        RepOptimizerDB.human = nil          -- the racial is detected, not stored
        print("|cff33ff99RepOptimizer|r loaded. Type |cffffffff/rep|r at the auction house.")
    elseif event == "PLAYER_LOGIN" then
        RO.Skin.Apply()                     -- ElvUI on Era, EllesmereUI on Forever
    elseif event == "AUCTION_HOUSE_SHOW" then
        -- Track the auction house by EVENT, not by whether Blizzard's frame is
        -- visible: TSM and other replacement UIs hide it, which used to make the
        -- addon think the auction house was shut.
        RO.Scanner.NotifyAuctionHouseOpen(true)
        if RepOptimizerDB and RepOptimizerDB.autoShow and not RO.Frame:IsShown() then
            RO.UI.Toggle()
        end
    elseif event == "AUCTION_HOUSE_CLOSED" then
        RO.Scanner.NotifyAuctionHouseOpen(false)
    end
end)

SLASH_REPOPTIMIZER1 = "/rep"
SLASH_REPOPTIMIZER2 = "/repoptimizer"
SlashCmdList["REPOPTIMIZER"] = function(msg)
    msg = (msg or ""):lower()
    if msg == "auto" then
        RepOptimizerDB.autoShow = not RepOptimizerDB.autoShow
        print("|cff33ff99RepOptimizer|r auto-open at the auction house: " ..
              (RepOptimizerDB.autoShow and "on" or "off"))
    else
        RO.UI.Toggle()
    end
end
