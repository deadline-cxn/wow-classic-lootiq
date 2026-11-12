local ADDON_NAME, ns = ...

-- Retail's Auction House (Midnight, interface 16001) uses the modern
-- C_AuctionHouse API: a blank browse query returns one summarized row per
-- item (result.minPrice/.totalQuantity, identified by result.itemKey.itemID)
-- instead of Classic Era's per-auction "list" pagination, and paging/
-- throttling is driven by events rather than a manually paced timer.
-- Confirmed against Auctionator's own Source_ModernAH/IncrementalScan
-- (the browse-scan loop) and AH/Mixins/Throttling.lua (the client-side
-- throttle gate a browse query must respect). This addon's client is
-- retail-only, so no Classic Era fallback path is needed here.
local PROGRESS_EVERY = 5 -- print a progress line every N result batches

local scanning = false
local batchCount = 0
local scannedAuctions = 0
local currentScanPrices = {} -- [itemID] = lowest unit price (copper) seen so far this scan
local pendingStart = false -- true while waiting for AUCTION_HOUSE_THROTTLED_SYSTEM_READY to fire

-- Routine scan-lifecycle messages (start/progress/complete/interrupted,
-- and the Flip It summary) - suppressed by "Scan the auction house
-- quietly" in the Auction House panel below. Usage errors (already
-- scanning, AH not open) print unconditionally instead, since those are a
-- direct response to a failed action rather than scan noise.
local function ScanPrint(fmt, ...)
    if ns.db.quietAuctionScan then return end
    print(("|cff33ff99LootIQ|r: " .. fmt):format(...))
end

