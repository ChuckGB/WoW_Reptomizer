--[[ Scanner.lua ---------------------------------------------------------------
Targeted auction house scanning for Classic Era.

Auctionator cannot help here: its saved database keeps only a minimum price and
a total quantity per item per day (see Auctionator's Source/Database/Mixin.lua,
where ProcessScan sums every listing into one number). We need the individual
listings -- how many at what price -- so we scan for ourselves.

We never use getAll. A faction needs at most ~18 exact-name searches, which at
the ~0.3s query throttle is a few seconds at the mailbox.
--------------------------------------------------------------------------- ]]

local RO = _G.RepOptimizer
local Scanner = {}
RO.Scanner = Scanner

local QUERY_INTERVAL = 0.5      -- seconds between queries; throttle is ~0.3
local PAGE_SIZE = 50

local frame = CreateFrame("Frame")
local state = nil

-- Whether the auction house is OPEN, which is not the same as the Blizzard
-- auction frame being visible: TSM and other replacement UIs hide it entirely.
-- Driven by AUCTION_HOUSE_SHOW / AUCTION_HOUSE_CLOSED.
local ahOpen = false

local function finish(ok, err)
    local cb = state and state.callback
    local results = state and state.results
    local itemIds = state and state.itemIds
    state = nil
    frame:UnregisterEvent("AUCTION_ITEM_LIST_UPDATE")
    -- NB: do NOT clear the OnUpdate script here. It is the pump that drives every
    -- scan; removing it means the FIRST scan works and every one after it hangs
    -- with no error. It costs nothing to leave installed -- it returns
    -- immediately while `state` is nil.
    if cb then cb(ok, ok and results or err, itemIds) end
end

--- Pull one page of results into the lot list.
local function harvest()
    local numOnPage, total = GetNumAuctionItems("list")
    local wanted = state.items[state.index]
    local bucket = state.results[wanted]
    for i = 1, numOnPage do
        local name, _, count, _, _, _, _, _, _, buyout = GetAuctionItemInfo("list", i)
        -- exactMatch is not always honoured, so filter by name ourselves
        if name == wanted and buyout and buyout > 0 and count and count > 0 then
            bucket[#bucket + 1] = { qty = count, price = buyout }
            -- remember the itemID so we can build a TSM group import string later
            if not state.itemIds[name] and GetAuctionItemLink then
                local link = GetAuctionItemLink("list", i)
                local id = link and tonumber(link:match("item:(%d+)"))
                if id then state.itemIds[name] = id end
            end
        end
    end
    return numOnPage, total
end

local function queryCurrent()
    local name = state.items[state.index]
    state.results[name] = state.results[name] or {}
    if not CanSendAuctionQuery() then
        state.retry = (state.retry or 0) + 1
        if state.retry > 40 then finish(false, "the auction house kept throttling the scan") end
        return false
    end
    state.retry = 0
    -- text, minLevel, maxLevel, page, usable, rarity, getAll, exactMatch
    QueryAuctionItems(name, nil, nil, state.page, false, nil, false, true)
    state.awaiting = true
    return true
end

local function advance()
    state.page = 0
    state.index = state.index + 1
    if state.index > #state.items then
        finish(true)
        return
    end
    if state.progress then
        state.progress(state.index, #state.items, state.items[state.index])
    end
end

frame:SetScript("OnEvent", function(_, event)
    if event ~= "AUCTION_ITEM_LIST_UPDATE" or not state or not state.awaiting then return end
    state.awaiting = false
    local numOnPage, total = harvest()
    if numOnPage >= PAGE_SIZE and (state.page + 1) * PAGE_SIZE < total then
        state.page = state.page + 1          -- more pages of this item
    else
        advance()                            -- may complete the scan and clear state
    end
    -- advance() can finish the whole scan, in which case there is no state left
    if state then state.nextQueryAt = GetTime() + QUERY_INTERVAL end
end)

frame:SetScript("OnUpdate", function()
    if not state then return end
    if not ahOpen then finish(false, "the auction house closed before the scan finished") return end
    if state.awaiting then return end
    if GetTime() < (state.nextQueryAt or 0) then return end
    if state.index > #state.items then finish(true) return end
    if not queryCurrent() then
        state.nextQueryAt = GetTime() + QUERY_INTERVAL
    end
end)

--- Scan a list of exact item names.
-- @param items array of item names
-- @param callback function(ok, resultsOrError, itemIds)
--        results[itemName] = { {qty=,price=}, ... };  itemIds[itemName] = <number>
-- @param progress optional function(index, total, itemName)
function Scanner.Start(items, callback, progress)
    if state then
        callback(false, "a scan is already running")
        return
    end
    if not ahOpen then
        callback(false, "open the auction house first")
        return
    end
    -- The classic auction house calls. A client without them (e.g. a modern
    -- auction house) gets a plain message instead of a Lua error.
    if not QueryAuctionItems or not GetAuctionItemInfo then
        callback(false, "this client's auction house can't be scanned by RepOptimizer yet")
        return
    end
    state = {
        items = items, index = 1, page = 0,
        results = {}, itemIds = {}, callback = callback, progress = progress,
        nextQueryAt = 0, awaiting = false,
    }
    frame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
    if progress then progress(1, #items, items[1]) end
end

function Scanner.IsRunning() return state ~= nil end

--- Called from Init.lua on AUCTION_HOUSE_SHOW / AUCTION_HOUSE_CLOSED.
function Scanner.NotifyAuctionHouseOpen(isOpen)
    ahOpen = isOpen and true or false
    if not ahOpen and state then
        finish(false, "the auction house closed before the scan finished")
    end
end

function Scanner.IsAuctionHouseOpen() return ahOpen end

function Scanner.Abort()
    if state then finish(false, "scan cancelled") end
end
