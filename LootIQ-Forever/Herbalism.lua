local ADDON_NAME, ns = ...

-- Same shape as Fishing.lua/Mining.lua (see their comments for the full
-- reasoning) - gathering an herb has no creature/GUID source either, so
-- herbs are recorded per zone using GetZoneText() as the key.
--
-- "Currently gathering" is detected the same way "currently fishing"/
-- "currently mining" is: polling UnitChannelInfo/UnitCastingInfo for a
-- cast named "Herb Gathering" rather than trusting a specific event+spellID
-- pairing, which silently failed for Fishing on this client.
local HERBALISM_SPELL_NAME = "Herb Gathering"
local POLL_INTERVAL = 0.2

-- Same reasoning as Mining: gathering a node has no "wait" step beyond the
-- cast itself (a few seconds), so this needs far less margin than Fishing's
-- 90s - just enough for the loot event to actually arrive after the cast -
-- and kept tight deliberately: too generous a window here risks overlapping
-- with a Mining cast done shortly after (or before), misattributing ore
-- into the herbalism list or vice versa. Even at 5s a fast switch between
-- adjacent nodes of different types could still overlap; the "-" button on
-- each zone's item list (see RenderDetail) is there to manually fix that
-- when it happens.
local HERBALISM_FALLBACK_WINDOW = 5
local lastHerbalismCastTime = 0

-- Also used by Tooltip.lua to decide whether a moused-over object is
-- plausibly an herb node.
function ns.GetHerbalismZone()
    if (GetTime() - lastHerbalismCastTime) >= HERBALISM_FALLBACK_WINDOW then return nil end
    local zone = GetZoneText()
    return zone ~= "" and zone or nil
end

local wasGathering = false
local pollElapsed = 0
local pollFrame = CreateFrame("Frame")
pollFrame:SetScript("OnUpdate", function(self, delta)
    pollElapsed = pollElapsed + delta
    if pollElapsed < POLL_INTERVAL then return end
    pollElapsed = 0

    local name = UnitChannelInfo("player") or UnitCastingInfo("player")
    if name == HERBALISM_SPELL_NAME then
        lastHerbalismCastTime = GetTime()
        if not wasGathering then
            wasGathering = true
            ns.DebugPrint("Herb Gathering cast detected - tracking harvests in %s for the next %ds.",
                GetZoneText(), HERBALISM_FALLBACK_WINDOW)
        end
    else
        wasGathering = false
    end
end)

local function GetOrCreateZone(zone)
    local zones = ns.accountDB.herbalism
    local entry = zones[zone]
    if not entry then
        entry = { herbs = {} }
        zones[zone] = entry
    end
    return entry
end

-- Tallied from the herb list itself rather than kept as its own counter -
-- see Fishing.lua's ns.GetTotalFishingCatches for why (a separately-kept
-- counter drifted out of sync with the list it was supposed to describe).
function ns.GetTotalHerbalismHarvests(zone)
    local entry = ns.accountDB.herbalism[zone]
    if not entry then return 0 end

    local total = 0
    for _, drop in pairs(entry.herbs) do
        total = total + drop.occurrences
    end
    return total
end

-- Same shape/logic as Loot.lua's RecordDropInto, kept as its own small
-- copy here rather than shared - see Fishing.lua's identical copy for why.
local function RecordDropInto(store, itemID, link, quantity)
    local drop = store[itemID]
    if drop then
        drop.count = drop.count + quantity
        drop.occurrences = drop.occurrences + 1
    else
        store[itemID] = { count = quantity, occurrences = 1, link = link }
    end
end

local function RecordHarvest(zone, link, quantity)
    local key = ns.GetItemKey(link)
    if not key then return end
    RecordDropInto(GetOrCreateZone(zone).herbs, key, link, quantity)
    ns.RecordGatheringItemSource("herbalism", key, link, zone)
end

-- Mirrors Fishing.lua's LOOT_OPENED/CHAT_MSG_LOOT fallback pairing and its
-- timestamp-based de-dupe (see that file's comment for the race a
-- LOOT_CLOSED-driven flag lost to).
local lastLootOpenedRecordTime = -math.huge
local CHAT_MSG_DEDUPE_WINDOW = 1

