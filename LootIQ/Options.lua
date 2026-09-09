local ADDON_NAME, ns = ...

local panel = CreateFrame("Frame")
panel.name = "LootIQ"

local category = Settings.RegisterCanvasLayoutCategory(panel, "LootIQ")
Settings.RegisterAddOnCategory(category)
ns.OptionsCategoryID = category:GetID()
ns.OptionsCategory = category
table.insert(ns.SettingsPanels, { name = "LootIQ", id = ns.OptionsCategoryID, icon = "Interface/Icons/INV_Misc_Wrench_01" })

local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("LootIQ")

local credits = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
credits:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -20)
credits:SetJustifyH("LEFT")
credits:SetText(table.concat({
    "LootIQ by Deadline",
    "Miracley / Dardel of <Wipe Team Six> guild on Mankrik",
    "",
    "Slash commands (/lootiq):",
    "  show / hide - show or hide the loot bar",
    "  minimize / expand - collapse the loot bar to an icon, or restore it",
    "  reset - clear the current loot bar session",
    "  clearcreatures - wipe the creature drop/skinning database",
    "  options - open this options window",
    "  scan - scan the auction house (must already be open)",
    "  debug - print recorded drop data for your current target",
    "  debugall - list every creature recorded, with kill/item counts",
    "  itemcheck <shift-click an item> - print that item's raw type info",
}, "\n"))

-- The auction-scan trigger lives on a button attached to the Auction House
-- window itself (see AuctionScan.lua) - opening this settings panel while
-- at the AH closes it, since Blizzard treats them as mutually exclusive.
--
-- The auto-vendor toggle lives in the Always Vendor List panel, next to
-- the list it actually controls - see OptionsLists.lua.

-- Thin divider between the slash command list above and the debug/clear
-- controls below, which act on the whole database rather than any one
-- slash command.
local divider = panel:CreateTexture(nil, "ARTWORK")
divider:SetPoint("TOPLEFT", credits, "BOTTOMLEFT", 0, -12)
divider:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
divider:SetHeight(1)
divider:SetColorTexture(1, 1, 1, 0.2)

local debugCheckbox = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
debugCheckbox:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, -12)
debugCheckbox.Text:SetText("Show loot-attribution debug messages in chat")
debugCheckbox:SetScript("OnClick", function(self)
    ns.db.debugMessages = self:GetChecked()
end)

-- Wipes the same ns.accountDB.creatures database as the Source Database
-- panel's browser, so any entry selected there goes stale - clearing it
-- through ns.OptionsRefreshers (the same list Core.lua runs through once at
-- load) lets that panel notice via its isValidID check instead of reaching
-- into its private Select function.
local clearSourcesButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
clearSourcesButton:SetSize(180, 22)
clearSourcesButton:SetPoint("TOPLEFT", debugCheckbox, "BOTTOMLEFT", 0, -12)
clearSourcesButton:SetText("Clear source database")
clearSourcesButton:SetScript("OnClick", function()
    ns.ClearCreatureData()
    print("|cff33ff99LootIQ|r: source database cleared.")
    for _, refresh in ipairs(ns.OptionsRefreshers) do
        refresh()
    end
end)

----------------------------------------------------------------------------
-- Loot Bar Panel: everything about what the loot bar shows and how it's
-- laid out lives in this subcategory.
----------------------------------------------------------------------------

local barPanel = CreateFrame("Frame")
barPanel.name = "Loot Bar Panel"

local barTitle = barPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
barTitle:SetPoint("TOPLEFT", 16, -16)
barTitle:SetText("Loot Bar")

local autoAddCheckbox = CreateFrame("CheckButton", nil, barPanel, "UICheckButtonTemplate")
autoAddCheckbox:SetPoint("TOPLEFT", barTitle, "BOTTOMLEFT", 0, -20)
autoAddCheckbox.Text:SetText("Automatically add looted items to the loot bar")
autoAddCheckbox:SetScript("OnClick", function(self)
    ns.db.autoAddLoot = self:GetChecked()
end)

local qualityLabel = barPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
qualityLabel:SetPoint("TOPLEFT", autoAddCheckbox, "BOTTOMLEFT", 0, -16)
qualityLabel:SetText("Minimum item quality to show on the loot bar")

local qualityDropdown = CreateFrame("Frame", "LootIQQualityDropdown", barPanel, "UIDropDownMenuTemplate")
qualityDropdown:SetPoint("TOPLEFT", qualityLabel, "BOTTOMLEFT", -16, -8)
UIDropDownMenu_SetWidth(qualityDropdown, 150)

-- Shared with the Always Vendor List panel's auto-learn quality dropdown
-- (see OptionsLists.lua).
function ns.QualityText(quality)
    local color = ITEM_QUALITY_COLORS[quality]
    local name = _G["ITEM_QUALITY" .. quality .. "_DESC"] or tostring(quality)
    return color and (color.hex .. name .. "|r") or name
end
local QualityText = ns.QualityText

local function OnQualitySelect(self)
    ns.db.minQuality = self.value
    UIDropDownMenu_SetSelectedValue(qualityDropdown, self.value)
    UIDropDownMenu_SetText(qualityDropdown, QualityText(self.value))
    CloseDropDownMenus()
