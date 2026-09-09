local ADDON_NAME, ns = ...

local ROW_HEIGHT = 22
local MAX_ROWS = 60

-- Accepts a shift-clicked item link, an "item:1234" fragment, or a plain
-- item name (only resolvable if the client has already seen that item).
local function ParseItemInput(input)
    input = strtrim(input or "")
    if input == "" then return nil end

    local itemID = tonumber(input:match("item:(%d+)"))
    if itemID then return itemID end

    local name, link = GetItemInfo(input)
    return link and tonumber(link:match("item:(%d+)")) or nil
end

-- Builds a scrollable "list of items with a Remove button" panel, used for
-- the Loot Bar Blacklist and Always Vendor List subcategories below.
-- extraSetup, if given, is called with (panel, title) to add extra controls
-- above the list; it should return the frame the list should now anchor
-- below (defaulting to the title), and optionally a sync function called
-- alongside the list refresh every time the panel is shown.
local function BuildListPanel(panelTitle, getStore, onAdd, onRemove, extraSetup)
    local panel = CreateFrame("Frame")
    panel.name = panelTitle

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(panelTitle)

    local anchorFrame, extraSync = title, nil
    if extraSetup then
        anchorFrame, extraSync = extraSetup(panel, title)
        anchorFrame = anchorFrame or title
    end

    local scrollFrame = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", anchorFrame, "BOTTOMLEFT", 0, -12)
    scrollFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -30, 70)

    -- Width is set explicitly (via SetWidth in RefreshList below) to
    -- scrollFrame's own actual width, rather than a fixed SetSize number
    -- (the old approach, which clipped/wrapped a row's text once price
    -- info got appended to it) or a TOPRIGHT anchor (tried first, but
    -- ScrollFrame:SetScrollChild() - and every subsequent scroll step -
    -- re-anchors the scroll child's position internally, silently wiping
    -- out any extra anchor point added to it and collapsing it to zero
    -- width the moment the user scrolled). SetWidth is a plain numeric
    -- property, not an anchor, so it survives that repositioning fine -
    -- every row below inherits it by anchoring to content's edges instead
    -- of carrying its own fixed width.
    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetHeight(ROW_HEIGHT)
    scrollFrame:SetScrollChild(content)

    local rows = {}
    local RefreshList

    local function GetRow(index)
        local row = rows[index]
        if row then return row end

        row = CreateFrame("Frame", nil, content)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
        row:SetPoint("RIGHT", content, "RIGHT", 0, 0)

        -- row.itemLink is (re)set by RefreshList below on every render -
        -- same hover-tooltip idea as BrowserPanel.lua's detail rows and
        -- FlipIt.lua's rows.
        row:EnableMouse(true)
        row:SetScript("OnEnter", function(self)
            if not self.itemLink then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(self.itemLink)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)

        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(16, 16)
        icon:SetPoint("LEFT")
        row.icon = icon

        local removeButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        removeButton:SetSize(70, 18)
        removeButton:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        removeButton:SetText("Remove")
        row.removeButton = removeButton

        local addToBarButton = ns.CreateAddToBarButton(row)
        addToBarButton:SetPoint("RIGHT", removeButton, "LEFT", -6, 0)
        row.addToBarButton = addToBarButton

        local text = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        text:SetPoint("LEFT", icon, "RIGHT", 6, 0)
        text:SetPoint("RIGHT", addToBarButton, "LEFT", -6, 0)
        text:SetJustifyH("LEFT")
        row.text = text

        rows[index] = row
        return row
    end

    RefreshList = function()
        -- Re-applied on every refresh (including every time the panel is
        -- shown) since it's a plain property, not a persistent anchor - see
        -- content's creation comment above for why an anchor doesn't work
        -- here. scrollFrame's own width is stable (its anchors aren't
        -- touched by scrolling, only content's are), so this always
        -- reflects whatever the Settings canvas actually rendered.
        local width = scrollFrame:GetWidth()
        if width > 0 then content:SetWidth(width) end

        local store = getStore()
        local itemIDs = {}
        for itemID in pairs(store) do
            table.insert(itemIDs, itemID)
        end
        table.sort(itemIDs)

        if #itemIDs == 0 then
            local row = GetRow(1)
            row.icon:SetTexture(nil)
            row.text:SetText("(empty)")
            row.removeButton:Hide()
            row.addToBarButton:Hide()
            row.itemLink = nil
            row:Show()
            for i = 2, #rows do
                rows[i]:Hide()
            end
            content:SetHeight(ROW_HEIGHT)
            return
        end

        local shown = math.min(#itemIDs, MAX_ROWS)
        for i = 1, shown do
            local itemID = itemIDs[i]
            local row = GetRow(i)
            local name, link, _, _, _, _, _, _, _, texture = GetItemInfo(itemID)
            row.icon:SetTexture(texture or "Interface/Icons/INV_Misc_QuestionMark")
            local displayLink = link or ("item:" .. itemID)
            row.text:SetText(("%s  -  %s"):format(displayLink, ns.FormatSellAndAHPrice(displayLink)))
            row.itemLink = displayLink
            row.removeButton:Show()
            row.removeButton:SetScript("OnClick", function()
                store[itemID] = nil
                if onRemove then onRemove(itemID) end
                RefreshList()
            end)
            row.addToBarButton.link = link or ("item:" .. itemID)
            row.addToBarButton.icon = texture
            row.addToBarButton.onAfterAdd = RefreshList
            row.addToBarButton:Show()
            row:Show()
        end
        for i = shown + 1, #rows do
            rows[i]:Hide()
        end
        content:SetHeight(shown * ROW_HEIGHT)
    end

    local addLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    addLabel:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 16, 44)
    addLabel:SetText("Item name (or shift-click an item into the box):")

    local editBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    editBox:SetSize(220, 20)
    editBox:SetAutoFocus(false)
    editBox:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 20, 16)

    local addButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    addButton:SetSize(70, 22)
    addButton:SetPoint("LEFT", editBox, "RIGHT", 12, 0)
    addButton:SetText("Add")

    local function TryAdd()
        local itemID = ParseItemInput(editBox:GetText())
        if not itemID then
            print("|cff33ff99LootIQ|r: item not found. Shift-click it into the box, or type its exact name after you've seen it in-game.")
            return
        end
        getStore()[itemID] = true
        if onAdd then onAdd(itemID) end
        editBox:SetText("")
        editBox:ClearFocus()
        RefreshList()
    end
    addButton:SetScript("OnClick", TryAdd)
    editBox:SetScript("OnEnterPressed", TryAdd)

    local function RefreshAll()
        RefreshList()
        if extraSync then extraSync() end
    end
    panel:SetScript("OnShow", RefreshAll)
    table.insert(ns.OptionsRefreshers, RefreshAll)

    return panel
