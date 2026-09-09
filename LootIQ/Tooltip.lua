local ADDON_NAME, ns = ...

local function AddSection(tooltip, title, store, kills)
    local items = ns.SortedDrops(store)

    tooltip:AddLine(" ")
    tooltip:AddLine(title, 0.5, 0.8, 1)
    for i = 1, #items do
        local d = items[i]
        local pct = kills > 0 and (d.occurrences / kills * 100) or 0
        tooltip:AddLine(("  %s x%d  (%.0f%%)"):format(d.link, d.count, pct))
    end
end

-- Sums (price x count) across every known drop and skin, plus any coin
-- looted directly (entry.money, accumulated in Loot.lua), giving the
-- expected gold value of a single kill. Items with no known price (no AH
-- scan data and no Auctionator) contribute nothing, so this is a lower
-- bound rather than a true average when pricing is incomplete. Shared with
-- the Source Database panel (CreatureDatabase.lua).
function ns.GetAverageValuePerKill(entry)
    if entry.kills <= 0 then return nil end

    local total = entry.money or 0
    for _, drop in pairs(entry.drops) do
        local price = ns.GetItemPrice(drop.link)
        if price then total = total + price * drop.count end
    end
    for _, skin in pairs(entry.skins) do
        local price = ns.GetItemPrice(skin.link)
        if price then total = total + price * skin.count end
    end

    return total / entry.kills
end

