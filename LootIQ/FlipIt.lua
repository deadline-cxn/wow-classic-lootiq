local ADDON_NAME, ns = ...

local ROW_HEIGHT = 22
local MAX_ROWS = 60

local panel = CreateFrame("Frame")
panel.name = "Flip It"

local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("Flip It")

-- Speculative by design: baseline (ns.accountDB.baseline, built in
-- AuctionScan.lua) is only ever as good as however many scans have run so
-- far, and the AH moves - a "deal" here is a prompt to go check, not a
-- promise of profit.
local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
subtitle:SetJustifyH("LEFT")
subtitle:SetWidth(560)
subtitle:SetText("Speculative: items from your last auction house scan (|cffffffff/lootiq scan|r) priced below their running baseline average. Not a guaranteed deal - the baseline is only as good as how many scans have built it up, and prices move.")

local clearButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
clearButton:SetSize(140, 22)
clearButton:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -12)
clearButton:SetText("Clear Flip It list")

local scrollFrame = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT", clearButton, "BOTTOMLEFT", 0, -12)
scrollFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -30, 16)

local content = CreateFrame("Frame", nil, scrollFrame)
content:SetSize(600, ROW_HEIGHT)
scrollFrame:SetScrollChild(content)

local rows = {}

local function GetRow(index)
    local row = rows[index]
    if row then return row end

    row = CreateFrame("Frame", nil, content)
    row:SetSize(600, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)

    -- row.itemLink is (re)set by RefreshList below on every render - same
    -- hover-tooltip idea as BrowserPanel.lua's detail rows.
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        if not self.itemLink then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(self.itemLink)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("LEFT")
    row.icon = icon

    local addToBarButton = ns.CreateAddToBarButton(row)
    addToBarButton:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.addToBarButton = addToBarButton

    local text = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    text:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    text:SetPoint("RIGHT", addToBarButton, "LEFT", -6, 0)
    text:SetJustifyH("LEFT")
    row.text = text

    rows[index] = row
    return row
end

-- Biggest (speculative) discount first, so the most interesting entries
-- don't get buried in a long list.
local function SortedFlipIDs()
    local flips = ns.accountDB.flipOpportunities
    local itemIDs = {}
    for itemID in pairs(flips) do
        table.insert(itemIDs, itemID)
    end
    table.sort(itemIDs, function(a, b)
        local dataA, dataB = flips[a], flips[b]
        local pctA = (dataA.average - dataA.price) / dataA.average
        local pctB = (dataB.average - dataB.price) / dataB.average
        return pctA > pctB
    end)
    return itemIDs
end

local function RefreshList()
    local flips = ns.accountDB.flipOpportunities
    local itemIDs = SortedFlipIDs()

    if #itemIDs == 0 then
        local row = GetRow(1)
        row.icon:SetTexture(nil)
        row.text:SetText("(no flip opportunities right now - run /lootiq scan at the auction house)")
        row.addToBarButton:Hide()
        row.itemLink = nil
        row:Show()
        for i = 2, #rows do rows[i]:Hide() end
        content:SetHeight(ROW_HEIGHT)
        return
    end

    local shown = math.min(#itemIDs, MAX_ROWS)
    for i = 1, shown do
        local itemID = itemIDs[i]
        local data = flips[itemID]
        local row = GetRow(i)
        local name, link, _, _, _, _, _, _, _, texture = GetItemInfo(itemID)
        row.icon:SetTexture(texture or "Interface/Icons/INV_Misc_QuestionMark")

        local pct = (data.average - data.price) / data.average * 100
        row.text:SetText(("%s - %s  (baseline %s across %d scan%s, %.0f%% below)"):format(
            link or data.link or name or ("item:" .. itemID),
            ns.FormatPrice(data.price),
            ns.FormatPrice(math.floor(data.average)),
            data.scans, data.scans == 1 and "" or "s",
            pct))
        row.addToBarButton.link = link or data.link or ("item:" .. itemID)
        row.addToBarButton.icon = texture
        row.addToBarButton:Show()
        row.itemLink = row.addToBarButton.link
        row:Show()
    end
    for i = shown + 1, #rows do
        rows[i]:Hide()
    end
    content:SetHeight(shown * ROW_HEIGHT)
end

clearButton:SetScript("OnClick", function()
    wipe(ns.accountDB.flipOpportunities)
    RefreshList()
end)

panel:SetScript("OnShow", RefreshList)
table.insert(ns.OptionsRefreshers, RefreshList)

local flipSubcategory = Settings.RegisterCanvasLayoutSubcategory(ns.OptionsCategory, panel, "Flip It")
table.insert(ns.SettingsPanels, { name = "Flip It", id = flipSubcategory:GetID(), icon = "Interface/Icons/INV_Misc_Coin_02" })