end

local bannedPanel = BuildListPanel(
    "Loot Bar Blacklist",
    function() return ns.db.excludedItems end,
    function(itemID)
        ns.db.whitelist[itemID] = nil
        ns.RemoveSessionItem(itemID)
    end
)
local bannedSubcategory = Settings.RegisterCanvasLayoutSubcategory(ns.OptionsCategory, bannedPanel, "Loot Bar Blacklist")
table.insert(ns.SettingsPanels, { name = "Loot Bar Blacklist", id = bannedSubcategory:GetID(), icon = "Interface/Buttons/UI-GroupLoot-Pass-Up" })

local alwaysVendorPanel = BuildListPanel(
    "Always Vendor List",
    function() return ns.db.alwaysVendor end,
    nil, nil,
    function(panel, title)
        local sellCheckbox = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        sellCheckbox:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
        sellCheckbox.Text:SetText("Automatically sell Always Vendor List items to vendors")
        sellCheckbox:SetScript("OnClick", function(self)
            ns.db.autoVendorEnabled = self:GetChecked()
        end)

        local learnCheckbox = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        learnCheckbox:SetPoint("TOPLEFT", sellCheckbox, "BOTTOMLEFT", 0, -8)
        learnCheckbox.Text:SetText("Automatically add items to this list when sold to a vendor")
        learnCheckbox:SetScript("OnClick", function(self)
            ns.db.autoLearnVendorEnabled = self:GetChecked()
        end)

        -- Reverse of the loot bar's "minimum quality to show": a ceiling,
        -- not a floor - picking Uncommon here auto-adds Poor/Common/
        -- Uncommon items sold to a vendor, not Uncommon-and-above.
        local qualityLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        qualityLabel:SetPoint("TOPLEFT", learnCheckbox, "BOTTOMLEFT", 0, -12)
        qualityLabel:SetText("Maximum quality to auto-add (that quality and below)")

        local qualityDropdown = CreateFrame("Frame", "LootIQAutoLearnQualityDropdown", panel, "UIDropDownMenuTemplate")
        qualityDropdown:SetPoint("TOPLEFT", qualityLabel, "BOTTOMLEFT", -16, -8)
        UIDropDownMenu_SetWidth(qualityDropdown, 150)

        local function OnQualitySelect(self)
            ns.db.autoLearnVendorMaxQuality = self.value
            UIDropDownMenu_SetSelectedValue(qualityDropdown, self.value)
            UIDropDownMenu_SetText(qualityDropdown, ns.QualityText(self.value))
            CloseDropDownMenus()
        end

        UIDropDownMenu_Initialize(qualityDropdown, function()
            for quality = 0, 5 do
                local info = UIDropDownMenu_CreateInfo()
                info.text = ns.QualityText(quality)
                info.value = quality
                info.func = OnQualitySelect
                info.checked = (ns.db and ns.db.autoLearnVendorMaxQuality == quality)
                UIDropDownMenu_AddButton(info)
            end
        end)

        return qualityDropdown, function()
            sellCheckbox:SetChecked(ns.db.autoVendorEnabled)
            learnCheckbox:SetChecked(ns.db.autoLearnVendorEnabled)
            local quality = ns.db.autoLearnVendorMaxQuality or 0
            UIDropDownMenu_SetSelectedValue(qualityDropdown, quality)
            UIDropDownMenu_SetText(qualityDropdown, ns.QualityText(quality))
        end
    end
)
local alwaysVendorSubcategory = Settings.RegisterCanvasLayoutSubcategory(ns.OptionsCategory, alwaysVendorPanel, "Always Vendor List")
table.insert(ns.SettingsPanels, { name = "Always Vendor List", id = alwaysVendorSubcategory:GetID(), icon = "Interface/Icons/INV_Misc_Coin_01" })
