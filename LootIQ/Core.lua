local ADDON_NAME, ns = ...

-- Settings canvas panels (Options.lua, OptionsLists.lua, BrowserPanel.lua)
-- that build their row content lazily append their refresh function here.
-- A panel frame's Shown flag already defaults to true at creation, so the
-- Settings UI's first-ever :Show() of it is a no-op that never fires
-- OnShow - only a later revisit (a genuine Hide->Show transition from
-- switching away and back) does. Calling every registered refresher once
-- here, right when ns.db/ns.accountDB actually become valid, guarantees
-- correct content on the very first view instead of depending on that.
ns.OptionsRefreshers = {}

-- Every registered category/subcategory appends {name, id, icon} here as
-- it registers, so the loot bar's tab strip (see Bar.lua) can jump
-- straight to any of them without knowing about each panel file. Only
-- read after every file has loaded (from ns.InitBar, called from
-- ADDON_LOADED) - Bar.lua itself loads before some panel files that
-- populate this (e.g. AuctionScan.lua), so building the tabs any earlier
-- would miss entries.
ns.SettingsPanels = {}

-- Per-character: loot bar state and personal settings. Nothing here is
-- useful shared across characters, so it lives in LootIQCharDB.
ns.DB_DEFAULTS = {
    -- Anchored by its top-left corner (where the drag handle is) so the
    -- bar only ever grows right/down as items or rows are added, never
    -- shifting the handle's position.
    barPosition = { point = "TOPLEFT", relPoint = "TOPLEFT", x = 100, y = -250 },
    barShown = true,
    minimized = false, -- when true, the bar collapses to a single Bolt of Runecloth icon
    session = {},       -- [itemID] = { count, icon, link }
    sessionOrder = {},  -- itemIDs in the order they were first looted
    excludedItems = {}, -- [itemID] = true for banned items; never auto-added to the bar
    whitelist = {},     -- [itemID] = true for items always auto-added regardless of the quality filter
    alwaysVendor = {},  -- [itemID] = true for items automatically sold whenever a vendor window is open
    autoVendorEnabled = true, -- master toggle for selling the Always Vendor List at vendors
    autoLearnVendorEnabled = false, -- whether manually selling an item to a vendor also adds it to the Always Vendor List
    autoLearnVendorMaxQuality = 1, -- highest quality (0=Poor..5=Legendary) auto-added this way; a "ceiling", not a floor
    autoAddLoot = true, -- whether looted items are automatically added to the loot bar at all
    minQuality = 0,     -- lowest item quality (0=Poor..5=Legendary) shown on the loot bar
    showCopper = true,  -- whether the loot bar's price totals include the copper component
    showJunk = true,    -- whether the vendor-junk tally entry is shown on the loot bar
    showItemPrices = true, -- whether gold values are shown below each item on the loot bar
    gridColumns = 8,    -- number of icon columns before the loot bar wraps to a new row
    gridIconWidth = 28, -- pixel width of each icon slot on the loot bar
    gridIconHeight = 28, -- pixel height of each icon slot on the loot bar
    debugMessages = true, -- whether automatic loot-attribution debug messages print to chat
    quietAuctionScan = false, -- whether an AH scan's start/progress/complete/interrupted messages are suppressed
}