end

UIDropDownMenu_Initialize(qualityDropdown, function()
    for quality = 0, 5 do
        local info = UIDropDownMenu_CreateInfo()
        info.text = QualityText(quality)
        info.value = quality
        info.func = OnQualitySelect
        info.checked = (ns.db and ns.db.minQuality == quality)
        UIDropDownMenu_AddButton(info)
    end
end)

local showPricesCheckbox = CreateFrame("CheckButton", nil, barPanel, "UICheckButtonTemplate")
showPricesCheckbox:SetPoint("TOPLEFT", qualityDropdown, "BOTTOMLEFT", 20, -12)
showPricesCheckbox.Text:SetText("Show gold values below each item")
showPricesCheckbox:SetScript("OnClick", function(self)
    ns.db.showItemPrices = self:GetChecked()
    ns.RefreshBar()
end)

local copperCheckbox = CreateFrame("CheckButton", nil, barPanel, "UICheckButtonTemplate")
copperCheckbox:SetPoint("TOPLEFT", showPricesCheckbox, "BOTTOMLEFT", 0, -8)
copperCheckbox.Text:SetText("Include copper in loot bar price totals")
copperCheckbox:SetScript("OnClick", function(self)
    ns.db.showCopper = self:GetChecked()
    ns.RefreshBar()
end)

local junkCheckbox = CreateFrame("CheckButton", nil, barPanel, "UICheckButtonTemplate")
junkCheckbox:SetPoint("TOPLEFT", copperCheckbox, "BOTTOMLEFT", 0, -8)
junkCheckbox.Text:SetText("Show vendor junk tally on the loot bar")
junkCheckbox:SetScript("OnClick", function(self)
    ns.db.showJunk = self:GetChecked()
    ns.RefreshBar()
end)

-- Grid layout sliders: columns (grid width) and per-icon cell width/height
-- (grid height). Read the current DB value on show, since InitOptions runs
-- before the panel has necessarily been created in some load orders.
local function CreateGridSlider(anchorTo, label, dbKey, minVal, maxVal)
    local slider = CreateFrame("Slider", nil, barPanel, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 4, -24)
    slider:SetWidth(160)
    slider:SetMinMaxValues(minVal, maxVal)
    slider:SetValueStep(1)
    slider:SetObeyStepOnDrag(true)

    -- OptionsSliderTemplate's built-in Text sits above the slider; reuse it
    -- as the live "Label: value" readout instead of a separate FontString.
    -- Seeded with the slider's initial (min) value in case InitOptions'
    -- SetValue call below is a no-op (current value already equals min).
    slider.Text:SetText(label .. ": " .. minVal)
    slider.Low:SetText(minVal)
    slider.High:SetText(maxVal)

    slider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value + 0.5)
        ns.db[dbKey] = value
        slider.Text:SetText(label .. ": " .. value)
        ns.RefreshBar()
    end)

    return slider
end

local columnsSlider = CreateGridSlider(junkCheckbox, "Grid columns", "gridColumns", 1, 12)
local iconWidthSlider = CreateGridSlider(columnsSlider, "Icon width", "gridIconWidth", 16, 64)
local iconHeightSlider = CreateGridSlider(iconWidthSlider, "Icon height", "gridIconHeight", 16, 64)

local clearButton = CreateFrame("Button", nil, barPanel, "UIPanelButtonTemplate")
clearButton:SetSize(140, 22)
clearButton:SetPoint("TOPLEFT", iconHeightSlider, "BOTTOMLEFT", -4, -30)
clearButton:SetText("Clear loot bar")
clearButton:SetScript("OnClick", function() ns.ResetSession() end)

local barSubcategory = Settings.RegisterCanvasLayoutSubcategory(ns.OptionsCategory, barPanel, "Loot Bar Panel")
table.insert(ns.SettingsPanels, { name = "Loot Bar Panel", id = barSubcategory:GetID(), icon = "Interface/Icons/INV_Misc_Bag_09" })

-- Called from Core.lua once the saved-variable DB is ready, since this
-- file loads (and builds the panel) before ADDON_LOADED fires.
function ns.InitOptions()
    debugCheckbox:SetChecked(ns.db.debugMessages)
    autoAddCheckbox:SetChecked(ns.db.autoAddLoot)
    local quality = ns.db.minQuality or 0
    UIDropDownMenu_SetSelectedValue(qualityDropdown, quality)
    UIDropDownMenu_SetText(qualityDropdown, QualityText(quality))
    showPricesCheckbox:SetChecked(ns.db.showItemPrices)
    copperCheckbox:SetChecked(ns.db.showCopper)
    junkCheckbox:SetChecked(ns.db.showJunk)

    -- SetValue fires OnValueChanged (already wired above), which writes
    -- back to the DB and updates the label - harmless when it's already
    -- the same value.
    columnsSlider:SetValue(ns.db.gridColumns)
    iconWidthSlider:SetValue(ns.db.gridIconWidth)
    iconHeightSlider:SetValue(ns.db.gridIconHeight)
end
