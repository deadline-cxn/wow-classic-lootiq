local ADDON_NAME, ns = ...

-- Fishing has no creature/GUID source to attribute a catch to (there's no
-- "target" involved at all), so catches are recorded per zone instead,
-- using GetZoneText() as the key.
--
-- "Currently fishing" is detected by directly polling UnitChannelInfo/
-- UnitCastingInfo for a spell named "Fishing", rather than listening for a
-- specific cast-start event: whether the "Fishing" cast is a channel or a
-- plain timed cast - and which of several numeric spell IDs it uses (see
-- BetterFishing, another installed addon, which checks half a dozen) -
-- varies enough across game versions/progression realms that an
-- event-name approach silently failed on this client. Polling the live
-- cast/channel state directly sidesteps needing to know either of those.
local FISHING_SPELL_NAME = "Fishing"
local POLL_INTERVAL = 0.2

-- The "Fishing" cast itself IS the wait for a bite (observed up to ~30s),
-- after which the bobber splashes and the player still has to notice and
-- click it - so the fallback window has to cover the full
-- cast-wait-click cycle, not just the cast. Tracked the same way Loot.lua
-- caches a recently-killed target: a timestamp plus a generous validity
-- window, re-checked whenever a catch needs attributing.
local FISHING_FALLBACK_WINDOW = 90
local lastFishingCastTime = 0

-- Also used by Tooltip.lua to decide whether a moused-over object is
-- plausibly the player's own bobber.
function ns.GetFishingZone()
    if (GetTime() - lastFishingCastTime) >= FISHING_FALLBACK_WINDOW then return nil end
    local zone = GetZoneText()
    return zone ~= "" and zone or nil
end

-- Prints once per contiguous cast/channel (not once per poll tick, which
-- would spam chat many times a second) so testing can confirm detection is
-- actually working without flooding the chat window.
local wasFishing = false
local pollElapsed = 0
local pollFrame = CreateFrame("Frame")
pollFrame:SetScript("OnUpdate", function(self, delta)
    pollElapsed = pollElapsed + delta
    if pollElapsed < POLL_INTERVAL then return end
    pollElapsed = 0

    local name = UnitChannelInfo("player") or UnitCastingInfo("player")
    if name == FISHING_SPELL_NAME then
        lastFishingCastTime = GetTime()
        if not wasFishing then
            wasFishing = true
            ns.DebugPrint("Fishing cast detected - tracking catches in %s for the next %ds.",
                GetZoneText(), FISHING_FALLBACK_WINDOW)
        end
    else
        wasFishing = false
    end
end)

local function GetOrCreateZone(zone)
    local zones = ns.accountDB.fishing
    local entry = zones[zone]
    if not entry then
        entry = { fish = {} }
        zones[zone] = entry
    end
    return entry
end