-- Compares this scan's prices against each item's baseline average (built
-- from every prior completed scan) to find "flip" opportunities - items
-- priced below what they've typically gone for - then folds this scan's
-- prices into that baseline for next time. The flip list is speculative
-- (a young baseline, or a market that's just moved, can easily produce a
-- false "deal") and is labeled as such in FlipIt.lua; it's replaced
-- wholesale each scan since an old deal may no longer be on the AH.
--
-- Also overwrites ns.accountDB.ahPrices with this scan's results (the price
-- shown everywhere else in the addon - Source/Item Database, loot bar,
-- tooltips). This used to only ever lower that stored price ("if unitPrice
-- < existing.price"), which meant a price permanently stuck at the lowest
-- it ever happened to be, drifting further from reality (and from what
-- Auctionator or a bag tooltip shows live) the longer the market moved on
-- since that one low scan. Overwriting unconditionally keeps it as fresh as
-- the player's own most recent scan instead.
local function FinishScan()
    local baseline = ns.accountDB.baseline
    wipe(ns.accountDB.flipOpportunities)
    local flipCount = 0
    local scanTime = time()

    for itemID, price in pairs(currentScanPrices) do
        ns.accountDB.ahPrices[itemID] = { price = price, scanTime = scanTime }

        local entry = baseline[itemID]
        if entry and entry.scans > 0 then
            local average = entry.total / entry.scans
            if price < average then
                local _, link = C_Item.GetItemInfo(itemID)
                ns.accountDB.flipOpportunities[itemID] = {
                    link = link,
                    price = price,
                    average = average,
                    scans = entry.scans,
                    scanTime = scanTime,
                }
                flipCount = flipCount + 1
            end
        end

        if not entry then
            entry = { total = 0, scans = 0 }
            baseline[itemID] = entry
        end
        entry.total = entry.total + price
        entry.scans = entry.scans + 1
    end

    if flipCount > 0 then
        ScanPrint("Flip It found %d item(s) speculatively below their baseline average price.", flipCount)
    end
end

-- Folds one batch of browse results (either the initial accumulated set
-- from AUCTION_HOUSE_BROWSE_RESULTS_UPDATED, or the newly-added set from
-- AUCTION_HOUSE_BROWSE_RESULTS_ADDED) into currentScanPrices. Idempotent -
-- safe to call again with results already seen, since it only ever lowers
-- an item's recorded price for this scan.
local function AddPrices(results)
    for _, result in ipairs(results) do
        local itemID = result.itemKey and result.itemKey.itemID
        local unitPrice = result.minPrice
        if itemID and unitPrice and unitPrice > 0 then
            if not currentScanPrices[itemID] or unitPrice < currentScanPrices[itemID] then
                currentScanPrices[itemID] = unitPrice
            end
            scannedAuctions = scannedAuctions + (result.totalQuantity or 1)
        end
    end
end

local function FinishScanning()
    scanning = false
    local pricedItems = 0
    for _ in pairs(currentScanPrices) do pricedItems = pricedItems + 1 end
    FinishScan()
    ScanPrint("scan complete - %d auctions scanned, %d item prices recorded.", scannedAuctions, pricedItems)
    if ns.RefreshBar then ns.RefreshBar() end
end

-- The throttle system self-paces C_AuctionHouse.RequestMoreBrowseResults()
-- internally (unlike Classic Era's manual QueryPage/C_Timer pacing, which
-- had no equivalent client-side gate to lean on) - see
-- Auctionator\Source_ModernAH\AH\Mixins\Throttling.lua.
local function RequestNextBatch()
    if not scanning then return end
    if C_AuctionHouse.HasFullBrowseResults() then
        FinishScanning()
        return
    end
    C_AuctionHouse.RequestMoreBrowseResults()
end

local function StartBrowseQuery()
    pendingStart = false
    C_AuctionHouse.SendBrowseQuery({ searchString = "", sorts = {}, filters = {}, itemClassFilters = {} })
end

-- A standalone button anchored to the open screen space just right of the
-- Auction House window, shown and hidden alongside it. Placed in open
-- space (not docked to a specific corner of the frame) so it can't end up
-- hidden underneath anything Auctionator (or another AH addon) overlays on
-- top of the window. Not placed in the options panel: opening that
-- settings frame while at the AH closes the AH, since Blizzard treats them
-- as mutually exclusive panels.
local scanButton = CreateFrame("Button", "LootIQScanButton", UIParent, "UIPanelButtonTemplate")
scanButton:SetSize(130, 26)
scanButton:SetText("LootIQ Scan")
scanButton:Hide()
scanButton:SetScript("OnClick", function() ns.ScanAuctionHouse() end)

local function ShowScanButton()
    if not AuctionHouseFrame then return end
    scanButton:SetFrameStrata(AuctionHouseFrame:GetFrameStrata())
    scanButton:SetFrameLevel(AuctionHouseFrame:GetFrameLevel() + 20)
    -- Anchored above vertical-center rather than at it, since a search
    -- button in that same "just right of the frame" spot would otherwise
    -- overlap it.
    scanButton:ClearAllPoints()
    scanButton:SetPoint("LEFT", AuctionHouseFrame, "RIGHT", 8, 60)
    scanButton:Show()
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
frame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
frame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
frame:RegisterEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
frame:RegisterEvent("AUCTION_HOUSE_BROWSE_FAILURE")
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
        if not scanning then return end
        AddPrices(C_AuctionHouse.GetBrowseResults())
        batchCount = batchCount + 1
        if batchCount % PROGRESS_EVERY == 0 then
            ScanPrint("scanning... batch %d, %d auctions so far.", batchCount, scannedAuctions)
        end
        RequestNextBatch()
    elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
        if not scanning then return end
        AddPrices(...)
        batchCount = batchCount + 1
        if batchCount % PROGRESS_EVERY == 0 then
            ScanPrint("scanning... batch %d, %d auctions so far.", batchCount, scannedAuctions)
        end
        RequestNextBatch()
    elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
        if pendingStart then StartBrowseQuery() end
    elseif event == "AUCTION_HOUSE_BROWSE_FAILURE" then
        if scanning then
            scanning = false
            ScanPrint("scan failed - the Auction House reported an error.")
        end
    elseif event == "AUCTION_HOUSE_SHOW" then
        -- Deferred a frame tick: some AH addons (including Auctionator)
        -- finish building their own overlay frames slightly after this
        -- event fires.
        C_Timer.After(0, ShowScanButton)
    elseif event == "AUCTION_HOUSE_CLOSED" then
        scanButton:Hide()
        pendingStart = false
        if scanning then
            scanning = false
            ScanPrint("scan stopped, the Auction House was closed.")
        end
    end
end)

