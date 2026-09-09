local ADDON_NAME, ns = ...

-- Crafting produces its item directly through the trade skill window's own
-- API - unlike fishing/mining/herbalism, there's no target, no zone, and no
-- need to infer anything from a loot event or chat message at all: when a
-- craft completes, GetTradeSkillSelectionIndex() still points at the
-- recipe that was just made, and GetTradeSkillItemLink/GetTradeSkillNumMade/
-- GetTradeSkillLine give the exact output item, quantity, and profession
-- name directly. Recorded per PROFESSION NAME (e.g. "Blacksmithing",
-- "Alchemy") - the same shape as a gathering zone, just substituting
-- "which profession made this" for "which zone was I in".
--
-- Smelting is a special case: GetTradeSkillLine() reports "Mining" for it,
-- since it's a Mining sub-skill sharing that skill line (it doesn't
-- actually gather ore itself, but the game files it under Mining) - so per
-- an explicit user request those items are routed into the existing Mining
-- tab instead (see ns.RecordSmelting in Mining.lua) rather than creating a
-- separate "Mining" entry here too.
--
-- Only TradeSkillFrame professions are covered (Blacksmithing, Alchemy,
-- Engineering, Leatherworking, Tailoring, Cooking, First Aid, and Mining's
-- Smelting). Enchanting uses a different frame (CraftFrame) with a
-- different, less consistent API - most of its recipes enchant an existing
-- item rather than creating a new one, so "created items" doesn't apply
-- uniformly there - and isn't tracked here.
local function OnCraftSucceeded()
    if not (TradeSkillFrame and TradeSkillFrame:IsShown()) then return end

    local recipeIndex = GetTradeSkillSelectionIndex()
    if not recipeIndex or recipeIndex <= 0 then return end

    local link = GetTradeSkillItemLink(recipeIndex)
    local profession = GetTradeSkillLine()
    if not (link and profession) then return end

    local quantity = GetTradeSkillNumMade(recipeIndex) or 1

    if profession == "Mining" then
        ns.RecordSmelting(link, quantity)
        ns.DebugPrint("recorded a smelted item: %s x%d.", link, quantity)
    else
        ns.RecordCraft(profession, link, quantity)
        ns.DebugPrint("recorded a crafted item (%s): %s x%d.", profession, link, quantity)
    end
end

local frame = CreateFrame("Frame")
frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
frame:SetScript("OnEvent", OnCraftSucceeded)

local function GetOrCreateProfession(profession)
    local professions = ns.accountDB.crafting
    local entry = professions[profession]
    if not entry then
        entry = { items = {} }
        professions[profession] = entry
    end
    return entry
end

-- Tallied from the items list itself rather than kept as its own counter -
-- see Fishing.lua's ns.GetTotalFishingCatches for why (a separately-kept
-- counter drifted out of sync with the list it was supposed to describe).
function ns.GetTotalCraftedCount(profession)
    local entry = ns.accountDB.crafting[profession]
    if not entry then return 0 end

    local total = 0
    for _, drop in pairs(entry.items) do
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

function ns.RecordCraft(profession, link, quantity)
    local key = ns.GetItemKey(link)
    if not key then return end
    RecordDropInto(GetOrCreateProfession(profession).items, key, link, quantity)
    ns.RecordGatheringItemSource("crafting", key, link, profession)
end

local function GetIDs()
    local professions = {}
    for profession in pairs(ns.accountDB.crafting) do
        table.insert(professions, profession)
    end
    table.sort(professions)
    return professions
end

local function GetListLabel(profession)
    local entry = ns.accountDB.crafting[profession]
    local types = 0
    for _ in pairs(entry.items) do types = types + 1 end
    local crafted = ns.GetTotalCraftedCount(profession)
    return ("%s (%d crafted, %d type%s)"):format(profession, crafted, types, types == 1 and "" or "s")
end

local Select -- assigned once ns.BuildBrowserPanel returns; the remove button needs it to refresh the detail pane

-- Lets the player manually correct a mis-attributed item, same as Mining's
-- and Herbalism's remove button. Removing the last item for a profession
-- drops that profession's entry entirely rather than leaving an empty
-- "(0 crafted, 0 types)" stub behind.
local function RemoveCraft(profession, itemID)
    local entry = ns.accountDB.crafting[profession]
    if not entry then return end

    entry.items[itemID] = nil
    ns.RemoveGatheringItemSource("crafting", itemID, profession)

    if next(entry.items) then
        Select(profession)
    else
        ns.accountDB.crafting[profession] = nil
        Select(nil)
    end
end

local function RenderDetail(profession, detail)
    local entry = ns.accountDB.crafting[profession]
    if not entry then return end

    local crafted = ns.GetTotalCraftedCount(profession)
    detail:AddRow(profession, "GameFontNormalLarge")
    detail:AddRow(("%d item%s crafted"):format(crafted, crafted == 1 and "" or "s"))
    detail:AddSection("Types:", entry.items, crafted, function(itemID) RemoveCraft(profession, itemID) end)
end

-- Exposed so a "Crafting: ProfessionName" source row in the Item Database
-- can jump straight to that profession's own entry here (see
-- ItemDatabase.lua via Loot.lua's GATHERING_CATEGORIES).
local _
_, Select, ns.GoToCraftingEntry = ns.BuildBrowserPanel("Crafting", {
    icon = "Interface/Icons/Trade_BlackSmithing",
    listLabel = "Known professions (click one to see what you've crafted):",
    emptyListText = "(no crafted items recorded yet - go craft something)",
    emptyDetailText = "Select a profession from the list to see its known crafts.",
    getIDs = GetIDs,
    getListLabel = GetListLabel,
    renderDetail = RenderDetail,
    isValidID = function(id) return ns.accountDB.crafting[id] ~= nil end,
})
