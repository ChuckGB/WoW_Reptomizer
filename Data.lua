--[[ Data.lua ------------------------------------------------------------------
Faction definitions. Every reputation number here was checked against the
Classic quest pages on wowhead (quest IDs in the comments) -- NOT against later
guides, most of which quote the patch 2.0.1 values.

Structure of a source:
    name        shown in the shopping list
    repBase     reputation the turn-in always awards
    tokenRep    extra reputation IF you consume the token it hands you (0 = none)
    limit       most times this turn-in can be done (nil = unlimited)
    questID     for a one-time turn-in, the quest to check. If the character has
                already handed it in the source is dropped from the plan -- see
                Core.QuestDone. Without this the addon promises reputation the
                game will not pay.
    components  the items you must buy; a coin set needs one of EACH of three
                different coins, so it has three components
    note        caveat shown in the UI
--------------------------------------------------------------------------- ]]

local RO = _G.RepOptimizer or {}
_G.RepOptimizer = RO

local BIJOUS = {
    "Blue Hakkari Bijou", "Bronze Hakkari Bijou", "Gold Hakkari Bijou",
    "Green Hakkari Bijou", "Orange Hakkari Bijou", "Purple Hakkari Bijou",
    "Red Hakkari Bijou", "Silver Hakkari Bijou", "Yellow Hakkari Bijou",
}

-- The capital-city cloth turn-ins. Every quartermaster offers the identical
-- set, so only the faction and the NPC change.
--
--   A Donation of Wool / Silk / Mageweave / Runecloth   60 cloth, 350 rep, ONCE
--   Additional Runecloth                                20 Runecloth, 75 rep, repeatable
--
-- Additional Runecloth needs level 50 and the one-time Runecloth donation
-- first. Its quest ID differs per faction -- 7801 is Darnassus (verified),
-- 7825 is Thunder Bluff; the others are not yet confirmed, so they are left
-- uncited rather than guessed.
--
-- No standing-based reduction: nothing in the Classic data gives these a cap
-- or a reduced award at higher standing, and the awards run to Exalted. If a
-- realm ever shows otherwise, this is the first place to look.
--
-- Horde (Orgrimmar, Thunder Bluff, Undercity, Darkspear Trolls) is the same
-- table with different factionIDs; not added yet.
local function ClothSources()
    return {
        { name = "A Donation of Wool (one-time)", repBase = 350, tokenRep = 0, limit = 1,
          components = { { items = { "Wool Cloth" }, perTurnin = 60 } },
          note = "60 Wool Cloth. 350 rep, once only." },
        { name = "A Donation of Silk (one-time)", repBase = 350, tokenRep = 0, limit = 1,
          components = { { items = { "Silk Cloth" }, perTurnin = 60 } },
          note = "60 Silk Cloth. 350 rep, once only." },
        { name = "A Donation of Mageweave (one-time)", repBase = 350, tokenRep = 0, limit = 1,
          components = { { items = { "Mageweave Cloth" }, perTurnin = 60 } },
          note = "60 Mageweave Cloth. 350 rep, once only." },
        { name = "A Donation of Runecloth (one-time)", repBase = 350, tokenRep = 0, limit = 1,
          components = { { items = { "Runecloth" }, perTurnin = 60 } },
          note = "60 Runecloth. 350 rep, once only. Unlocks the repeatable." },
        { name = "Additional Runecloth (repeatable)", repBase = 75, tokenRep = 0,
          components = { { items = { "Runecloth" }, perTurnin = 20 } },
          note = "20 Runecloth for 75 rep, repeatable. Needs level 50 and the one-time donation." },
    }
end

