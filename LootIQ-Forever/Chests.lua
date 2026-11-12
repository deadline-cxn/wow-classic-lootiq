local ADDON_NAME, ns = ...

-- Chests, crates, and other lootable containers - both GameObjects found
-- in the world (a chest/crate - see Loot.lua's OnLootOpened/
-- GetLootObjectID, which routes a loot window here instead of
-- RecordCreatureDrop whenever its loot source GUID says "GameObject") and
-- openable items in the player's own bags (a Clam Shell, a lockbox - see
-- Loot.lua's OnContainerItemOpened/GetRecentlyOpenedContainerItem, which
-- watches C_Container.UseContainerItem for an item flagged hasLoot and
-- correlates it with the loot window that follows). Keyed by the world
-- container's template ID (a plain number - shared by every spawned
-- instance of that same container type, e.g. every "Locked Chest", exactly
-- like creatureID identifies a type of creature rather than one specific
-- spawn) OR, for a bag item, a string "item:<itemID>" - the two key shapes
-- can never collide since one is always a number and the other always a
-- string, so both live in the same ns.accountDB.chests table and this same
-- panel without needing separate identity spaces.
local Select -- assigned once ns.BuildBrowserPanel returns; the remove button needs it to refresh the detail pane

-- name is optional and only used to fill in (or backfill) entry.name if
-- it's still unset - a world container resolves its name via Questie (see
-- Loot.lua, which may not have an answer yet), while a bag item's name is
-- already known for certain the moment it's used (it's a real item in the
-- player's own inventory), so each caller resolves its own name rather
-- than this function guessing how to from the key's shape.
local function GetOrCreateChest(key, name)
    local chests = ns.accountDB.chests
    local entry = chests[key]
    if not entry then
        entry = { opens = 0, items = {} }
        chests[key] = entry
    end
    if name and not entry.name then entry.name = name end
    return entry
end

-- opens is a real independent counter (like a creature's kills), not summed
-- from item occurrences - a single opening can drop 0, 1, or several items,
-- so it can't be derived from the item list the way Fishing's catch total
-- can (see that file's double-counting fix for why that distinction
-- matters).
function ns.RecordChestOpen(key, name)
    local entry = GetOrCreateChest(key, name)
    entry.opens = entry.opens + 1
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

-- itemKey (an ns.GetItemKey result) here is distinct from this function's
-- own `key` param (the CHEST's identity - a world objectID or "item:N" bag
-- item) - two unrelated identity keys in play at once, one for which
-- container this is, one for which specific random-suffix roll the looted
-- item is.
function ns.RecordChestLoot(key, link, quantity)
    local itemKey = ns.GetItemKey(link)
    if not itemKey then return end

    local entry = GetOrCreateChest(key)
    RecordDropInto(entry.items, itemKey, link, quantity)
    ns.RecordGatheringItemSource("chests", itemKey, link, key)
end

function ns.GetChestOpens(key)
    local entry = ns.accountDB.chests[key]
    return entry and entry.opens or 0
end

-- Used anywhere a chest's plain name is shown (this panel, and an item's
-- ranked sources via Loot.lua's GATHERING_CATEGORIES) - see
-- ns.GetCreatureDisplayName for the same idea applied to creatures.
function ns.GetChestDisplayName(key)
    local entry = ns.accountDB.chests[key]
    return (entry and entry.name) or ("Unknown container (" .. tostring(key) .. ")")
end

-- Unlike Mining.lua/Herbalism.lua's RemoveHarvest, this never deletes the
-- whole chest entry even if its item list ends up empty - a chest's
-- identity (name, opens count) is independent of what's currently in its
-- drop list, same as a creature entry with kills but no known drops still
-- exists in the Source Database.
local function RemoveChestItem(key, itemKey)
    local entry = ns.accountDB.chests[key]
    if entry then entry.items[itemKey] = nil end
    ns.RemoveGatheringItemSource("chests", itemKey, key)
    Select(key)
end

local function GetIDs()
    local ids = {}
    for key in pairs(ns.accountDB.chests) do
        table.insert(ids, key)
    end
    table.sort(ids, function(a, b)
        return ns.GetChestDisplayName(a) < ns.GetChestDisplayName(b)
    end)
    return ids
end

local function GetListLabel(key)
    local entry = ns.accountDB.chests[key]
    return ("%s (%d open%s)"):format(ns.GetChestDisplayName(key), entry.opens, entry.opens == 1 and "" or "s")
end

local function RenderDetail(key, detail)
    local entry = ns.accountDB.chests[key]
    if not entry then return end

    detail:AddRow(ns.GetChestDisplayName(key), "GameFontNormalLarge")
    detail:AddRow(("%d open%s tracked"):format(entry.opens, entry.opens == 1 and "" or "s"))
    detail:AddSection("Known contents:", entry.items, entry.opens,
        function(itemID) RemoveChestItem(key, itemID) end)
end

-- Exposed so a "Chests: Container Name" source row in the Item Database can
-- jump straight to that container's own entry here (see ItemDatabase.lua
-- via Loot.lua's GATHERING_CATEGORIES).
local _
_, Select, ns.GoToChestEntry = ns.BuildBrowserPanel("Chests", {
    icon = "Interface/Icons/INV_Box_01",
    listLabel = "Known chests, crates, and containers (click one to see what you've gotten from it):",
    emptyListText = "(no chests or containers recorded yet)",
    emptyDetailText = "Select a chest or container from the list to see what you've gotten from it.",
    getIDs = GetIDs,
    getListLabel = GetListLabel,
    renderDetail = RenderDetail,
    isValidID = function(id) return ns.accountDB.chests[id] ~= nil end,
})
