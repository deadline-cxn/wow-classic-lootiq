local ADDON_NAME, ns = ...

-- Items are keyed by ns.GetItemKey (Core.lua) rather than a bare itemID -
-- a random-suffix item ("of the Monkey" vs. "of the Whale") gets a distinct
-- key per roll instead of merging every variant under one entry, so a
-- "key" here can be a plain number (no suffix) or an "itemID:suffix"
-- string. GetItemInfo can't take that string form directly, so name/icon
-- resolution always goes through item.link (kept up to date on every
-- record - see Loot.lua's GetOrCreateItemEntry) rather than the key itself.
--
-- Falls back to the stored hyperlink (colored markup and all) when
-- GetItemInfo hasn't cached the name yet - virtually never happens here,
-- since recording a drop already required a successful GetItemInfo call,
-- but it keeps sorting/display from erroring on a nil name.
local function GetDisplayName(key, item)
    return (item.link and GetItemInfo(item.link)) or item.link or ("item:" .. tostring(key))
end

local function GetIDs()
    local items = ns.accountDB.items
    local ids = {}
    for key in pairs(items) do
        table.insert(ids, key)
    end
    table.sort(ids, function(a, b)
        return GetDisplayName(a, items[a]) < GetDisplayName(b, items[b])
    end)
    return ids
end

local function GetRowItemLink(key)
    local item = ns.accountDB.items[key]
    local sourceLink = item and item.link
    local _, link, _, _, _, _, _, _, _, texture = GetItemInfo(sourceLink or ns.GetBaseItemID(key))
    return link or sourceLink, texture
end

local function GetListLabel(key)
    local item = ns.accountDB.items[key]
    local sourceCount = 0
    for _ in pairs(item.sources) do
        sourceCount = sourceCount + 1
    end
    for _ in pairs(item.fishingSources or {}) do
        sourceCount = sourceCount + 1
    end
    for _ in pairs(item.miningSources or {}) do
        sourceCount = sourceCount + 1
    end
    for _ in pairs(item.herbalismSources or {}) do
        sourceCount = sourceCount + 1
    end
    for _ in pairs(item.craftingSources or {}) do
        sourceCount = sourceCount + 1
    end
    for _ in pairs(item.chestsSources or {}) do
        sourceCount = sourceCount + 1
    end
    return ("%s (%d source%s)"):format(GetDisplayName(key, item), sourceCount, sourceCount == 1 and "" or "s")
end

local function RenderDetail(key, detail)
    local item = ns.accountDB.items[key]
    if not item then return end

    local _, link, _, _, _, _, _, _, _, texture = GetItemInfo(item.link)
    link = link or item.link
    detail:AddRow(link, "GameFontNormalLarge", nil, texture or "Interface/Icons/INV_Misc_QuestionMark", link)

    local sources = ns.GetRankedItemSources(key)
    if not sources then
        detail:AddRow("No known sources yet.")
        return
    end

    detail:AddRow("Sources:", "GameFontNormal", { 0.5, 0.8, 1 })
    for _, source in ipairs(sources) do
        -- A vendor source shows its own sell-to-player price alongside the
        -- generic sell/AH prices instead of a percentage (there's no
        -- "chance" to buy something from a vendor - see
        -- ns.GetRankedItemSources); a drop/gather source keeps its
        -- percentage and adds just the generic sell/AH prices. All price
        -- figures are full copper precision, not affected by the loot bar's
        -- "show copper" setting.
        local text
        if source.price then
            text = ("  %s - %s"):format(source.name, ns.FormatSellVendorAndAHPrice(source.price, link))
        else
            text = ("  %s (%.0f%%) - %s"):format(source.name, source.pct, ns.FormatSellAndAHPrice(link))
        end
        if source.creatureID then
            -- Blue like a hyperlink, to read as clickable - jumps to that
            -- creature's or vendor's own Source Database entry.
            detail:AddRow(text, nil, { 0.4, 0.7, 1 }, nil, nil,
                function() ns.GoToSourceDatabaseEntry(source.creatureID) end)
        elseif source.onClick then
            -- Same idea for a fishing/mining/herbalism source - jumps to
            -- that zone's entry in the matching gathering panel.
            detail:AddRow(text, nil, { 0.4, 0.7, 1 }, nil, nil, source.onClick)
        else
            detail:AddRow(text)
        end
    end
end

-- Exposed so any item listed elsewhere (a creature's drops/skins, a
-- gathering zone's catches/harvests, the loot bar) can jump straight to
-- that item's own entry here (see BrowserPanel.lua's AddSection and
-- Bar.lua).
local _
_, _, ns.GoToItemDatabaseEntry = ns.BuildBrowserPanel("Item Database", {
    icon = "Interface/Icons/INV_Misc_Bag_08",
    listLabel = "Known items (click one to see what drops it):",
    emptyListText = "(no items recorded yet)",
    emptyDetailText = "Select an item from the list to see its known sources.",
    getIDs = GetIDs,
    getListLabel = GetListLabel,
    getRowItemLink = GetRowItemLink,
    renderDetail = RenderDetail,
    isValidID = function(id) return ns.accountDB.items[id] ~= nil end,
    showModel = true,
    searchable = true,
    -- Wrapped rather than passed directly (`= ns.GetPrimaryItemSource`):
    -- this file loads before Loot.lua in the .toc, so that field wouldn't
    -- exist yet at the point a direct assignment would capture it. A
    -- closure defers the lookup to when it's actually called, well after
    -- every file has loaded. Falls back to that profession's icon for an
    -- item with no creature source at all (only ever fished/mined/
    -- gathered) - there's no model to preview for "caught/harvested in a
    -- zone", so an icon stands in for it instead.
    getModelCreatureID = function(key)
        local creatureID = ns.GetPrimaryItemSource(key)
        if creatureID then return creatureID end

        local item = ns.accountDB.items[key]
        if not item then return nil end
        if next(item.fishingSources or {}) then
            return nil, "Interface/Icons/Trade_Fishing"
        elseif next(item.miningSources or {}) then
            return nil, "Interface/Icons/Trade_Mining"
        elseif next(item.herbalismSources or {}) then
            return nil, "Interface/Icons/Trade_Herbalism"
        elseif next(item.craftingSources or {}) then
            return nil, "Interface/Icons/Trade_BlackSmithing"
        elseif next(item.chestsSources or {}) then
            return nil, "Interface/Icons/INV_Box_01"
        end
        return nil
    end,
})