RO.Factions = {
    {
        key = "zandalar", name = "Zandalar Tribe", factionID = 270,
        tokenName = "Zandalar Honor Token",
        tokenSinks = { { name = "Zandalar Signet (shoulder enchant)", cost = 15, standing = "Exalted" } },
        sources = {
            {   -- quest: destroy a bijou (spell 24377) = 75 rep + 1 Honor Token
                name = "Bijou", repBase = 75, tokenRep = 50,
                components = { { items = BIJOUS, perTurnin = 1 } },
                note = "Any colour works. 75 rep + an Honor Token worth 50 more.",
            },
            {   -- quest 8195
                name = "Zulian/Razzashi/Hakkari set", repBase = 25, tokenRep = 50,
                components = {
                    { items = { "Zulian Coin" },   perTurnin = 1 },
                    { items = { "Razzashi Coin" }, perTurnin = 1 },
                    { items = { "Hakkari Coin" },  perTurnin = 1 },
                },
                note = "Needs one of each of the three coins.",
            },
            {   -- quest 8238
                name = "Gurubashi/Vilebranch/Witherbark set", repBase = 25, tokenRep = 50,
                components = {
                    { items = { "Gurubashi Coin" },  perTurnin = 1 },
                    { items = { "Vilebranch Coin" }, perTurnin = 1 },
                    { items = { "Witherbark Coin" }, perTurnin = 1 },
                },
                note = "Needs one of each of the three coins.",
            },
            {   -- quest 8239
                name = "Sandfury/Skullsplitter/Bloodscalp set", repBase = 25, tokenRep = 50,
                components = {
                    { items = { "Sandfury Coin" },      perTurnin = 1 },
                    { items = { "Skullsplitter Coin" }, perTurnin = 1 },
                    { items = { "Bloodscalp Coin" },    perTurnin = 1 },
                },
                note = "Needs one of each of the three coins.",
            },
        },
    },
    {
        key = "argentdawn", name = "Argent Dawn", factionID = 529,
        -- The five commission drops are ordinary tradeable trade goods. Each
        -- quest pays 200 rep ONCE (quests 9124/9126/9128/9131/9136); the
        -- repeatable versions (9125/9127/9129/9132/9137) pay 10 rep per 30
        -- items. Scourgestones, Healthy Dragon Scale and the cauldron reagents
        -- are Bind-on-Pickup, so they are not listed here at all.
        sources = {
            -- questID lets Core skip a one-time quest this character has already
            -- handed in. Without it the addon planned 4 x 200 rep that the game
            -- then paid at the repeatable's 10, leaving Chuck ~700 short with
            -- 120 items bought for nothing (29 Oct 2026).
            { name = "Bonescythe Digs (one-time)", repBase = 200, tokenRep = 0, limit = 1,
              questID = 9126,
              components = { { items = { "Bone Fragments" }, perTurnin = 30 } },
              note = "Quest 9126. 200 rep, once only." },
            { name = "Savage Flora (one-time)", repBase = 200, tokenRep = 0, limit = 1,
              questID = 9136,
              components = { { items = { "Savage Frond" }, perTurnin = 30 } },
              note = "Quest 9136. 200 rep, once only." },
            { name = "Cryptstalker Armor (one-time)", repBase = 200, tokenRep = 0, limit = 1,
              questID = 9124,
              components = { { items = { "Crypt Fiend Parts" }, perTurnin = 30 } },
              note = "Quest 9124. 200 rep, once only." },
            { name = "Binding the Dreadnaught (one-time)", repBase = 200, tokenRep = 0, limit = 1,
              questID = 9131,
              components = { { items = { "Dark Iron Scraps" }, perTurnin = 30 } },
              note = "Quest 9131. 200 rep, once only." },
            { name = "The Elemental Equation (one-time)", repBase = 200, tokenRep = 0, limit = 1,
              questID = 9128,
              components = { { items = { "Core of Elements" }, perTurnin = 30 } },
              note = "Quest 9128. 200 rep, once only." },
            -- the repeatables, at their real and dismal value
            { name = "Bone Fragments (repeatable)", repBase = 10, tokenRep = 0,
              components = { { items = { "Bone Fragments" }, perTurnin = 30 } },
              note = "Quest 9127. Only 10 rep per 30 items." },
            { name = "Savage Fronds (repeatable)", repBase = 10, tokenRep = 0,
              components = { { items = { "Savage Frond" }, perTurnin = 30 } },
              note = "Quest 9137. Only 10 rep per 30 items." },
            { name = "Crypt Fiend Parts (repeatable)", repBase = 10, tokenRep = 0,
              components = { { items = { "Crypt Fiend Parts" }, perTurnin = 30 } },
              note = "Quest 9125. Only 10 rep per 30 items." },
            { name = "Dark Iron Scraps (repeatable)", repBase = 10, tokenRep = 0,
              components = { { items = { "Dark Iron Scraps" }, perTurnin = 30 } },
              note = "Quest 9132. Only 10 rep per 30 items." },
            { name = "Core of Elements (repeatable)", repBase = 10, tokenRep = 0,
              components = { { items = { "Core of Elements" }, perTurnin = 30 } },
              note = "Quest 9129. Only 10 rep per 30 items." },
        },
    },
    {
        key = "cenarion", name = "Cenarion Circle", factionID = 609,
        sources = {
            {   -- quest 8319
                name = "Encrypted Twilight Text", repBase = 100, tokenRep = 0,
                components = { { items = { "Encrypted Twilight Text" }, perTurnin = 10 } },
                note = "10 per turn-in. No unlock beyond the starting quest.",
            },
            {   -- quest 8362
                name = "Abyssal Crest", repBase = 50, tokenRep = 0,
                components = { { items = { "Abyssal Crest" }, perTurnin = 3 } },
                note = "Needs the Twilight Trappings set.",
            },
            {   -- quest 8363
                name = "Abyssal Signet", repBase = 100, tokenRep = 0,
                components = { { items = { "Abyssal Signet" }, perTurnin = 3 } },
                note = "Needs Trappings + Medallion of Station.",
            },
            {   -- quest 8364 -- CLASSIC value is 150, not the 350 of TBC
                name = "Abyssal Scepter", repBase = 150, tokenRep = 0,
                components = { { items = { "Abyssal Scepter" }, perTurnin = 3 } },
                note = "Needs Trappings + Medallion + Ring of Lordship, and Revered.",
            },
        },
    },
    {
        key = "thorium", name = "Thorium Brotherhood", factionID = 59,
        sources = {
            { name = "Dark Iron Ore", repBase = 50, tokenRep = 0,             -- quest 6642
              components = { { items = { "Dark Iron Ore" }, perTurnin = 10 } },
              note = "Unlocks at Honored." },
            { name = "Fiery Core", repBase = 200, tokenRep = 0,               -- quest 6643
              components = { { items = { "Fiery Core" }, perTurnin = 1 } },
              note = "Unlocks at Honored." },
            { name = "Lava Core", repBase = 200, tokenRep = 0,                -- quest 6644
              components = { { items = { "Lava Core" }, perTurnin = 1 } },
              note = "Unlocks at Honored." },
            { name = "Core Leather", repBase = 150, tokenRep = 0,             -- quest 6645
              components = { { items = { "Core Leather" }, perTurnin = 2 } },
              note = "Unlocks at Honored." },
            { name = "Blood of the Mountain", repBase = 200, tokenRep = 0,    -- quest 6646
              components = { { items = { "Blood of the Mountain" }, perTurnin = 1 } },
              note = "Unlocks at Honored." },
        },
    },
    -- ---- Alliance capital cities (cloth) --------------------------------
    { key = "stormwind", name = "Stormwind",        factionID = 72, cloth = true,
      sources = ClothSources() },
    { key = "ironforge", name = "Ironforge",        factionID = 47, cloth = true,
      sources = ClothSources() },
    { key = "darnassus", name = "Darnassus",        factionID = 69, cloth = true,
      sources = ClothSources() },
    { key = "gnomeregan", name = "Gnomeregan Exiles", factionID = 54, cloth = true,
      sources = ClothSources() },
}

-- Cumulative reputation at the START of each standing.
RO.StandingStart = {
    [1] = -42000, [2] = -6000, [3] = -3000, [4] = 0,
    [5] = 3000,   [6] = 9000,  [7] = 21000, [8] = 42000,
}
RO.StandingName = {
    [1] = "Hated", [2] = "Hostile", [3] = "Unfriendly", [4] = "Neutral",
    [5] = "Friendly", [6] = "Honored", [7] = "Revered", [8] = "Exalted",
}

--- Every distinct item name a faction needs scanned.
function RO.ItemsForFaction(faction)
    local seen, out = {}, {}
    for _, src in ipairs(faction.sources) do
        for _, comp in ipairs(src.components) do
            for _, item in ipairs(comp.items) do
                if not seen[item] then
                    seen[item] = true
                    out[#out + 1] = item
                end
            end
        end
    end
    return out
end