-- Exposed (not local) so BrowserPanel.lua can show this same content on a
-- hover tooltip for a creature/vendor that isn't a live unit at all (a
-- Source Database list row, or the model preview shared with the Item
-- Database) - there's no UnitGUID to hook OnTooltipSetUnit with there, so
-- those callers build the tooltip's header line themselves (the name
-- Blizzard would normally add first for a live unit) and then call this to
-- append the same kills/drops/skins/value lines used everywhere else.
function ns.AddDropLines(tooltip, creatureID)
    local entry = ns.accountDB.creatures[creatureID]
    -- entry.kills is tracked for every PARTY_KILL regardless of whether
    -- anything was ever looted from it (see Loot.lua's RecordKill), so this
    -- shows the kill count for any tracked kill - not just ones that also
    -- happened to drop something, which this used to require before even
    -- printing the count (a creature with 0 known drops/skins got no
    -- tooltip line at all, even though its kill count was accurate).
    if not entry or entry.kills <= 0 then return end

    tooltip:AddLine(" ")
    tooltip:AddLine(("LootIQ - %d kills tracked:"):format(entry.kills), 0.5, 0.8, 1)

    if next(entry.drops) ~= nil then
        AddSection(tooltip, "Known drops:", entry.drops, entry.kills)
    end
    if next(entry.skins) ~= nil then
        AddSection(tooltip, "Skinning:", entry.skins, entry.kills)
    end

    local avgValue = ns.GetAverageValuePerKill(entry)
    if avgValue and avgValue > 0 then
        tooltip:AddLine(" ")
        tooltip:AddLine(("Average value per kill: %s"):format(ns.FormatPrice(math.floor(avgValue))), 0.5, 0.8, 1)
    end

    tooltip:Show()
end

local MAX_SOURCE_LINES = 12

-- Two per line ("Name (X%), Name (Y%)"), highest drop rate first, capped
-- to the top MAX_SOURCE_LINES overall so an item with many known sources
-- doesn't take over the tooltip.
local function AddSourceLine(tooltip, key)
    local sources = ns.GetRankedItemSources(key)
    if not sources then return end

    tooltip:AddLine(" ")
    tooltip:AddLine("LootIQ sources:", 0.5, 0.8, 1)

    local shown = math.min(#sources, MAX_SOURCE_LINES)
    for i = 1, shown, 2 do
        local first = ("%s (%.0f%%)"):format(sources[i].name, sources[i].pct)
        local second = sources[i + 1]
        local line = second and ("%s, %s (%.0f%%)"):format(first, second.name, second.pct) or first
        tooltip:AddLine("  " .. line)
    end
    tooltip:Show()
end

GameTooltip:HookScript("OnTooltipSetItem", function(tooltip)
    if not ns.accountDB then return end

    local _, link = tooltip:GetItem()
    -- ns.GetItemKey (not a bare itemID) so a random-suffix item looks up
    -- its own specific roll's entry rather than whichever roll happened to
    -- be recorded under the bare itemID (see Core.lua's ns.GetItemKey).
    local key = link and ns.GetItemKey(link)
    if not key then return end

    -- Deferred for the same reason as the unit-tooltip hook below: run
    -- after other tooltip addons finish resizing so these lines don't get
    -- clipped.
    C_Timer.After(0, function()
        if not tooltip:IsShown() then return end
        local _, currentLink = tooltip:GetItem()
        local currentKey = currentLink and ns.GetItemKey(currentLink)
        if currentKey ~= key then return end
        AddSourceLine(tooltip, key)
    end)
end)

GameTooltip:HookScript("OnTooltipSetUnit", function(tooltip)
    if not ns.accountDB then return end

    local _, unit = tooltip:GetUnit()
    if not unit then return end
    local guid = UnitGUID(unit)
    if not guid then return end

    local unitType, _, _, _, _, creatureID = strsplit("-", guid)
    if unitType ~= "Creature" and unitType ~= "Vehicle" then return end
    creatureID = tonumber(creatureID)

    -- Deferred to the next frame tick so this runs after other tooltip
    -- addons (e.g. TipTac) finish their own OnTooltipSetUnit pass and
    -- resize the tooltip. Adding lines synchronously here can get them
    -- clipped if something else recalculates the tooltip's size right
    -- after this fires, since that resize happens after ours.
    C_Timer.After(0, function()
        if not tooltip:IsShown() then return end
        local _, currentUnit = tooltip:GetUnit()
        if not currentUnit or UnitGUID(currentUnit) ~= guid then return end
        ns.AddDropLines(tooltip, creatureID)
    end)
end)

local function AddGatherLines(tooltip, headerFormat, dbKey, storeField, getTotal, zone)
    local entry = ns.accountDB[dbKey][zone]
    if not entry or not next(entry[storeField]) then return end

    local total = getTotal(zone)
    local items = ns.SortedDrops(entry[storeField])
    tooltip:AddLine(" ")
    tooltip:AddLine(headerFormat:format(total, zone), 0.5, 0.8, 1)
    for i = 1, #items do
        local d = items[i]
        local pct = total > 0 and (d.occurrences / total * 100) or 0
        tooltip:AddLine(("  %s x%d  (%.0f%%)"):format(d.link, d.count, pct))
    end
    tooltip:Show()
end

-- There's no dedicated event for "this tooltip is the player's bobber/
-- mining node/herb node" (each is a world object, not a unit or an item),
-- so this infers it the same way for all three: getZone() (from
-- Fishing.lua/Mining.lua/Herbalism.lua) is only non-nil for a while after
-- casting the matching gathering skill, and such a tooltip carries no
-- unit, item, or spell data - just a plain object name. A false positive
-- here (mousing over some other plain-named object while that fallback
-- window happens to still be open) just shows an extra, harmless list, so
-- this doesn't try to be any more precise than that.
local function RegisterGatherTooltip(getZone, dbKey, storeField, getTotal, headerFormat)
    GameTooltip:HookScript("OnShow", function(tooltip)
        if not ns.accountDB then return end
        local zone = getZone()
        if not zone then return end
        if tooltip:GetUnit() or tooltip:GetItem() or tooltip:GetSpell() then return end

        -- Deferred for the same reason as the hooks above - runs after
        -- other tooltip addons finish resizing so these lines don't get
        -- clipped.
        C_Timer.After(0, function()
            if not tooltip:IsShown() then return end
            if tooltip:GetUnit() or tooltip:GetItem() or tooltip:GetSpell() then return end
            AddGatherLines(tooltip, headerFormat, dbKey, storeField, getTotal, zone)
        end)
    end)
end

RegisterGatherTooltip(ns.GetFishingZone, "fishing", "fish", ns.GetTotalFishingCatches,
    "Known catches (LootIQ) - %d caught in %s:")
RegisterGatherTooltip(ns.GetMiningZone, "mining", "ore", ns.GetTotalMiningHarvests,
    "Known harvests (LootIQ) - %d harvested in %s:")
RegisterGatherTooltip(ns.GetHerbalismZone, "herbalism", "herbs", ns.GetTotalHerbalismHarvests,
    "Known harvests (LootIQ) - %d harvested in %s:")
