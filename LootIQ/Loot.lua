local ADDON_NAME, ns = ...

-- Kill counting is driven entirely by the combat log's PARTY_KILL subevent
-- (fired whenever you or your group gets credit for a kill), independent
-- of whether the corpse is ever looted. This matches "kills tracked" to
-- actual kills rather than to loot interactions.
--
-- Item recording is separate: LOOT_OPENED is the primary, accurate source
-- for what a creature drops, since it snapshots the loot window directly.
-- But some loot doesn't fire LOOT_OPENED at all in this client - confirmed
-- for skinning, and also possible with the base game's own Auto Loot
-- setting granting items instantly - so CHAT_MSG_LOOT is also used as a
-- fallback for any items LOOT_OPENED didn't see. It only skips recording
-- when a loot window is open for that exact corpse right now (meaning
-- LOOT_OPENED just handled it more accurately). "target" can also already
-- have moved on to the next enemy by the time CHAT_MSG_LOOT fires (e.g.
-- with Auto Loot), so a continuously-updated cache of the most recently
-- killed target is used instead of re-checking "target" then.
local killCounted = {}    -- guid -> true once its kill has been counted
local currentLootGuid     -- guid of the loot window currently open, if any (cleared on LOOT_CLOSED)
local currentLootIsContainer = false -- true while the open loot window came from a chest/crate, not a creature (cleared on LOOT_CLOSED)
local lastDeadTarget = { guid = nil, creatureID = nil, name = nil, time = 0 }
local FALLBACK_WINDOW = 5 -- seconds a cached dead target stays usable as a fallback
local lastKnownMoney = GetMoney()

local function GetCreatureIDFromGUID(guid)
    local unitType, _, _, _, _, creatureID = strsplit("-", guid or "")
    if unitType == "Creature" or unitType == "Vehicle" then
        return tonumber(creatureID)
    end
    return nil
end

-- A chest/crate/etc is a GameObject, not a Creature - it never has a
-- "target" to die and get cached the way GetTargetCreature relies on, so
-- its identity has to come from the loot itself. GetLootSourceInfo's GUID
-- works for any loot slot regardless of source type (unlike UnitGUID,
-- which only applies to actual units) - the objectID it carries is the
-- container's template ID, shared by every spawned instance of that same
-- container type (e.g. every "Locked Chest"), exactly like creatureID
-- identifies a type of creature rather than one specific spawn.
--
-- Checks the first slot that actually HAS an item rather than always slot
-- 1: a loot window's money (if any) occupies its own slot with no source
-- GUID attached, so a chest that also drops coin would silently fail
-- detection if slot 1 happened to be that money slot instead of an item.
-- Confirmed against RareScanner (another installed addon targeting this
-- same client) using the identical LootSlotHasItem-then-GetLootSourceInfo
-- pattern for its own container detection.
local function GetLootObjectID()
    for i = 1, GetNumLootItems() do
        if LootSlotHasItem(i) then
            local guid = GetLootSourceInfo(i)
            local unitType, _, _, _, _, objectID = strsplit("-", guid or "")
            if unitType == "GameObject" then
                return tonumber(objectID)
            end
            return nil
        end
    end
    return nil
end

-- A Clam Shell, lockbox, or similar openable bag item has no world GUID at
-- all (it's not an entity - GetLootSourceInfo returns nothing useful for
-- it), so there's nothing for GetLootObjectID above to key off. Instead,
-- watch C_Container.UseContainerItem (the same call the default UI makes
-- for a right-click on a bag item - see AutoVendor.lua's identical hook for
-- a different purpose) and cache whichever bag item was just used, but only
-- when GetContainerItemInfo's hasLoot flag says it's actually a container
-- (so using a potion or bandage never gets cached as one) - the flag is set
-- by the client itself, no name/item-type guessing needed. A short window
-- correlates that use with the loot window that follows; OnLootOpened
-- consumes (clears) the cache the moment it claims a loot window with it,
-- so a second, unrelated loot shortly after (e.g. an actual creature corpse
-- looted moments after opening a Clam Shell) can't also get misattributed
-- to it.
local lastOpenedContainerItem = { itemID = nil, link = nil, time = 0 }
local CONTAINER_ITEM_WINDOW = 3 -- seconds a "just opened this bag item" stays eligible to claim the next loot window

