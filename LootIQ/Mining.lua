local ADDON_NAME, ns = ...

-- Same shape as Fishing.lua (see its comments for the full reasoning) -
-- mining a node has no creature/GUID source either, so ore is recorded per
-- zone using GetZoneText() as the key.
--
-- "Currently mining" is detected the same way "currently fishing" is:
-- polling UnitChannelInfo/UnitCastingInfo for a cast named "Mining" rather
-- than trusting a specific event+spellID pairing, which silently failed for
-- Fishing on this client.
local MINING_SPELL_NAME = "Mining"
local POLL_INTERVAL = 0.2

-- Unlike Fishing, mining a node has no "wait for a bite" step - the cast
-- itself (a few seconds) is the whole interaction, and the ore lands in
-- your bag right after. The fallback window still needs some margin for
-- the loot event to actually arrive, but nowhere near Fishing's 90s - and
-- kept tight deliberately: too generous a window here risks overlapping
-- with a Herb Gathering cast done shortly after (or before), misattributing
-- an herb into the mining list or vice versa. Even at 5s a fast switch
-- between adjacent nodes of different types could still overlap; the
-- "-" button on each zone's item list (see RenderDetail) is there to
-- manually fix that when it happens.
local MINING_FALLBACK_WINDOW = 5
local lastMiningCastTime = 0

-- Also used by Tooltip.lua to decide whether a moused-over object is
-- plausibly a mining node.
function ns.GetMiningZone()
    if (GetTime() - lastMiningCastTime) >= MINING_FALLBACK_WINDOW then return nil end
    local zone = GetZoneText()
    return zone ~= "" and zone or nil
end

local wasMining = false
local pollElapsed = 0
local pollFrame = CreateFrame("Frame")
pollFrame:SetScript("OnUpdate", function(self, delta)
    pollElapsed = pollElapsed + delta
    if pollElapsed < POLL_INTERVAL then return end
    pollElapsed = 0

    local name = UnitChannelInfo("player") or UnitCastingInfo("player")
    if name == MINING_SPELL_NAME then
        lastMiningCastTime = GetTime()
        if not wasMining then
            wasMining = true
            ns.DebugPrint("Mining cast detected - tracking harvests in %s for the next %ds.",
                GetZoneText(), MINING_FALLBACK_WINDOW)
        end
    else
        wasMining = false
    end
end)

local function GetOrCreateZone(zone)
    local zones = ns.accountDB.mining
    local entry = zones[zone]
    if not entry then
        entry = { ore = {} }
        zones[zone] = entry
    end
    return entry
end

-- Tallied from the ore list itself rather than kept as its own counter -
-- see Fishing.lua's ns.GetTotalFishingCatches for why (a separately-kept
-- counter drifted out of sync with the list it was supposed to describe).
function ns.GetTotalMiningHarvests(zone)
    local entry = ns.accountDB.mining[zone]
    if not entry then return 0 end

    local total = 0
    for _, drop in pairs(entry.ore) do
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
    RecordDropInto(GetOrCreateZone(zone).ore, key, link, quantity)
    ns.RecordGatheringItemSource("mining", key, link, zone)
end

-- Smelting is a Mining sub-skill - GetTradeSkillLine() reports it as
-- "Mining" the same as actually swinging a pick, since it shares Mining's
-- skill line (see Crafting.lua) - so per an explicit user request, smelted
-- items fold into this same Mining tab rather than Crafting.lua giving
-- them their own "Mining" entry there too. Filed under a fixed "Smelting"
-- key (not a real zone) alongside actual zone entries in the same list,
-- since GetOrCreateZone doesn't care whether its key is a place or an
-- activity - it's just a string either way.
function ns.RecordSmelting(link, quantity)
    RecordHarvest("Smelting", link, quantity)
end

-- Mirrors Fishing.lua's LOOT_OPENED/CHAT_MSG_LOOT fallback pairing and its
-- timestamp-based de-dupe (see that file's comment for the race a
-- LOOT_CLOSED-driven flag lost to).
local lastLootOpenedRecordTime = -math.huge
local CHAT_MSG_DEDUPE_WINDOW = 1

local function OnLootOpened()
    local zone = ns.GetMiningZone()
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
        ns.DebugPrint("recorded a mining harvest in %s (%d item(s)).", zone, recorded)
    end
end

local function OnChatMsgLoot(msg)
    if (GetTime() - lastLootOpenedRecordTime) < CHAT_MSG_DEDUPE_WINDOW then return end
    local zone = ns.GetMiningZone()
    if not zone then return end

    local recorded = 0
    for link, qtyStr in msg:gmatch("(|c%x+|Hitem:.-|h.-|h|r)x?(%d*)") do
        RecordHarvest(zone, link, tonumber(qtyStr) or 1)
        recorded = recorded + 1
    end

    if recorded > 0 then
        ns.DebugPrint("recorded a mining harvest via chat fallback in %s (%d item(s)).", zone, recorded)
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
    for zone in pairs(ns.accountDB.mining) do
        table.insert(zones, zone)
    end
    table.sort(zones)
    return zones
end

local function GetListLabel(zone)
    local entry = ns.accountDB.mining[zone]
    local types = 0
    for _ in pairs(entry.ore) do types = types + 1 end
    local harvested = ns.GetTotalMiningHarvests(zone)
    return ("%s (%d harvested, %d type%s)"):format(zone, harvested, types, types == 1 and "" or "s")
end

local Select -- assigned once ns.BuildBrowserPanel returns; the remove button needs it to refresh the detail pane

-- Lets the player manually correct a mis-attributed item (e.g. an herb
-- that ended up here because a Herb Gathering cast happened to overlap
-- this zone's fallback window - see MINING_FALLBACK_WINDOW). Removing the
-- last item in a zone drops the zone entry entirely rather than leaving an
-- empty "(0 harvested, 0 types)" stub behind.
local function RemoveHarvest(zone, itemID)
    local entry = ns.accountDB.mining[zone]
    if not entry then return end

    entry.ore[itemID] = nil
    ns.RemoveGatheringItemSource("mining", itemID, zone)

    if next(entry.ore) then
        Select(zone)
    else
        ns.accountDB.mining[zone] = nil
        Select(nil)
    end
end

local function RenderDetail(zone, detail)
    local entry = ns.accountDB.mining[zone]
    if not entry then return end

    local harvests = ns.GetTotalMiningHarvests(zone)
    detail:AddRow(zone, "GameFontNormalLarge")
    detail:AddRow(("%d harvest%s tracked"):format(harvests, harvests == 1 and "" or "s"))
    detail:AddSection("Types:", entry.ore, harvests, function(itemID) RemoveHarvest(zone, itemID) end)
end

-- Exposed so a "Mining: ZoneName" source row in the Item Database can jump
-- straight to that zone's own entry here (see ItemDatabase.lua via
-- Loot.lua's GATHERING_CATEGORIES).
local _
_, Select, ns.GoToMiningEntry = ns.BuildBrowserPanel("Mining", {
    icon = "Interface/Icons/Trade_Mining",
    listLabel = "Known mining zones (click one to see what you can harvest):",
    emptyListText = "(no mining zones recorded yet - go harvest something)",
    emptyDetailText = "Select a zone from the list to see its known harvests.",
    getIDs = GetIDs,
    getListLabel = GetListLabel,
    renderDetail = RenderDetail,
    isValidID = function(id) return ns.accountDB.mining[id] ~= nil end,
})