-- Scans the Auction House's current (blank) browse search and records the
-- lowest per-unit price seen for each item into ns.accountDB.ahPrices
-- (shared across all characters on the account), separate from any
-- Auctionator data. Must be called while the Auction House window is open.
-- Paging is driven by AUCTION_HOUSE_BROWSE_RESULTS_ADDED/_UPDATED above,
-- gated by C_AuctionHouse.IsThrottledMessageSystemReady() so a scan started
-- while the throttle system isn't ready waits for
-- AUCTION_HOUSE_THROTTLED_SYSTEM_READY instead of erroring.
function ns.ScanAuctionHouse()
    if scanning then
        print("|cff33ff99LootIQ|r: a scan is already running.")
        return
    end
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
        print("|cff33ff99LootIQ|r: open the Auction House to scan it.")
        return
    end

    scanning = true
    batchCount = 0
    scannedAuctions = 0
    wipe(currentScanPrices)
    ScanPrint("scanning the auction house, this may take a while...")
    if C_AuctionHouse.IsThrottledMessageSystemReady() then
        StartBrowseQuery()
    else
        pendingStart = true
    end
end

----------------------------------------------------------------------------
-- Auction House panel: scan-related options, plus a browsable list of
-- every item price recorded by our own scans (ns.accountDB.ahPrices) -
-- the lowest per-unit price ever seen, not this scan specifically.
----------------------------------------------------------------------------

local PRICE_ROW_HEIGHT = 22
local MAX_PRICE_ROWS = 2000 -- a generous ceiling, not a practical truncation - a realm's AH rarely has this many unique items

local ahPanel = CreateFrame("Frame")
ahPanel.name = "Auction House"

local ahTitle = ahPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
ahTitle:SetPoint("TOPLEFT", 16, -16)
ahTitle:SetText("Auction House")

local quietScanCheckbox = CreateFrame("CheckButton", nil, ahPanel, "UICheckButtonTemplate")
quietScanCheckbox:SetPoint("TOPLEFT", ahTitle, "BOTTOMLEFT", 0, -20)
quietScanCheckbox.Text:SetText("Scan the auction house quietly (no chat messages)")
quietScanCheckbox:SetScript("OnClick", function(self)
    ns.db.quietAuctionScan = self:GetChecked()
end)

-- SearchBoxTemplate brings its own magnifier icon, "Search..." placeholder,
-- and clear (X) button - same convention as BrowserPanel.lua's searchable
-- panels. Hooked (not set) so the template's own OnTextChanged handler,
-- which manages the placeholder and the X's visibility, still runs.
local priceSearchBox = CreateFrame("EditBox", nil, ahPanel, "SearchBoxTemplate")
priceSearchBox:SetSize(200, 20)
priceSearchBox:SetPoint("TOPLEFT", quietScanCheckbox, "BOTTOMLEFT", 0, -20)
priceSearchBox:SetAutoFocus(false)

local priceListLabel = ahPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
priceListLabel:SetPoint("TOPLEFT", priceSearchBox, "BOTTOMLEFT", 0, -12)
priceListLabel:SetText("Lowest price seen for every item scanned:")

local priceScroll = CreateFrame("ScrollFrame", nil, ahPanel, "UIPanelScrollFrameTemplate")
priceScroll:SetPoint("TOPLEFT", priceListLabel, "BOTTOMLEFT", 0, -8)
priceScroll:SetPoint("BOTTOMRIGHT", ahPanel, "BOTTOMRIGHT", -30, 16)