local function OnContainerItemOpened(bag, slot)
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if not (info and info.itemID and info.hasLoot) then return end

    lastOpenedContainerItem.itemID = info.itemID
    lastOpenedContainerItem.link = info.hyperlink
    lastOpenedContainerItem.time = GetTime()
end
hooksecurefunc(C_Container, "UseContainerItem", OnContainerItemOpened)

local function GetRecentlyOpenedContainerItem()
    if lastOpenedContainerItem.itemID and (GetTime() - lastOpenedContainerItem.time) < CONTAINER_ITEM_WINDOW then
        return lastOpenedContainerItem.itemID, lastOpenedContainerItem.link
    end
    return nil, nil
end

-- name is optional and only ever used to fill in (or refresh) the
-- creature's display name for the item-sources reverse index; callers that
-- don't have it on hand (e.g. a bare creatureID) just pass nil.
--
-- A vendor is just a creature whose merchant window the player opened
-- instead of fighting - same GUID/creatureID identity, same entry, so a
-- vendor you've also fought (or a mob that happens to sell things) isn't
-- split across two records. See
-- entry.sells below (RecordVendorSells further down) - unlike
-- drops/skins, this isn't an occurrence-counted store: it's a catalog
-- snapshot ([itemID] = {link, price}) of everything currently in that
-- vendor's window, since a vendor doesn't "occasionally" sell something.
-- The nil-check backfills it for creature entries saved before this field
-- existed.
local function GetOrCreateCreature(creatureID, name)
    local creatures = ns.accountDB.creatures
    local entry = creatures[creatureID]
    if not entry then
        entry = { kills = 0, drops = {}, skins = {}, money = 0, sells = {} }
        creatures[creatureID] = entry
    end
    if not entry.sells then entry.sells = {} end
    if name then entry.name = name end
    -- Falls back to Questie's NPC database (see Core.lua) for the rare case
    -- where no live name was ever captured for this creature - e.g. seen
    -- only via the chat-loot fallback with no target name cached.
    if not entry.name then entry.name = ns.LookupCreatureName(creatureID) end

    -- Always refreshed to wherever this encounter just happened, so a
    -- roaming mob's zone reflects the most recent sighting rather than the
    -- first one - see ns.GetCreatureDisplayName. GetZoneText() can be ""
    -- in some liminal areas, so that's left as whatever zone was recorded
    -- last rather than overwritten with a blank.
    local zone = GetZoneText()
    if zone ~= "" then entry.zone = zone end

    return entry
end

-- "Name (Zone)" for a creature/vendor, or a placeholder if it's never been
-- recorded at all - used anywhere a source's plain name is shown (the
-- Source Database and an item's ranked sources, both here and on the
-- item's own tooltip) so the zone shows up automatically everywhere
-- instead of needing every caller to build it themselves.
function ns.GetCreatureDisplayName(creatureID)
    local entry = ns.accountDB.creatures[creatureID]
    local name = (entry and entry.name) or ("Unknown source #" .. creatureID)
    if entry and entry.zone then
        return ("%s (%s)"):format(name, entry.zone)
    end
    return name
end

-- copper gained while a recently-killed target is cached (see
-- GetTargetCreature) is attributed to it as loot money, same fallback
-- window as item drops. Accumulates across every kill, so the average
-- (ns.GetAverageValuePerKill) divides it back down by entry.kills.
local function RecordMoneyLoot(creatureID, copper, name)
    local entry = GetOrCreateCreature(creatureID, name)
    entry.money = (entry.money or 0) + copper
end

local function RecordKill(guid, creatureID, name)
    if killCounted[guid] then return end
    killCounted[guid] = true

    local entry = GetOrCreateCreature(creatureID, name)
    entry.kills = entry.kills + 1
    ns.DebugPrint("creature %d killed - now %d kills tracked.", creatureID, entry.kills)
end

-- Call this as often as possible - including right before loot fires, via
-- UNIT_SPELLCAST_SUCCEEDED for "player" (which also fires for Skinning
-- succeeding) - so the cache reflects the corpse actually being acted on,
-- not a stale kill from other combat that happened in between.
local function CacheDeadTarget()
    if not (UnitExists("target") and UnitIsDead("target")) then return end
    local guid = UnitGUID("target")
    local creatureID = GetCreatureIDFromGUID(guid)
    if creatureID then
        lastDeadTarget.guid = guid
        lastDeadTarget.creatureID = creatureID
        lastDeadTarget.name = UnitName("target")
        lastDeadTarget.time = GetTime()
    end
