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

-- Added synchronously, NOT deferred via C_Timer like the unit-tooltip hook
-- below. Both OnTooltipSetItem and TooltipDataProcessor's post-call refire
-- every frame for a bag/vendor item's tooltip (to keep stack counts/
-- charges current), clearing and rebuilding the base tooltip each time. A
-- deferred (next-frame) add here used to land one frame behind that
-- per-frame rebuild, so the tooltip visibly resized smaller-then-bigger on
-- every single frame - that oscillation was the reported flicker. Adding
-- in the same frame as the rebuild avoids that; a plain link/world
-- tooltip only fires this once anyway, so there's no clipping race to
-- defer around here.
local function OnItemTooltip(tooltip)
    if not ns.accountDB then return end

    local _, link = tooltip:GetItem()
    -- ns.GetItemKey (not a bare itemID) so a random-suffix item looks up
    -- its own specific roll's entry rather than whichever roll happened to
    -- be recorded under the bare itemID (see Core.lua's ns.GetItemKey).
    local key = link and ns.GetItemKey(link)
    if not key then return end

    AddSourceLine(tooltip, key)
end

-- Retail (Midnight) can populate an item tooltip asynchronously in a way
-- OnTooltipSetItem doesn't reliably fire for - TooltipDataProcessor is the
-- modern replacement, confirmed via Auctionator's own Source/Tooltips/
-- Hooks.lua, which branches on exactly this (TooltipDataProcessor and
-- C_TooltipInfo both present) and falls back to OnTooltipSetItem only when
-- they're absent. This addon's client is retail-only, so the fallback
-- branch below is dead code here, but kept for parity with that evidence
-- rather than assumed away.
if TooltipDataProcessor and C_TooltipInfo then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip)
        if tooltip == GameTooltip then OnItemTooltip(tooltip) end
    end)
else
    GameTooltip:HookScript("OnTooltipSetItem", OnItemTooltip)
end

-- The "World Cursor" tooltip (hovering a unit directly in the 3D world,
-- rather than a frame like a nameplate/unitframe - the common case while
-- checking out/fighting a creature) makes ANY attempt to read unit
-- identity (UnitGUID, for any unit token - tooltip:GetUnit()'s own,
-- "mouseover", even "target") come back secret, confirmed via extensive
-- diagnostic testing across every retry strategy tried (same tick, next
-- frame, a pre-existing named function instead of a fresh closure) -
-- including reading UnitGUID("target") from Loot.lua's own
-- PLAYER_TARGET_CHANGED handler (a completely separate code path,
-- unrelated to hovering), which ALSO came back secret. There may be no
-- addon-readable GUID path for live unit identity on this client at all
-- right now.
--
-- Fix (per user's own suggestion): don't read identity at all - read the
-- creature's NAME directly off the tooltip's own already-rendered text.
-- Plain UI text isn't protected/secret data, it's exactly what the player
-- already sees on screen, and ns.accountDB.creatures already stores each
-- creature's last-known display name. GameTooltipTextLeft1 is the
-- standard FontString region Blizzard's own tooltip uses for a unit's
-- name line - reading `_G[frameName.."TextLeft1"]:GetText()` is a
-- long-standing, widely-used addon technique for exactly this (no
-- dedicated API exists to read a tooltip's own rendered lines back).
-- Trades exact identity for name-matching: two different creatureIDs
-- that happen to share a display name (a generic mob name reused across
-- several distinct spawns/levels, not uncommon in WoW) would show
-- whichever one FindCreatureIDByName finds first, merging their data in
-- this display only - an acceptable approximation given there's no
-- longer any identity signal more precise than the name to go on. This
-- ALSO works for any hover now, not just your own current target (an
-- actual improvement over the target-cache approach tried first) - the
-- name is shown regardless of whether the creature is targeted.
local function GetTooltipUnitName(tooltip)
    local frameName = tooltip:GetName()
    local textLeft1 = frameName and _G[frameName .. "TextLeft1"]
    return textLeft1 and textLeft1:GetText()
end

local function FindCreatureIDByName(name)
    if not name then return nil end
    for creatureID, entry in pairs(ns.accountDB.creatures) do
        if entry.name == name then return creatureID end
    end
    return nil
end

local function OnUnitTooltip(tooltip)
    if not ns.accountDB then return end

    -- Deferred to the next frame tick so this runs after other tooltip
    -- addons (e.g. TipTac) finish their own OnTooltipSetUnit pass and
    -- resize the tooltip - also ensures the name text (set this same
    -- frame by Blizzard's own tooltip rebuild) is definitely already
    -- rendered by the time it's read. Adding lines synchronously here can
    -- get them clipped if something else recalculates the tooltip's size
    -- right after this fires.
    C_Timer.After(0, function()
        if not tooltip:IsShown() then return end
        local creatureID = FindCreatureIDByName(GetTooltipUnitName(tooltip))
        if not creatureID then return end
        ns.AddDropLines(tooltip, creatureID)
    end)
end

-- Same TooltipDataProcessor requirement as the item hook above - retail
-- removed the "OnTooltipSetUnit" virtual script from GameTooltip entirely
-- (HookScript on it now errors: "bad argument #2 to HookScript", confirmed
-- in-game on this client), not just made it unreliable. Prat-3.0's own
-- AltNames.lua module hits this exact fork (TooltipDataProcessor present ->
-- Enum.TooltipDataType.Unit; absent -> the old HookScript, which it only
-- uses via SecureHookScript on non-retail).
if TooltipDataProcessor and C_TooltipInfo then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip)
        if tooltip == GameTooltip then OnUnitTooltip(tooltip) end
    end)
else
    GameTooltip:HookScript("OnTooltipSetUnit", OnUnitTooltip)
end

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
