local ADDON_NAME, ns = ...

-- Retail (Midnight) replaced the old TradeSkillFrame API
-- (GetTradeSkillSelectionIndex/GetTradeSkillItemLink/GetTradeSkillNumMade/
-- GetTradeSkillLine) with C_TradeSkillUI. The craft-completion signal stays
-- the same as Classic Era - UNIT_SPELLCAST_SUCCEEDED for "player" still
-- fires the same way on retail (confirmed via other installed retail
-- addons still using it, e.g. TPerl_ArcaneBar, Dominos) - but which
-- recipe/item it refers to now has to be captured separately: hooking
-- C_TradeSkillUI.CraftRecipe(recipeID) records the recipe the player just
-- queued (same "still points at the recipe that was just made" idea as
-- the old GetTradeSkillSelectionIndex), then the completed craft's cast is
-- resolved back to that recipe's output item via
-- C_TradeSkillUI.GetRecipeSchematic(recipeID).outputItemID/.quantityMax
-- and the open profession's name via
-- C_TradeSkillUI.GetBaseProfessionInfo().professionName. Confirmed against
-- DataStore_Crafts's own retail-only code (DataStore_Crafts_Retail.lua),
-- the only installed addon found tracking crafted output this way.
-- TRADE_SKILL_SHOW/TRADE_SKILL_CLOSE (used here in place of the old
-- TradeSkillFrame:IsShown() check) are confirmed still fired by Blizzard
-- for the modern Professions UI too - same source.
--
-- Smelting is a special case: GetBaseProfessionInfo().professionName
-- reports "Mining" for it, since it's a Mining sub-skill sharing that
-- profession line (it doesn't actually gather ore itself, but the game
-- files it under Mining) - so per an explicit user request those items are
-- routed into the existing Mining tab instead (see ns.RecordSmelting in
-- Mining.lua) rather than creating a separate "Mining" entry here too.
--
-- Only recipes surfaced through C_TradeSkillUI are covered (Blacksmithing,
-- Alchemy, Engineering, Leatherworking, Tailoring, Cooking, and Mining's
-- Smelting). Enchanting applies an enchant to an existing item rather than
-- creating a new one, so "created items" doesn't apply uniformly there -
-- and isn't tracked here.
local tradeSkillWindowOpen = false
local currentCraftRecipeID = nil

hooksecurefunc(C_TradeSkillUI, "CraftRecipe", function(recipeID)
    currentCraftRecipeID = recipeID
end)

local function OnCraftSucceeded()
    if not tradeSkillWindowOpen then return end
    if not currentCraftRecipeID then return end

    local schematic = C_TradeSkillUI.GetRecipeSchematic(currentCraftRecipeID, false)
    local itemID = schematic and schematic.outputItemID
    if not itemID then return end

    local info = C_TradeSkillUI.GetBaseProfessionInfo()
    local profession = info and info.professionName
    if not profession then return end

    local link = select(2, C_Item.GetItemInfo(itemID))
    if not link then return end

    local quantity = schematic.quantityMax or 1

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
frame:RegisterEvent("TRADE_SKILL_SHOW")
frame:RegisterEvent("TRADE_SKILL_CLOSE")
frame:SetScript("OnEvent", function(self, event)
    if event == "TRADE_SKILL_SHOW" then
        tradeSkillWindowOpen = true
    elseif event == "TRADE_SKILL_CLOSE" then
        tradeSkillWindowOpen = false
        currentCraftRecipeID = nil
    else
        OnCraftSucceeded()
    end
end)

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