end

local function GetTargetCreature()
    CacheDeadTarget()
    if lastDeadTarget.guid and (GetTime() - lastDeadTarget.time) < FALLBACK_WINDOW then
        return lastDeadTarget.guid, lastDeadTarget.creatureID, lastDeadTarget.name
    end
    return nil, nil, nil
end

-- This client reports every Trade Goods item with the same generic
-- subtype/subclassID (verified via /lootiq itemcheck), so subtype can't
-- distinguish leather from other trade goods here. Skinning materials
-- (all tiers, e.g. "Light Leather" through "Thick Hide") always end their
-- name with "Leather" or "Hide"; leather armor doesn't (e.g. "Leather
-- Gloves"), so matching the end of the name works while still requiring
-- Trade Goods to avoid matching anything unrelated.
local function IsSkinningMaterial(itemID)
    local name, _, _, _, _, _, _, _, _, _, _, classID = GetItemInfo(itemID)
    if not name or classID ~= 7 then return false end
    return name:match("Leather$") ~= nil or name:match("Hide$") ~= nil
end

local function RecordDropInto(store, itemID, link, quantity)
    local drop = store[itemID]
    if drop then
        drop.count = drop.count + quantity
        drop.occurrences = drop.occurrences + 1
    else
        store[itemID] = { count = quantity, occurrences = 1, link = link }
    end
end