-- Tallied from the fish list itself (each fish's occurrences is "how many
-- catch events produced this fish") rather than kept as its own
-- incrementally-updated counter, so it can never drift out of sync with
-- what's actually in the list - which a separately-tracked counter did
-- (see the LOOT_OPENED/CHAT_MSG_LOOT de-dupe comment below for the bug that
-- caused it). Also used by Loot.lua for a fishing source's drop-rate %.
function ns.GetTotalFishingCatches(zone)
    local entry = ns.accountDB.fishing[zone]
    if not entry then return 0 end

    local total = 0
    for _, drop in pairs(entry.fish) do
        total = total + drop.occurrences
    end
    return total
end

-- Same shape/logic as Loot.lua's RecordDropInto, kept as its own small
-- copy here rather than shared - fishing's zone-keyed schema is otherwise
-- unrelated to the creature-keyed one, so there's no other coupling
-- between the two files worth introducing for one helper.
local function RecordDropInto(store, itemID, link, quantity)
    local drop = store[itemID]
    if drop then
        drop.count = drop.count + quantity
        drop.occurrences = drop.occurrences + 1
    else
        store[itemID] = { count = quantity, occurrences = 1, link = link }
    end
end

local function RecordCatch(zone, link, quantity)
    local key = ns.GetItemKey(link)
    if not key then return end
    RecordDropInto(GetOrCreateZone(zone).fish, key, link, quantity)
    ns.RecordGatheringItemSource("fishing", key, link, zone)
end

-- Mirrors Loot.lua's LOOT_OPENED/CHAT_MSG_LOOT fallback pairing: LOOT_OPENED
-- snapshots the loot window accurately when it fires, and CHAT_MSG_LOOT
-- only fills in when it didn't (e.g. an auto-loot catch that skips the
-- window entirely).
--
-- De-duped by a short timestamp window rather than "is a loot window
-- currently open" (a LOOT_CLOSED-driven flag, which is what this used
-- originally): a single-item fishing catch can open AND close its loot
-- window essentially instantly with Auto Loot on, so LOOT_CLOSED could fire
-- - and clear an "already handled" flag - before CHAT_MSG_LOOT for that
-- same catch even arrived, silently double-recording every catch (inflating
-- each fish's own count/occurrences - back when the total catch count was
-- its own separately-tracked field instead of tallied from this list, that
-- drift was why the two didn't line up). A short time window sidesteps
-- that race entirely, since it doesn't depend on the window's open/closed
-- state.
local lastLootOpenedRecordTime = -math.huge
local CHAT_MSG_DEDUPE_WINDOW = 1

local function OnLootOpened()
    local zone = ns.GetFishingZone()
    if not zone then return end

    local recorded = 0
    for i = 1, GetNumLootItems() do
        local _, _, quantity = GetLootSlotInfo(i)
        local link = GetLootSlotLink(i)
        if link then
            RecordCatch(zone, link, quantity or 1)
            recorded = recorded + 1
        end
    end

    if recorded > 0 then
        lastLootOpenedRecordTime = GetTime()
        ns.DebugPrint("recorded a fishing catch in %s (%d item(s)).", zone, recorded)
    end
end

local function OnChatMsgLoot(msg)
    if (GetTime() - lastLootOpenedRecordTime) < CHAT_MSG_DEDUPE_WINDOW then return end
    local zone = ns.GetFishingZone()
    if not zone then return end

    local recorded = 0
    for link, qtyStr in msg:gmatch("(|c%x+|Hitem:.-|h.-|h|r)x?(%d*)") do
        RecordCatch(zone, link, tonumber(qtyStr) or 1)
        recorded = recorded + 1
    end

    if recorded > 0 then
        ns.DebugPrint("recorded a fishing catch via chat fallback in %s (%d item(s)).", zone, recorded)
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("LOOT_OPENED")
frame:RegisterEvent("CHAT_MSG_LOOT")
frame:SetScript("OnEvent", function(self, event, msg)
    if event == "LOOT_OPENED" then
        OnLootOpened()
    elseif event == "CHAT_MSG_LOOT" then
        OnChatMsgLoot(msg)
    end
end)

local function GetIDs()
    local zones = {}
    for zone in pairs(ns.accountDB.fishing) do
        table.insert(zones, zone)
    end
    table.sort(zones)
    return zones
end

local function GetListLabel(zone)
    local entry = ns.accountDB.fishing[zone]
    local types = 0
    for _ in pairs(entry.fish) do types = types + 1 end
    local caught = ns.GetTotalFishingCatches(zone)
    return ("%s (%d caught, %d type%s)"):format(zone, caught, types, types == 1 and "" or "s")
end

local function RenderDetail(zone, detail)
    local entry = ns.accountDB.fishing[zone]
    if not entry then return end

    local catches = ns.GetTotalFishingCatches(zone)
    detail:AddRow(zone, "GameFontNormalLarge")
    detail:AddRow(("%d %s tracked"):format(catches, catches == 1 and "catch" or "catches"))
    detail:AddSection("Types:", entry.fish, catches)
end

-- Exposed so a "Fishing: ZoneName" source row in the Item Database can
-- jump straight to that zone's own entry here (see ItemDatabase.lua via
-- Loot.lua's GATHERING_CATEGORIES).
local _
_, _, ns.GoToFishingEntry = ns.BuildBrowserPanel("Fishing", {
    icon = "Interface/Icons/Trade_Fishing",
    listLabel = "Known fishing zones (click one to see what you can catch):",
    emptyListText = "(no fishing zones recorded yet - go catch something)",
    emptyDetailText = "Select a zone from the list to see its known catches.",
    getIDs = GetIDs,
    getListLabel = GetListLabel,
    renderDetail = RenderDetail,
    isValidID = function(id) return ns.accountDB.fishing[id] ~= nil end,
})