local function OnLootOpened()
    local zone = ns.GetHerbalismZone()
    if not zone then return end

    local recorded = 0
    for i = 1, GetNumLootItems() do
        local _, _, quantity = GetLootSlotInfo(i)
        local link = GetLootSlotLink(i)
        if link then
            RecordHarvest(zone, link, quantity or 1)
            recorded = recorded + 1
        end
    end

    if recorded > 0 then
        lastLootOpenedRecordTime = GetTime()
        ns.DebugPrint("recorded an herb harvest in %s (%d item(s)).", zone, recorded)
    end
end

local function OnChatMsgLoot(msg)
    if (GetTime() - lastLootOpenedRecordTime) < CHAT_MSG_DEDUPE_WINDOW then return end
    local zone = ns.GetHerbalismZone()
    if not zone then return end

    local recorded = 0
    for link, qtyStr in msg:gmatch("(|c%x+|Hitem:.-|h.-|h|r)x?(%d*)") do
        RecordHarvest(zone, link, tonumber(qtyStr) or 1)
        recorded = recorded + 1
    end

    if recorded > 0 then
        ns.DebugPrint("recorded an herb harvest via chat fallback in %s (%d item(s)).", zone, recorded)
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
    for zone in pairs(ns.accountDB.herbalism) do
        table.insert(zones, zone)
    end
    table.sort(zones)
    return zones
end

local function GetListLabel(zone)
    local entry = ns.accountDB.herbalism[zone]
    local types = 0
    for _ in pairs(entry.herbs) do types = types + 1 end
    local harvested = ns.GetTotalHerbalismHarvests(zone)
    return ("%s (%d harvested, %d type%s)"):format(zone, harvested, types, types == 1 and "" or "s")
end

local Select -- assigned once ns.BuildBrowserPanel returns; the remove button needs it to refresh the detail pane

-- Lets the player manually correct a mis-attributed item (e.g. ore that
-- ended up here because a Mining cast happened to overlap this zone's
-- fallback window - see HERBALISM_FALLBACK_WINDOW). Removing the last item
-- in a zone drops the zone entry entirely rather than leaving an empty
-- "(0 harvested, 0 types)" stub behind.
local function RemoveHarvest(zone, itemID)
    local entry = ns.accountDB.herbalism[zone]
    if not entry then return end

    entry.herbs[itemID] = nil
    ns.RemoveGatheringItemSource("herbalism", itemID, zone)

    if next(entry.herbs) then
        Select(zone)
    else
        ns.accountDB.herbalism[zone] = nil
        Select(nil)
    end
end

local function RenderDetail(zone, detail)
    local entry = ns.accountDB.herbalism[zone]
    if not entry then return end

    local harvests = ns.GetTotalHerbalismHarvests(zone)
    detail:AddRow(zone, "GameFontNormalLarge")
    detail:AddRow(("%d harvest%s tracked"):format(harvests, harvests == 1 and "" or "s"))
    detail:AddSection("Types:", entry.herbs, harvests, function(itemID) RemoveHarvest(zone, itemID) end)
end

-- Exposed so an "Herbalism: ZoneName" source row in the Item Database can
-- jump straight to that zone's own entry here (see ItemDatabase.lua via
-- Loot.lua's GATHERING_CATEGORIES).
local _
_, Select, ns.GoToHerbalismEntry = ns.BuildBrowserPanel("Herbalism", {
    icon = "Interface/Icons/Trade_Herbalism",
    listLabel = "Known herbalism zones (click one to see what you can harvest):",
    emptyListText = "(no herbalism zones recorded yet - go harvest something)",
    emptyDetailText = "Select a zone from the list to see its known harvests.",
    getIDs = GetIDs,
    getListLabel = GetListLabel,
    renderDetail = RenderDetail,
    isValidID = function(id) return ns.accountDB.herbalism[id] ~= nil end,
})
