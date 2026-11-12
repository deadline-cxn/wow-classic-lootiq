local ADDON_NAME, ns = ...

-- "Source Database" covers both creatures (kills/drops/skins) and vendors
-- (sells) - a vendor is just a creature whose window the player opened
-- instead of fighting, and shares the exact same ns.accountDB.creatures
-- entry/identity (see Loot.lua's GetOrCreateCreature and its MERCHANT_SHOW
-- handler), so one list and one entry shape covers both without any
-- special-casing here beyond what a given entry actually has recorded.
--
-- The debug-message toggle and clear-database button that used to live
-- here have moved to the main LootIQ panel, under the slash command list -
-- see Options.lua.

local function GetIDs()
    local ids = {}
    for creatureID in pairs(ns.accountDB.creatures) do
        table.insert(ids, creatureID)
    end
    table.sort(ids, function(a, b)
        return ns.GetCreatureDisplayName(a) < ns.GetCreatureDisplayName(b)
    end)
    return ids
end

local function GetListLabel(creatureID)
    local entry = ns.accountDB.creatures[creatureID]
    local name = ns.GetCreatureDisplayName(creatureID)
    -- entry.sells can be nil for a creature entry saved before this field
    -- existed (i.e. almost every pre-existing entry) - reading it
    -- unguarded here previously threw a Lua error on the first such entry
    -- encountered while building the list, silently truncating the rest of
    -- it (this is what caused "only the first entry shows up").
    if entry.kills > 0 then
        return ("%s (%d kills)"):format(name, entry.kills)
    elseif next(entry.sells or {}) then
        return ("%s (vendor)"):format(name)
    end
    return name
end

local function RenderDetail(creatureID, detail)
    local entry = ns.accountDB.creatures[creatureID]
    if not entry then return end

    detail:AddRow(ns.GetCreatureDisplayName(creatureID), "GameFontNormalLarge")
    if entry.kills > 0 then
        detail:AddRow(("%d kills tracked"):format(entry.kills))
    end
    detail:AddSection("Known drops:", entry.drops, entry.kills)
    detail:AddSection("Skinning:", entry.skins, entry.kills)
    detail:AddVendorSells("Sells:", entry.sells or {})

    local avgValue = ns.GetAverageValuePerKill(entry)
    if avgValue and avgValue > 0 then
        detail:AddRow(("Average value per kill: %s"):format(ns.FormatPrice(math.floor(avgValue))),
            "GameFontNormal", { 0.5, 0.8, 1 })
    end
end

local _
-- Exposed so a source row in the Item Database can jump straight to that
-- creature's or vendor's own entry here (see ItemDatabase.lua).
_, _, ns.GoToSourceDatabaseEntry = ns.BuildBrowserPanel("Source Database", {
    icon = "Interface/Icons/INV_Misc_Bone_Skull_01",
    listLabel = "Known sources (click one to see what you've gotten from it):",
    emptyListText = "(no sources recorded yet)",
    emptyDetailText = "Select a source from the list to see what you've gotten from it.",
    getIDs = GetIDs,
    getListLabel = GetListLabel,
    renderDetail = RenderDetail,
    isValidID = function(id) return ns.accountDB.creatures[id] ~= nil end,
    showModel = true,
    searchable = true,
    rowCreatureTooltip = true,
})
