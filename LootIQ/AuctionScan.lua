local ADDON_NAME, ns = ...

-- Classic Era's Auction House uses the old (pre-retail) API: QueryAuctionItems
-- paginates through "list" results, and GetAuctionItemInfo("list", index)
-- returns a positional table. Field positions confirmed against Auctionator's
-- own legacy-AH scanning code (Source_LegacyAH/Constants/Main.lua).
local BUYOUT_INDEX = 10
local QUANTITY_INDEX = 3
local ITEMID_INDEX = 17
local PAGE_SIZE = 50
local PAGE_DELAY = 0.6 -- seconds between page queries, a safety margin against server throttling
local PROGRESS_EVERY = 10 -- print a progress line every N pages

local scanning = false
local currentPage = 0
local scannedAuctions = 0
local currentScanPrices = {} -- [itemID] = lowest unit price (copper) seen so far this scan

local function QueryPage(page)
    QueryAuctionItems("", nil, nil, page, nil, nil, false, false, nil)
end

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
                local _, link = GetItemInfo(itemID)
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

local function ProcessPage()
    local numItems = GetNumAuctionItems("list")
    for i = 1, numItems do
        local info = { GetAuctionItemInfo("list", i) }
        local itemID = info[ITEMID_INDEX]
        local buyout = info[BUYOUT_INDEX]
        local quantity = info[QUANTITY_INDEX] or 1
        if itemID and buyout and buyout > 0 then
            local unitPrice = math.floor(buyout / math.max(quantity, 1))

            if not currentScanPrices[itemID] or unitPrice < currentScanPrices[itemID] then
                currentScanPrices[itemID] = unitPrice
            end
        end
    end
    scannedAuctions = scannedAuctions + numItems

    if numItems < PAGE_SIZE then
        scanning = false
        local pricedItems = 0
        for _ in pairs(currentScanPrices) do pricedItems = pricedItems + 1 end
        FinishScan()
        ScanPrint("scan complete - %d auctions scanned, %d item prices recorded.", scannedAuctions, pricedItems)
        if ns.RefreshBar then ns.RefreshBar() end
        return
    end

    currentPage = currentPage + 1
    if currentPage % PROGRESS_EVERY == 0 then
        ScanPrint("scanning... page %d, %d auctions so far.", currentPage, scannedAuctions)
    end
    C_Timer.After(PAGE_DELAY, function()
        if scanning then QueryPage(currentPage) end
    end)
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
    if not AuctionFrame then return end
    scanButton:SetFrameStrata(AuctionFrame:GetFrameStrata())
    scanButton:SetFrameLevel(AuctionFrame:GetFrameLevel() + 20)
    -- Anchored above vertical-center rather than at it, since a search
    -- button in that same "just right of the frame" spot would otherwise
    -- overlap it.
    scanButton:ClearAllPoints()
    scanButton:SetPoint("LEFT", AuctionFrame, "RIGHT", 8, 60)
    scanButton:Show()
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
frame:SetScript("OnEvent", function(self, event)
    if event == "AUCTION_ITEM_LIST_UPDATE" then
        if scanning then ProcessPage() end
    elseif event == "AUCTION_HOUSE_SHOW" then
        -- Deferred a frame tick: some AH addons (including Auctionator)
        -- finish building their own overlay frames slightly after this
        -- event fires.
        C_Timer.After(0, ShowScanButton)
    elseif event == "AUCTION_HOUSE_CLOSED" then
        scanButton:Hide()
        if scanning then
            scanning = false
            ScanPrint("scan stopped, the Auction House was closed.")
        end
    end
end)

-- Scans every page of the Auction House's current (blank) search and
-- records the lowest per-unit buyout seen for each item into
-- ns.accountDB.ahPrices (shared across all characters on the account),
-- separate from any Auctionator data. Must be called while the Auction
-- House window is open. A full scan can take a while since each page
-- query is deliberately paced to avoid tripping server-side throttling.
function ns.ScanAuctionHouse()
    if scanning then
        print("|cff33ff99LootIQ|r: a scan is already running.")
        return
    end
    if not (AuctionFrame and AuctionFrame:IsShown()) then
        print("|cff33ff99LootIQ|r: open the Auction House to scan it.")
        return
    end

    scanning = true
    currentPage = 0
    scannedAuctions = 0
    newPrices = 0
    wipe(currentScanPrices)
    ScanPrint("scanning the auction house, this may take a while...")
    QueryPage(0)
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
        local nameA = GetItemInfo(a) or ("item:" .. a)
        local nameB = GetItemInfo(b) or ("item:" .. b)
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
            local name = GetItemInfo(itemID) or ("item:" .. itemID)
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
        local name, link, _, _, _, _, _, _, _, texture = GetItemInfo(itemID)
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