-- Returns the entries of a drops/skins store (or any other {count,
-- occurrences, link} - shaped store, e.g. Fishing.lua's catches) as a
-- plain array sorted by descending occurrence count, for display (creature
-- tooltip lines, the Source Database panel, etc). Not used for a vendor's
-- sells catalog - that has no occurrence count to sort by (see
-- BrowserPanel.lua's AddVendorSells).
function ns.SortedDrops(store)
    local items = {}
    for _, drop in pairs(store) do
        table.insert(items, drop)
    end
    table.sort(items, function(a, b) return a.occurrences > b.occurrences end)
    return items
end

-- Activities that have no creatureID to attribute an item to (see
-- Fishing.lua/Mining.lua/Herbalism.lua/Crafting.lua/Chests.lua) - each gets
-- its own parallel map on the item entry (key -> true), field named
-- "<key>Sources". The key itself is a zone name for fishing/mining/
-- herbalism, a profession name for crafting, or a container's objectID for
-- chests - the code doesn't care either way, it's just an arbitrary
-- identifier for "where/how this was obtained" within that category.
-- Centralized here (rather than each file just poking its own field name
-- in) so GetOrCreateItemEntry's backfill and ns.GetRankedItemSources' scan
-- both stay in sync with whatever categories exist, and so adding a new one
-- later is a one-line addition to this list instead of hunting down every
-- call site. dbKey/storeField locate the actual per-key data
-- (ns.accountDB[dbKey][key][storeField]); getTotal computes that key's
-- total occurrences for a rate, and goTo navigates to that key's own entry
-- in this category's panel (for a source row's onClick - see
-- ns.GetRankedItemSources and ItemDatabase.lua). getName is optional -
-- only chests need it, since a zone/profession key IS already its own
-- display name but an objectID needs resolving (see Chests.lua's
-- ns.GetChestDisplayName); when absent, the key is used directly. All are
-- wrapped in closures since e.g. ns.GetTotalMiningHarvests/
-- ns.GoToMiningEntry are defined in a file that loads after this one; the
-- closure defers the lookup to call time, well after every file has loaded.
local GATHERING_CATEGORIES = {
    { key = "fishing", dbKey = "fishing", storeField = "fish", label = "Fishing",
        getTotal = function(zone) return ns.GetTotalFishingCatches(zone) end,
        goTo = function(zone) ns.GoToFishingEntry(zone) end },
    { key = "mining", dbKey = "mining", storeField = "ore", label = "Mining",
        getTotal = function(zone) return ns.GetTotalMiningHarvests(zone) end,
        goTo = function(zone) ns.GoToMiningEntry(zone) end },
    { key = "herbalism", dbKey = "herbalism", storeField = "herbs", label = "Herbalism",
        getTotal = function(zone) return ns.GetTotalHerbalismHarvests(zone) end,
        goTo = function(zone) ns.GoToHerbalismEntry(zone) end },
    { key = "crafting", dbKey = "crafting", storeField = "items", label = "Crafting",
        getTotal = function(profession) return ns.GetTotalCraftedCount(profession) end,
        goTo = function(profession) ns.GoToCraftingEntry(profession) end },
    { key = "chests", dbKey = "chests", storeField = "items", label = "Chests",
        getTotal = function(objectID) return ns.GetChestOpens(objectID) end,
        getName = function(objectID) return ns.GetChestDisplayName(objectID) end,
        goTo = function(objectID) ns.GoToChestEntry(objectID) end },
}

-- Reverse index of the same drops/skins data, keyed by ns.GetItemKey
-- instead of by creature - lets a tooltip on the item itself answer "what
-- drops this?" (see Tooltip.lua) without scanning every known creature.
-- The nil-checks backfill each category's field for item entries saved
-- before it existed.
local function GetOrCreateItemEntry(key, link)
    local items = ns.accountDB.items
    local entry = items[key]
    if not entry then
        entry = { link = link, sources = {} }
        items[key] = entry
    end
    entry.link = link
    for _, category in ipairs(GATHERING_CATEGORIES) do
        local field = category.key .. "Sources"
        if not entry[field] then entry[field] = {} end
    end
    return entry
end

local function RecordItemSource(key, link, creatureID)
    GetOrCreateItemEntry(key, link).sources[creatureID] = true
end

-- Called from Fishing.lua/Mining.lua/Herbalism.lua/Crafting.lua/Chests.lua
-- when a catch/harvest/craft/loot is recorded, so the Item Database shows
-- e.g. "Mining: ZoneName" alongside any creature/vendor sources for the
-- same item. category is the plain string key ("fishing"/"mining"/
-- "herbalism"/"crafting"/"chests" - matches a .key entry in
-- GATHERING_CATEGORIES). key is an ns.GetItemKey result, not a bare itemID.
function ns.RecordGatheringItemSource(category, key, link, zone)
    GetOrCreateItemEntry(key, link)[category .. "Sources"][zone] = true
end

-- Reverse of the above - called when a gathering panel's remove button
-- (see Mining.lua/Herbalism.lua) clears an item from a zone's list, so the
-- Item Database stops listing that zone as a source for it too. Without
-- this, a removed item would still show up there (just permanently stuck
-- at 0%, since the occurrence data ns.GetRankedItemSources needs for a
-- rate is gone but the source pointer itself wouldn't be).
function ns.RemoveGatheringItemSource(category, key, zone)
    local item = ns.accountDB.items[key]
    local field = item and item[category .. "Sources"]
    if field then field[zone] = nil end
end

-- key is an ns.GetItemKey result (bare itemID, or "itemID:suffix" for a
-- random-enchant roll like "of the Monkey") - see its own comment in
-- Core.lua for why drops/skins need this instead of the bare itemID
-- IsSkinningMaterial still uses below (a skinning-material check cares
-- about the base item type, never its random suffix).
local function RecordCreatureDrop(creatureID, link, quantity, name)
    local itemID = tonumber(link:match("item:(%d+)"))
    if not itemID then return end
    local key = ns.GetItemKey(link)

    local entry = GetOrCreateCreature(creatureID, name)
    local store = IsSkinningMaterial(itemID) and entry.skins or entry.drops
    RecordDropInto(store, key, link, quantity)
    RecordItemSource(key, link, creatureID)
end

-- Snapshots a vendor's whole sale list (every slot, not just what's
-- actually bought) into the same source database as kills/drops, plus the
-- vendor's current price for each - and the item itself into the Item
-- Database, same as any other item source. Runs on MERCHANT_SHOW (see the
-- event dispatcher below) rather than hooking BuyMerchantItem, since the
-- goal is "what does this vendor sell", not "what did I buy" - the full
-- list is already right there in GetMerchantItemInfo without waiting for a
-- purchase. Re-scanned every time the window opens so a price change (e.g.
-- from a reputation discount) stays current.
-- entry.sells stays keyed by the bare itemID (not ns.GetItemKey) - a
-- vendor's catalog is a fixed, deterministic list, never a random-suffix
-- roll, so there's no "of the Monkey" vs "of the Whale" ambiguity to
-- resolve here the way there is for actual loot drops.
local function RecordVendorSells(vendorID, name)
    local entry = GetOrCreateCreature(vendorID, name)
    for index = 1, GetMerchantNumItems() do
        local link = GetMerchantItemLink(index)
        local itemID = link and tonumber(link:match("item:(%d+)"))
        if itemID then
            local _, _, price = GetMerchantItemInfo(index)
            entry.sells[itemID] = { link = link, price = price }
            RecordItemSource(ns.GetItemKey(link), link, vendorID)
        end
    end
end

-- Returns a list of { name, pct, creatureID, price, onClick } for this
-- item's known sources (creature drop/skin rate, a flat 100% for something
-- a vendor sells - see RecordVendorSells above - or a gathering rate for a
-- zone (fishing/mining/herbalism) - see ns.RecordGatheringItemSource and
-- GATHERING_CATEGORIES), ranked by that rate descending. creatureID is nil
-- for a gathering source (there's no creature to link to); it's what lets
-- the Item Database's source rows jump to that creature's (or vendor's -
-- same identity space) Source Database entry (see ItemDatabase.lua and
-- ns.GoToSourceDatabaseEntry). onClick is only set for a gathering source -
-- calling it navigates to that zone's entry in the matching Fishing/
-- Mining/Herbalism panel (GATHERING_CATEGORIES' goTo); ItemDatabase.lua
-- uses it the same way it uses creatureID. price is only set for a vendor
-- source (the actual copper cost, always shown at full precision
-- regardless of the loot bar's "show copper" setting - see
-- ItemDatabase.lua, which shows it instead of pct when present). Used
-- wherever an item's sources are shown with a rate per one - the item's own
-- tooltip (Tooltip.lua) and the Item Database. pct is 0 for a drop/skin
-- source with no kills tracked yet (can't compute a rate) rather than
-- being excluded.
-- A source whose creature name hasn't been captured yet (possible if it
-- was only ever seen via the chat-loot fallback before a kill logged its
-- name) falls back to a placeholder rather than being silently dropped.
function ns.GetRankedItemSources(key)
    local item = ns.accountDB.items[key]
    if not item then return nil end

    local hasSource = next(item.sources) ~= nil
    if not hasSource then
        for _, category in ipairs(GATHERING_CATEGORIES) do
            -- item[category.key .. "Sources"] can be nil for an item entry
            -- saved before that category existed (e.g. via Core.lua's
            -- one-time creature-drops backfill, which predates all three).
            if next(item[category.key .. "Sources"] or {}) then
                hasSource = true
                break
            end
        end
    end
    if not hasSource then return nil end

    local results = {}
    for creatureID in pairs(item.sources) do
        local creature = ns.accountDB.creatures[creatureID]
        local name = ns.GetCreatureDisplayName(creatureID)
        local drop = creature and (creature.drops[key] or creature.skins[key])
        -- creature.sells stays bare-itemID-keyed (see RecordVendorSells) -
        -- this lookup only succeeds when `key` itself is a bare itemID
        -- (no random suffix), which is the only shape a vendor's catalog
        -- can ever contain.
        local sells = creature and creature.sells and creature.sells[key]
        local pct = 0
        if drop and creature.kills > 0 then
            pct = drop.occurrences / creature.kills * 100
        elseif sells then
            -- A vendor doesn't have a "chance" to sell it - it just always
            -- does - so there's no rate to compute; 100% reads as "reliably
            -- available here" rather than a drop percentage.
            pct = 100
        end
        -- price is only present for a vendor source, since a drop/skin has
        -- no fixed sale price to show - see ItemDatabase.lua, which shows
        -- it instead of the percentage when present.
        table.insert(results, { name = name, pct = pct, creatureID = creatureID, price = sells and sells.price })
    end
    for _, category in ipairs(GATHERING_CATEGORIES) do
        for zone in pairs(item[category.key .. "Sources"] or {}) do
            local zoneEntry = ns.accountDB[category.dbKey][zone]
            local drop = zoneEntry and zoneEntry[category.storeField][key]
            local total = category.getTotal(zone)
            local pct = (total > 0 and drop) and (drop.occurrences / total * 100) or 0
            local displayName = category.getName and category.getName(zone) or zone
            -- onClick jumps to this zone's entry in the matching Fishing/
            -- Mining/Herbalism/Chests panel (see ItemDatabase.lua, which
            -- uses it the same way it uses creatureID for a creature/vendor
            -- source).
            table.insert(results, { name = category.label .. ": " .. displayName, pct = pct,
                onClick = function() category.goTo(zone) end })
        end
    end
    table.sort(results, function(a, b) return a.pct > b.pct end)
    return results
end

-- Returns the creatureID of whichever known source has looted/skinned this
-- item most often (by occurrence count, the same metric ns.SortedDrops
-- ranks by), or nil if the item has no known sources yet. Used to pick a
-- single creature model to preview for an item with several sources (see
-- ItemDatabase.lua).
function ns.GetPrimaryItemSource(key)
    local item = ns.accountDB.items[key]
    if not item then return nil end

    local bestID, bestOccurrences = nil, -1
    for creatureID in pairs(item.sources) do
        local creature = ns.accountDB.creatures[creatureID]
        local drop = creature and (creature.drops[key] or creature.skins[key])
        local occurrences = (drop and drop.occurrences) or 0
        if occurrences > bestOccurrences then
            bestID, bestOccurrences = creatureID, occurrences
        end
    end
    return bestID
end

local function OnLootOpened()
    local objectID = GetLootObjectID()
    if objectID then
        currentLootIsContainer = true
        ns.RecordChestOpen(objectID, ns.LookupObjectName(objectID))

        local itemsRecorded = 0
        for i = 1, GetNumLootItems() do
            local _, _, quantity = GetLootSlotInfo(i)
            local link = GetLootSlotLink(i)
            if link then
                ns.RecordChestLoot(objectID, link, quantity or 1)
                itemsRecorded = itemsRecorded + 1
            end
        end
        ns.DebugPrint("recorded %d item(s) from container %d's loot window.", itemsRecorded, objectID)
        return
    end

    local containerItemID, containerLink = GetRecentlyOpenedContainerItem()
    if containerItemID then
        -- Consumed immediately so a second, unrelated loot window shortly
        -- after (e.g. an actual creature corpse looted moments after
        -- opening a Clam Shell) can't also get misattributed to this same
        -- bag item.
        lastOpenedContainerItem.itemID = nil

        currentLootIsContainer = true
        local key = "item:" .. containerItemID
        ns.RecordChestOpen(key, containerLink and (GetItemInfo(containerLink)))

        local itemsRecorded = 0
        for i = 1, GetNumLootItems() do
            local _, _, quantity = GetLootSlotInfo(i)
            local link = GetLootSlotLink(i)
            if link then
                ns.RecordChestLoot(key, link, quantity or 1)
                itemsRecorded = itemsRecorded + 1
            end
        end
        ns.DebugPrint("recorded %d item(s) from opening %s.", itemsRecorded, containerLink or key)
        return
    end
    currentLootIsContainer = false

    -- guid, creatureID and name are always returned together (or not at all).
    local guid, creatureID, name = GetTargetCreature()
    if not guid then
        ns.DebugPrint("couldn't identify the loot source (no recent dead target) - items from this loot weren't recorded.")
        return
    end

    currentLootGuid = guid

    local itemsRecorded = 0
    for i = 1, GetNumLootItems() do
        local _, _, quantity = GetLootSlotInfo(i)
        local link = GetLootSlotLink(i)
        if link then
            RecordCreatureDrop(creatureID, link, quantity or 1, name)
            itemsRecorded = itemsRecorded + 1
        end
    end
    ns.DebugPrint("recorded %d item(s) from creature %d's loot window.", itemsRecorded, creatureID)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("LOOT_OPENED")
frame:RegisterEvent("LOOT_CLOSED")
frame:RegisterEvent("CHAT_MSG_LOOT")
frame:RegisterEvent("PLAYER_MONEY")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
frame:RegisterEvent("MERCHANT_SHOW")
frame:RegisterUnitEvent("UNIT_HEALTH", "target")
frame:SetScript("OnEvent", function(self, event, msg)
    if event == "LOOT_OPENED" then
        OnLootOpened()
    elseif event == "LOOT_CLOSED" then
        currentLootGuid = nil
        currentLootIsContainer = false
    elseif event == "MERCHANT_SHOW" then
        local vendorID = GetCreatureIDFromGUID(UnitGUID("target"))
        if vendorID then
            RecordVendorSells(vendorID, UnitName("target"))
            ns.DebugPrint("recorded %d item(s) for sale from creature %d.", GetMerchantNumItems(), vendorID)
        end
    elseif event == "PLAYER_MONEY" then
        local money = GetMoney()
        local gained = money - lastKnownMoney
        lastKnownMoney = money

        -- PLAYER_MONEY fires for any change (spending included), so only
        -- act on a gain, and only attribute it while a recently-killed
        -- target is still cached - same fallback window and false-positive
        -- tradeoff (e.g. selling to a vendor within 5s of a kill) already
        -- accepted for chat-loot item recording below.
        if gained > 0 then
            local fallbackGuid, fallbackCreatureID, fallbackName = GetTargetCreature()
            if fallbackGuid then
                RecordMoneyLoot(fallbackCreatureID, gained, fallbackName)
                ns.DebugPrint("recorded %s copper loot for creature %d.", tostring(gained), fallbackCreatureID)
            end
        end
    elseif event == "PLAYER_TARGET_CHANGED" or event == "UNIT_HEALTH" then
        CacheDeadTarget()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if msg == "player" then
            CacheDeadTarget()
        end
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local _, subevent, _, _, _, _, _, destGUID, destName = CombatLogGetCurrentEventInfo()
        if subevent == "PARTY_KILL" then
            local creatureID = GetCreatureIDFromGUID(destGUID)
            if creatureID then
                RecordKill(destGUID, creatureID, destName)
            end
        end
    elseif event == "CHAT_MSG_LOOT" then
        local fallbackGuid, fallbackCreatureID, fallbackName = GetTargetCreature()

        -- Only skip item recording here if a loot window is CURRENTLY open
        -- for this exact corpse - LOOT_OPENED already snapshotted it more
        -- accurately. A separate, later loot session for the same corpse
        -- (e.g. skinning, which doesn't seem to fire LOOT_OPENED at all in
        -- this client) isn't covered by that, so it still needs recording
        -- here. Also skipped outright while the CURRENT window is a
        -- container's (currentLootIsContainer, set for both a world
        -- chest/crate and a just-opened bag item like a Clam Shell) -
        -- GetTargetCreature's 5s fallback window has nothing to do with the
        -- container just opened (a world container's GUID is a
        -- GameObject's, never equal to a creature's, and a bag item has no
        -- GUID at all - the guid check alone wouldn't catch either case),
        -- and Chests.lua's own LOOT_OPENED handling already recorded these
        -- items correctly.
        local useFallbackRecording = not currentLootIsContainer and fallbackGuid and fallbackGuid ~= currentLootGuid
        local fallbackItemsRecorded = 0

        -- Iterates every item link in the message (not just the first) since
        -- the client can combine several looted items into a single line.
        for link, qtyStr in msg:gmatch("(|c%x+|Hitem:.-|h.-|h|r)x?(%d*)") do
            local itemID = tonumber(link:match("item:(%d+)"))
            if itemID then
                if useFallbackRecording then
                    RecordCreatureDrop(fallbackCreatureID, link, tonumber(qtyStr) or 1, fallbackName)
                    fallbackItemsRecorded = fallbackItemsRecorded + 1
                end

                -- Skip items below the configured quality threshold, unless
                -- the item is whitelisted. If quality isn't cached yet, let
                -- it through rather than silently hiding it. The master
                -- auto-add toggle overrides all of this, including the
                -- whitelist, when off.
                local quality = select(3, GetItemInfo(itemID))
                if ns.db.autoAddLoot and (ns.db.whitelist[itemID] or not (quality and ns.db and quality < ns.db.minQuality)) then
                    ns.AddSessionItem(link, GetItemIcon(itemID))
                end
            end
        end

        if useFallbackRecording and fallbackItemsRecorded > 0 then
            ns.DebugPrint("recorded %d item(s) via chat fallback for creature %d.",
                fallbackItemsRecorded, fallbackCreatureID)
        end
    end
end)