local priceContent = CreateFrame("Frame", nil, priceScroll)
priceContent:SetSize(600, PRICE_ROW_HEIGHT)
priceScroll:SetScrollChild(priceContent)

local priceRows = {}

local function GetPriceRow(index)
    local row = priceRows[index]
    if row then return row end

    row = CreateFrame("Frame", nil, priceContent)
    row:SetSize(600, PRICE_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", priceContent, "TOPLEFT", 0, -(index - 1) * PRICE_ROW_HEIGHT)

    -- row.itemLink is (re)set by RefreshPriceList below on every render -
    -- same hover-tooltip idea as FlipIt.lua's and OptionsLists.lua's rows.
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

    priceRows[index] = row
    return row
end

local function RefreshPriceList()
    local prices = ns.accountDB.ahPrices
    local itemIDs = {}
    for itemID in pairs(prices) do
        table.insert(itemIDs, itemID)
    end
    table.sort(itemIDs, function(a, b)
        local nameA = C_Item.GetItemInfo(a) or ("item:" .. a)
        local nameB = C_Item.GetItemInfo(b) or ("item:" .. b)
        return nameA < nameB
    end)

    -- Case-insensitive substring match against each item's name - same
    -- idea as BrowserPanel.lua's searchable panels.
    local filter = priceSearchBox:GetText()
    local isFiltered = filter and filter ~= ""
    if isFiltered then
        filter = filter:lower()
        local matched = {}
        for _, itemID in ipairs(itemIDs) do
            local name = C_Item.GetItemInfo(itemID) or ("item:" .. itemID)
            if name:lower():find(filter, 1, true) then
                table.insert(matched, itemID)
            end
        end
        itemIDs = matched
    end

    if #itemIDs == 0 then
        local row = GetPriceRow(1)
        row.icon:SetTexture(nil)
        row.text:SetText(isFiltered and "(no matches)" or "(no items recorded yet - run /lootiq scan at the auction house)")
        row.addToBarButton:Hide()
        row.itemLink = nil
        row:Show()
        for i = 2, #priceRows do priceRows[i]:Hide() end
        priceContent:SetHeight(PRICE_ROW_HEIGHT)
        return
    end

    local shown = math.min(#itemIDs, MAX_PRICE_ROWS)
    for i = 1, shown do
        local itemID = itemIDs[i]
        local data = prices[itemID]
        local row = GetPriceRow(i)
        local name, link, _, _, _, _, _, _, _, texture = C_Item.GetItemInfo(itemID)
        row.icon:SetTexture(texture or "Interface/Icons/INV_Misc_QuestionMark")
        row.text:SetText(("%s - %s"):format(link or name or ("item:" .. itemID), ns.FormatPrice(data.price)))
        row.itemLink = link or ("item:" .. itemID)
        row.addToBarButton.link = link or ("item:" .. itemID)
        row.addToBarButton.icon = texture
        row.addToBarButton:Show()
        row:Show()
    end
    for i = shown + 1, #priceRows do
        priceRows[i]:Hide()
    end
    priceContent:SetHeight(shown * PRICE_ROW_HEIGHT)
end

priceSearchBox:HookScript("OnTextChanged", RefreshPriceList)
-- Esc wipes the filter rather than merely dropping focus, which is what a
-- user pressing Esc on a search box means.
priceSearchBox:HookScript("OnEscapePressed", function(self)
    self:SetText("")
    self:ClearFocus()
    RefreshPriceList()
end)

local function RefreshAHPanel()
    quietScanCheckbox:SetChecked(ns.db.quietAuctionScan)
    RefreshPriceList()
end
ahPanel:SetScript("OnShow", RefreshAHPanel)
table.insert(ns.OptionsRefreshers, RefreshAHPanel)

local ahSubcategory = Settings.RegisterCanvasLayoutSubcategory(ns.OptionsCategory, ahPanel, "Auction House")
table.insert(ns.SettingsPanels, { name = "Auction House", id = ahSubcategory:GetID(), icon = "Interface/Icons/INV_Misc_Note_01" })
