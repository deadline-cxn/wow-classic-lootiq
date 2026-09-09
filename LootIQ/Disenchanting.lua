local ADDON_NAME, ns = ...

-- Disenchant materials - keyed by ns.GetItemKey of the DISENCHANTED item
-- itself (the item that got consumed, not a material it produced), same key
-- shape used everywhere else an item's identity matters (see Core.lua's
-- GetItemKey - "of the Monkey" vs "of the Whale" rolls of the same base
-- item are kept separate here too, since a random-suffix roll can affect
-- what a disenchant yields). See Loot.lua's SpellTargetItem hook +
-- OnLootOpened, which detects a Disenchant cast on a bag item and
-- correlates it with the loot window that follows - same
-- click-then-correlate-next-loot-window design as Chests.lua's bag-opened
-- container path.
local Select -- assigned once ns.BuildBrowserPanel returns; the remove button needs it to refresh the detail pane

-- link is optional and only ever used to fill in (or refresh) the
-- disenchanted item's own link, needed to resolve its display name/icon -
-- same reasoning as Chests.lua's GetOrCreateChest.
local function GetOrCreateDisenchantEntry(key, link)
    local disenchanting = ns.accountDB.disenchanting
    local entry = disenchanting[key]
    if not entry then
        entry = { disenchants = 0, materials = {} }
        disenchanting[key] = entry
    end
    if link then entry.link = link end
    return entry
end

-- disenchants is a real independent counter (like a chest's opens), not
-- summed from the materials list - a single disenchant can yield 0, 1, or
-- several material stacks, so it can't be derived from the list the way
-- Fishing's catch total can (see that file's double-counting fix for why
-- that distinction matters).
function ns.RecordDisenchant(key, link)
    local entry = GetOrCreateDisenchantEntry(key, link)
    entry.disenchants = entry.disenchants + 1
end

-- Same shape/logic as Loot.lua's RecordDropInto, kept as its own small
-- local copy rather than shared - see Fishing.lua's identical comment for
-- why (each gathering-style tracker file is deliberately self-contained).
local function RecordDropInto(store, itemID, link, quantity)
    local drop = store[itemID]
    if drop then
        drop.count = drop.count + quantity
        drop.occurrences = drop.occurrences + 1
    else
        store[itemID] = { count = quantity, occurrences = 1, link = link }
    end
end

-- key/link here identify the DISENCHANTED item (this entry's own identity);
-- matLink/quantity describe one material result from its loot window -
-- distinct from this function's own key param, the same way Chests.lua's
-- RecordChestLoot distinguishes a chest's key from a looted item's own key.
function ns.RecordDisenchantMaterial(key, link, matLink, quantity)
    local matKey = ns.GetItemKey(matLink)
    if not matKey then return end

    local entry = GetOrCreateDisenchantEntry(key, link)
    RecordDropInto(entry.materials, matKey, matLink, quantity)
    ns.RecordGatheringItemSource("disenchanting", matKey, matLink, key)
end

function ns.GetDisenchantCount(key)
    local entry = ns.accountDB.disenchanting[key]
    return entry and entry.disenchants or 0
end

-- Used anywhere a disenchanted item's plain name is shown (this panel, and
-- a material's ranked sources via Loot.lua's GATHERING_CATEGORIES) - same
-- idea as ns.GetChestDisplayName/ns.GetCreatureDisplayName, resolved via
-- the stored link since GetItemInfo can't take this table's composite
-- "itemID:suffix" keys directly (see Core.lua's GetItemKey).
function ns.GetDisenchantDisplayName(key)
    local entry = ns.accountDB.disenchanting[key]
    local name = entry and entry.link and GetItemInfo(entry.link)
    return name or ("Unknown item (" .. tostring(key) .. ")")
end

-- Unlike Mining.lua/Herbalism.lua's RemoveHarvest, this never deletes the
-- whole entry even if its material list ends up empty - a disenchanted
-- item's identity (link, disenchant count) is independent of its current
-- material list, same as Chests.lua's RemoveChestItem.
local function RemoveDisenchantMaterial(key, matKey)
    local entry = ns.accountDB.disenchanting[key]
    if entry then entry.materials[matKey] = nil end
    ns.RemoveGatheringItemSource("disenchanting", matKey, key)
    Select(key)
end

local function GetIDs()
    local ids = {}
    for key in pairs(ns.accountDB.disenchanting) do
        table.insert(ids, key)
    end
    table.sort(ids, function(a, b)
        return ns.GetDisenchantDisplayName(a) < ns.GetDisenchantDisplayName(b)
    end)
    return ids
end

local function GetListLabel(key)
    local entry = ns.accountDB.disenchanting[key]
    local types = 0
    for _ in pairs(entry.materials) do types = types + 1 end
    return ("%s (%d disenchanted, %d material type%s)"):format(
        ns.GetDisenchantDisplayName(key), entry.disenchants, types, types == 1 and "" or "s")
end

local function RenderDetail(key, detail)
    local entry = ns.accountDB.disenchanting[key]
    if not entry then return end

    detail:AddRow(ns.GetDisenchantDisplayName(key), "GameFontNormalLarge")
    detail:AddRow(("%d disenchant%s tracked"):format(entry.disenchants, entry.disenchants == 1 and "" or "s"))
    detail:AddSection("Materials received:", entry.materials, entry.disenchants,
        function(matKey) RemoveDisenchantMaterial(key, matKey) end)
end

-- Exposed so a "Disenchanting: Item Name" source row in the Item Database
-- can jump straight to that item's own entry here (see ItemDatabase.lua via
-- Loot.lua's GATHERING_CATEGORIES).
local _
_, Select, ns.GoToDisenchantingEntry = ns.BuildBrowserPanel("Disenchanting", {
    icon = "Interface/Icons/INV_Enchant_Disenchant",
    listLabel = "Known disenchanted items (click one to see what materials it's produced):",
    emptyListText = "(no disenchants recorded yet - go disenchant something)",
    emptyDetailText = "Select a disenchanted item from the list to see what materials you've gotten from it.",
    getIDs = GetIDs,
    getListLabel = GetListLabel,
    renderDetail = RenderDetail,
    isValidID = function(id) return ns.accountDB.disenchanting[id] ~= nil end,
})