-- Account-wide: what a creature drops and what the auction house is
-- charging are true regardless of which character learned them, so these
-- stay shared in LootIQDB instead of being relearned per character.
ns.ACCOUNT_DB_DEFAULTS = {
    -- [creatureID] = { kills = n, drops/skins = { [itemID] = { count, occurrences, link } },
    -- sells = { [itemID] = { link, price } } }. A vendor is stored the same
    -- way (same creatureID identity) - just a `sells` catalog (a snapshot
    -- of its window, not an occurrence count - see Loot.lua's
    -- RecordVendorSells) instead of kills/drops. See also
    -- CreatureDatabase.lua (the "Source Database" panel).
    creatures = {},
    -- Lowest per-unit price seen during the player's most recent completed
    -- scan (overwritten wholesale each scan by AuctionScan.lua's
    -- FinishScan, not accumulated across scans - an old low from weeks ago
    -- shouldn't outlive the market moving on) - used for pricing elsewhere
    -- in the addon (loot bar, creature average value), though
    -- ns.GetItemPrice actually prefers Auctionator's live estimate over
    -- this when Auctionator is installed, falling back to this only when
    -- it isn't. See baseline below for a running average instead.
    ahPrices = {},  -- [itemID] = { price = copper (per unit), scanTime = time() } from our own AH scans
    -- [itemID] = { link, sources = { [creatureID] = true },
    -- fishingSources/miningSources/herbalismSources/craftingSources =
    -- { [key] = true } } - reverse index of creatures.drops/skins/sells
    -- plus each gathering/crafting activity's own data (see Loot.lua's
    -- GATHERING_CATEGORIES; key is a zone name for the first three,
    -- a profession name for crafting).
    items = {},
    -- A general running reference for "what does this item usually sell
    -- for", built from every completed AH scan (see AuctionScan.lua) -
    -- distinct from ahPrices' floor. average = total/scans.
    baseline = {},  -- [itemID] = { total = cumulative copper sum of per-scan lowest unit price, scans = n }
    -- Items whose most recent scan price came in below their baseline
    -- average at the time - speculative, not a guaranteed deal (a young
    -- baseline or a market that's just moved can produce a false one).
    -- Replaced wholesale each scan; see FlipIt.lua.
    flipOpportunities = {}, -- [itemID] = { link, price, average, scans, scanTime }
    -- [zoneName] = { fish = { [itemID] = { count, occurrences, link } } },
    -- keyed by GetZoneText() since a fishing catch has no creature/GUID
    -- source to attribute to - see Fishing.lua. Total catches for a zone is
    -- tallied on demand from fish's occurrences (ns.GetTotalFishingCatches),
    -- not stored as its own field.
    fishing = {},
    -- Same shape/reasoning as fishing above, for the other two gathering
    -- professions - see Mining.lua/Herbalism.lua. Store field is "ore"/
    -- "herbs" instead of "fish"; totals are ns.GetTotalMiningHarvests/
    -- ns.GetTotalHerbalismHarvests.
    mining = {},
    herbalism = {},
    -- [professionName] = { items = { [itemID] = { count, occurrences, link } } },
    -- keyed by GetTradeSkillLine() instead of a zone - see Crafting.lua.
    -- Smelting (a Mining sub-skill) is folded into `mining` above instead
    -- of getting its own "Mining" entry here - see ns.RecordSmelting.
    crafting = {},
    -- [objectID] = { name, opens = n, items = { [itemID] = { count,
    -- occurrences, link } } } - chests, crates, and other lootable
    -- containers (GameObjects, not Creatures - see Loot.lua's
    -- OnLootOpened/Chests.lua). objectID is the container's template ID
    -- (shared by every spawned instance of that same container type, e.g.
    -- every "Locked Chest" in the world - exactly like creatureID
    -- identifies a type of creature, not one specific spawn), so this uses
    -- the same ID-keyed, name-backfilled identity model as `creatures`
    -- above rather than the zone/profession string-keyed model the
    -- gathering trio and crafting use. `opens` is a real independent
    -- counter (like a creature's `kills`) - a single opening can drop 0, 1,
    -- or several items, so it can't be derived from summing the item list.
    chests = {},
}

-- A random-suffix item ("Ogre Slaying Bracers of the Monkey" vs. "...of the
-- Whale") shares one base itemID across every possible roll - Blizzard's
-- random-enchant system distinguishes the actual roll via a separate
-- suffixID baked into the item link, the 7th colon-delimited field for this
-- client's (Classic Era / "legacy AH") link format - confirmed against
-- Auctionator's own DBKeyFromLink.lua, which parses it identically
-- (`item:.-:.-:.-:.-:.-:.-:(.-):`) for its own per-suffix price-database
-- keys. 0 (or unparseable) means no random suffix at all, in which case
-- this returns the bare itemID unchanged - the overwhelming majority of
-- items, and exactly the key already used for them before this existed, so
-- no migration is needed for anything that was never suffixed.
--
-- This is the identity key for anything that should track "of the Monkey"
-- and "of the Whale" as separate entries (a creature's drops/skins,
-- gathering catches, crafted items, chest contents, the Item Database)
-- instead of merging every roll under one entry that gets stuck showing
-- whichever suffix happened to be recorded first. Deliberately NOT used for
-- the loot bar (GetItemCount already sums every suffix variant together for
-- a bag count, which is what you want there), a vendor's sells catalog
-- (fixed catalog items don't roll random suffixes), or AH/baseline pricing
-- (already an approximation, out of scope here).
function ns.GetItemKey(link)
    local itemID = link and tonumber(link:match("item:(%d+)"))
    if not itemID then return nil end
    local suffix = tonumber(link:match("item:.-:.-:.-:.-:.-:.-:(.-):"))
    if suffix and suffix ~= 0 then
        return itemID .. ":" .. suffix
    end
    return itemID
end

-- The base itemID behind an ns.GetItemKey result - a plain number already,
-- or a "itemID:suffix" string - for anything that needs the real itemID
-- regardless of which suffix variant this key represents (e.g. checking
-- whether it's a skinning material). Passing a plain itemID through
-- unchanged means callers can use this even when they aren't sure which
-- shape they have.
function ns.GetBaseItemID(key)
    if type(key) == "number" then return key end
    return tonumber(tostring(key):match("^(%-?%d+)"))
end

-- Used for the automatic per-loot diagnostic messages (loot attribution
-- success/failure); does nothing when the option is off. Commands the user
-- explicitly runs (like /lootiq debug) always print, regardless of this.
function ns.DebugPrint(fmt, ...)
    if ns.db and ns.db.debugMessages then
        print(("|cff33ff99LootIQ|r: " .. fmt):format(...))
    end
end

-- Per-unit price in copper, preferring Auctionator's data (the same source
-- it shows on a bag/bank item's own tooltip, kept current automatically as
-- the player browses the AH) over our own scanned data (see
-- AuctionScan.lua, only ever as fresh as the player's last manual
-- /lootiq scan) - this keeps every price LootIQ shows (loot bar, Source/Item
-- Database) consistent with what hovering the item itself shows. Falls back
-- to our own scan when Auctionator isn't installed or has no data for this
-- item, or nil if neither has one.
function ns.GetItemPrice(link)
    if Auctionator and Auctionator.API and Auctionator.API.v1 then
        local ok, price = pcall(Auctionator.API.v1.GetAuctionPriceByItemLink, ADDON_NAME, link)
        if ok and price and price > 0 then
            return price
        end
    end

    local itemID = tonumber(link:match("item:(%d+)"))
    local scanned = itemID and ns.accountDB.ahPrices[itemID]
    if scanned then
        return scanned.price
    end
    return nil
end

-- Formats a copper amount, dropping the copper component when the
-- "include copper" option is turned off. That option is specifically about
-- the loot bar's price display, though - pass fullPrecision=true to always
-- show exact copper regardless (e.g. a vendor's actual sale price, which
-- isn't the loot bar and shouldn't be rounded off by an unrelated setting).
function ns.FormatPrice(copper, fullPrecision)
    if not fullPrecision and not ns.db.showCopper then
        copper = copper - (copper % 100)
    end
    return GetCoinTextureString(copper)
end

-- The generic price any vendor pays when the PLAYER sells this item to them
-- (GetItemInfo's sellPrice return) - every sellable item has this, distinct
-- from a specific vendor's own price to sell the item TO the player (that
-- one's only recorded for an actual selling vendor - see
-- ns.RecordVendorSells/entry.sells). Nil for anything unsellable (e.g. most
-- quest items).
function ns.GetVendorSellPrice(link)
    local _, _, _, _, _, _, _, _, _, _, sellPrice = GetItemInfo(link)
    return sellPrice and sellPrice > 0 and sellPrice or nil
end

-- "Sell: Xs Yc   AH: Zs Wc" for any item row - the generic vendor sell-back
-- price alongside the current AH price, both at full copper precision (same
-- reasoning as FormatPrice's fullPrecision param). Either side falls back to
-- "no data" when it isn't known (no sell price, or ns.GetItemPrice has
-- neither our own scan nor an Auctionator estimate).
function ns.FormatSellAndAHPrice(link)
    local sellPrice = ns.GetVendorSellPrice(link)
    local ahPrice = ns.GetItemPrice(link)
    local sellText = sellPrice and ns.FormatPrice(sellPrice, true) or "no data"
    local ahText = ahPrice and ns.FormatPrice(ahPrice, true) or "no data"
    return ("Sell: %s   AH: %s"):format(sellText, ahText)
end

-- Same as above plus a specific selling vendor's own price to buy the item
-- FROM them - for a row that IS that vendor's catalog entry (BrowserPanel's
-- AddVendorSells, or a vendor source in ItemDatabase's Sources: list), where
-- all three numbers are meaningful side by side.
function ns.FormatSellVendorAndAHPrice(vendorPrice, link)
    local sellPrice = ns.GetVendorSellPrice(link)
    local ahPrice = ns.GetItemPrice(link)
    local sellText = sellPrice and ns.FormatPrice(sellPrice, true) or "no data"
    local ahText = ahPrice and ns.FormatPrice(ahPrice, true) or "no data"
    return ("Sell: %s   Vendor: %s   AH: %s"):format(sellText, ns.FormatPrice(vendorPrice, true), ahText)
end

-- Fills in fields added after a player's saved data already exists, so
-- older entries (from before kill/occurrence tracking) don't read as nil.
local function MigrateCreatureData(creatures)
    for _, entry in pairs(creatures) do
        entry.kills = entry.kills or 0
        entry.skins = entry.skins or {}
        entry.money = entry.money or 0
        for _, drop in pairs(entry.drops or {}) do
            drop.occurrences = drop.occurrences or drop.count or 1
        end
        for _, skin in pairs(entry.skins) do
            skin.occurrences = skin.occurrences or skin.count or 1
        end
    end
end

local function MergeDefaults(dbTable, defaults)
    for key, value in pairs(defaults) do
        if dbTable[key] == nil then
            dbTable[key] = (type(value) == "table") and CopyTable(value) or value
        end
    end
end

-- One-time backfill for the item->sources reverse index (added after
-- creatures/drops was already accumulating data): rebuilds it from the
-- existing per-creature drops/skins so it's populated immediately instead
-- of only from here on as items are looted again.
local function BackfillItemSources(db)
    if db.itemSourcesBackfilled then return end

    for creatureID, entry in pairs(db.creatures) do
        for _, store in ipairs({ entry.drops, entry.skins }) do
            for itemID, data in pairs(store or {}) do
                local item = db.items[itemID]
                if not item then
                    item = { link = data.link, sources = {}, fishingSources = {}, miningSources = {}, herbalismSources = {}, craftingSources = {} }
                    db.items[itemID] = item
                end
                item.link = data.link
                item.sources[creatureID] = true
            end
        end
    end

    db.itemSourcesBackfilled = true
end

-- Looks up a creature's display name from Questie's bundled NPC database,
-- if Questie is installed and enabled - the only source of a name for a
-- creature whose kill/loot events never carried one (e.g. recorded before
-- this addon started capturing names at all, or only ever seen via the
-- chat-loot fallback with no target name cached). Returns nil if Questie
-- isn't present, hasn't finished its own (coroutine-based, multi-second)
-- startup yet - Questie.started only flips true once QuestieDB's
-- compiled-database query handles actually exist, not merely once its
-- files have loaded - or doesn't know this creatureID. Defensive pcalls
-- since this reaches into another addon's module system rather than a
-- stable Blizzard API.
function ns.LookupCreatureName(creatureID)
    if not (QuestieLoader and Questie and Questie.started) then return nil end
    local ok, QuestieDB = pcall(QuestieLoader.ImportModule, QuestieLoader, "QuestieDB")
    if not ok or not QuestieDB or not QuestieDB.QueryNPC then return nil end
    local ok2, npc = pcall(QuestieDB.GetNPC, QuestieDB, creatureID)
    if not ok2 or not npc then return nil end
    return npc.name
end

-- Same idea as ns.LookupCreatureName above, but for a lootable container
-- (chest/crate GameObject - see Chests.lua) via Questie's bundled object
-- database instead of its NPC one - there's no Blizzard API that gives a
-- GameObject's name from its template ID the way UnitName does for a
-- targetable unit.
function ns.LookupObjectName(objectID)
    if not (QuestieLoader and Questie and Questie.started) then return nil end
    local ok, QuestieDB = pcall(QuestieLoader.ImportModule, QuestieLoader, "QuestieDB")
    if not ok or not QuestieDB or not QuestieDB.GetObject then return nil end
    local ok2, obj = pcall(QuestieDB.GetObject, QuestieDB, objectID)
    if not ok2 or not obj then return nil end
    return obj.name
end

-- Backfills missing creature and chest/container names via
-- ns.LookupCreatureName/ns.LookupObjectName. Not gated behind an "already
-- ran" flag like the migrations above - it only touches entries missing a
-- name, so it's cheap and safe to recheck every login (e.g. in case Questie
-- gets installed later).
local function BackfillCreatureNamesFromQuestie(db)
    local resolved = 0
    for creatureID, entry in pairs(db.creatures) do
        if not entry.name then
            local name = ns.LookupCreatureName(creatureID)
            if name then
                entry.name = name
                resolved = resolved + 1
            end
        end
    end
    for objectID, entry in pairs(db.chests) do
        if not entry.name then
            local name = ns.LookupObjectName(objectID)
            if name then
                entry.name = name
                resolved = resolved + 1
            end
        end
    end
    if resolved > 0 then
        print(("|cff33ff99LootIQ|r: resolved %d creature/container name(s) via Questie."):format(resolved))
    end
    return resolved
end

-- Our own ADDON_LOADED fires long before Questie.started does (Questie
-- compiles/loads its database across several coroutine-yielded frames), so
-- a single backfill attempt right away would always find Questie not
-- ready. Poll instead: retry every 2s until Questie finishes starting (or
-- give up after a minute, or immediately if Questie isn't installed at
-- all - QuestieLoader existing but Questie.started never arriving would
-- otherwise poll forever).
local function BackfillCreatureNamesWhenQuestieReady(db, attemptsLeft)
    if not QuestieLoader then return end
    if Questie and Questie.started then
        BackfillCreatureNamesFromQuestie(db)
        return
    end

    attemptsLeft = attemptsLeft or 30
    if attemptsLeft <= 0 then return end
    C_Timer.After(2, function()
        BackfillCreatureNamesWhenQuestieReady(db, attemptsLeft - 1)
    end)
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, addonName)
    if addonName ~= ADDON_NAME then return end

    if type(LootIQCharDB) ~= "table" then
        LootIQCharDB = {}
    end
    MergeDefaults(LootIQCharDB, ns.DB_DEFAULTS)
    -- Older saves anchored the bar by its center; re-home it to the
    -- top-left default so growth stays right/down instead of jumping.
    if LootIQCharDB.barPosition.point ~= "TOPLEFT" then
        LootIQCharDB.barPosition = CopyTable(ns.DB_DEFAULTS.barPosition)
    end
    ns.db = LootIQCharDB

    if type(LootIQDB) ~= "table" then
        LootIQDB = {}
    end
    MergeDefaults(LootIQDB, ns.ACCOUNT_DB_DEFAULTS)
    -- A since-fixed bug attributed drops to a GUID that was unique per
    -- kill instead of per creature, filling the database with bogus
    -- one-off "creature" entries. Clear it once so real data can build up.
    if not LootIQDB.creatureDataFixed then
        wipe(LootIQDB.creatures)
        LootIQDB.creatureDataFixed = true
    end
    MigrateCreatureData(LootIQDB.creatures)
    BackfillItemSources(LootIQDB)
    BackfillCreatureNamesWhenQuestieReady(LootIQDB)
    ns.accountDB = LootIQDB

    if ns.InitBar then
        ns.InitBar()
    end
    if ns.InitOptions then
        ns.InitOptions()
    end
    for _, refresh in ipairs(ns.OptionsRefreshers) do
        refresh()
    end

    self:UnregisterEvent("ADDON_LOADED")
end)

-- Wipes the creature drop/skinning database (and its item->sources reverse
-- index) only, leaving the loot bar, banned/whitelist, and AH price data
-- untouched.
function ns.ClearCreatureData()
    wipe(ns.accountDB.creatures)
    wipe(ns.accountDB.items)
end

SLASH_LOOTIQ1 = "/lootiq"
SlashCmdList["LOOTIQ"] = function(rawMsg)
    -- Keep the original casing around for itemcheck, since shift-clicked
    -- item links are case-sensitive (|Hitem: etc.) and would break if
    -- lowercased along with the rest of the command.
    local raw = strtrim(rawMsg or "")
    local msg = raw:lower()
    if msg:match("^itemcheck") then
        local link = raw:match("(|c%x+|Hitem:.-|h.-|h|r)")
        local itemID = link and tonumber(link:match("item:(%d+)"))
        if not itemID then
            print("|cff33ff99LootIQ|r: usage: /lootiq itemcheck <shift-click an item into the chat box after typing this>")
            return
        end
        local name, _, quality, _, _, itemType, itemSubType, _, _, _, sellPrice, classID, subclassID = GetItemInfo(itemID)
        print(("|cff33ff99LootIQ|r: %s (id %d) - type=%s subType=%s classID=%s subclassID=%s"):format(
            tostring(name), itemID, tostring(itemType), tostring(itemSubType), tostring(classID), tostring(subclassID)))
        return
    elseif msg == "reset" then
        ns.ResetSession()
        print("|cff33ff99LootIQ|r: session loot tally cleared.")
    elseif msg == "clearcreatures" then
        ns.ClearCreatureData()
        print("|cff33ff99LootIQ|r: creature drop/skinning database cleared.")
    elseif msg == "show" then
        ns.db.barShown = true
        ns.Bar:Show()
    elseif msg == "hide" then
        ns.db.barShown = false
        ns.Bar:Hide()
    elseif msg == "options" then
        Settings.OpenToCategory(ns.OptionsCategoryID)
    elseif msg == "scan" then
        ns.ScanAuctionHouse()
    elseif msg == "minimize" then
        ns.db.minimized = true
        ns.RefreshBar()
    elseif msg == "expand" then
        ns.db.minimized = false
        ns.RefreshBar()
    elseif msg == "debug" then
        if not UnitExists("target") then
            print("|cff33ff99LootIQ|r: no target selected.")
            return
        end
        local guid = UnitGUID("target")
        local unitType, _, _, _, _, creatureID = strsplit("-", guid or "")
        creatureID = tonumber(creatureID)
        print(("|cff33ff99LootIQ|r: target=%s guid=%s creatureID=%s"):format(
            UnitName("target") or "?", tostring(guid), tostring(creatureID)))

        local entry = creatureID and ns.accountDB.creatures[creatureID]
        if not entry then
            print("  no drop data recorded for this creature ID yet.")
            return
        end
        print(("  kills tracked: %d"):format(entry.kills))
        local count = 0
        for itemID, drop in pairs(entry.drops) do
            count = count + 1
            print(("  itemID %d: %s x%d, seen %d/%d loots"):format(
                itemID, drop.link, drop.count, drop.occurrences, entry.kills))
        end
        print(("  total distinct items recorded: %d"):format(count))
    elseif msg == "debugall" then
        local creatureCount = 0
        for creatureID, entry in pairs(ns.accountDB.creatures) do
            creatureCount = creatureCount + 1
            local itemCount = 0
            for _ in pairs(entry.drops) do
                itemCount = itemCount + 1
            end
            print(("|cff33ff99LootIQ|r: creature %s - %d kills, %d distinct items"):format(
                tostring(creatureID), entry.kills, itemCount))
        end
        print(("|cff33ff99LootIQ|r: %d creatures recorded total."):format(creatureCount))
    else
        print("|cff33ff99LootIQ|r commands: /lootiq show, /lootiq hide, /lootiq minimize, /lootiq expand, /lootiq reset, /lootiq clearcreatures, /lootiq options, /lootiq scan, /lootiq debug, /lootiq debugall")
    end
end
