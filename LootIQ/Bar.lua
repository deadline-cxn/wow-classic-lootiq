local ADDON_NAME, ns = ...

local DEFAULT_ICON_WIDTH = 28
local DEFAULT_ICON_HEIGHT = 28
local DEFAULT_COLUMNS = 8
local PADDING = 22
local HANDLE_WIDTH = 16
local MAX_ICONS = 32
local PRICE_ROW_HEIGHT = 16
local ROW_GAP = 4
local BOLT_OF_RUNECLOTH_ITEM_ID = 14048

-- Grid sizing is user-configurable (Loot Bar Panel in options), read live
-- from the DB so it can change without a reload. Falls back to defaults
-- when the DB isn't loaded yet (these run at file-load time, before
-- ADDON_LOADED populates ns.db).
local function IconWidth() return (ns.db and ns.db.gridIconWidth) or DEFAULT_ICON_WIDTH end
local function IconHeight() return (ns.db and ns.db.gridIconHeight) or DEFAULT_ICON_HEIGHT end
local function Columns() return (ns.db and ns.db.gridColumns) or DEFAULT_COLUMNS end
local function ShowPrices() return not ns.db or ns.db.showItemPrices ~= false end

-- Full height of one grid slot: the icon, plus the price row beneath it
-- when prices are shown.
local function CellHeight()
    local h = IconHeight()
    if ShowPrices() then
        h = h + ROW_GAP + PRICE_ROW_HEIGHT
    end
    return h
end

local bar = CreateFrame("Frame", "LootIQBar", UIParent, "BackdropTemplate")
ns.Bar = bar
bar:SetSize(
    HANDLE_WIDTH + PADDING * 2,
    CellHeight() + PADDING * 2
)
bar:SetBackdrop({
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
bar:SetBackdropColor(0, 0, 0, 0.6)
bar:SetMovable(true)
bar:SetClampedToScreen(true)
bar:SetFrameStrata("MEDIUM")

-- Drag handle: grab this to move the bar, right-click it to open options.
local handle = CreateFrame("Button", nil, bar)
handle:SetSize(HANDLE_WIDTH, IconHeight())
handle:SetPoint("TOPLEFT", bar, "TOPLEFT", PADDING, -PADDING)
handle:RegisterForDrag("LeftButton")
handle:SetScript("OnDragStart", function() bar:StartMoving() end)
handle:SetScript("OnDragStop", function()
    bar:StopMovingOrSizing()
    local point, _, relPoint, x, y = bar:GetPoint()
    ns.db.barPosition = { point = point, relPoint = relPoint, x = x, y = y }
end)
handle:RegisterForClicks("LeftButtonUp", "RightButtonUp")
handle:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
        Settings.OpenToCategory(ns.OptionsCategoryID)
    else
        ns.db.minimized = true
        ns.RefreshBar()
    end
end)

handle:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("LootIQ")
    GameTooltip:AddLine("Drag to move, click to minimize, right-click for options.", 1, 1, 1)
    GameTooltip:AddLine("Drop a bag item here to track it.", 1, 1, 1)
    GameTooltip:Show()
end)
handle:SetScript("OnLeave", function() GameTooltip:Hide() end)

for i = 1, 3 do
    local line = handle:CreateTexture(nil, "ARTWORK")
    line:SetTexture("Interface/Buttons/WHITE8X8")
    line:SetVertexColor(0.85, 0.85, 0.85, 0.9)
    line:SetSize(10, 2)
    line:SetPoint("CENTER", handle, "CENTER", 0, (2 - i) * 5)
end

-- Drop an item from your bags (or anywhere else) onto the bar to start
-- tracking it, even if you already have some and didn't just loot it.
local function HandleItemDrop()
    local cursorType, _, link = GetCursorInfo()
    if cursorType == "item" and link then
        local itemID = tonumber(link:match("item:(%d+)"))
        local icon = itemID and GetItemIcon(itemID)
        -- Dropping an item back on the bar is a deliberate re-add, so it
        -- overrides a prior manual removal.
        ns.AddSessionItem(link, icon, true)
    end
    ClearCursor()
end

bar:EnableMouse(true)
bar:SetScript("OnReceiveDrag", HandleItemDrop)
bar:SetScript("OnMouseUp", function(self, button)
    if button ~= "RightButton" then HandleItemDrop() end
end)
handle:SetScript("OnReceiveDrag", HandleItemDrop)

-- Right-click an icon for a menu to remove it from the bar.
local removeMenuItemID = nil
local removeMenu = CreateFrame("Frame", "LootIQRemoveMenu", UIParent, "UIDropDownMenuTemplate")
UIDropDownMenu_Initialize(removeMenu, function()
    if not removeMenuItemID then return end
    local data = ns.db.session[removeMenuItemID]

    local info = UIDropDownMenu_CreateInfo()
    info.text = (data and data.link) or "Item"
    info.isTitle = true
    info.notCheckable = true
    UIDropDownMenu_AddButton(info)

    info = UIDropDownMenu_CreateInfo()
    info.text = "Remove from bar"
    info.notCheckable = true
    info.func = function() ns.RemoveSessionItem(removeMenuItemID) end
    UIDropDownMenu_AddButton(info)
end, "MENU")

local function ShowRemoveMenu(anchorFrame, itemID)
    removeMenuItemID = itemID
    ToggleDropDownMenu(1, nil, removeMenu, anchorFrame, 0, 0)
end

-- Shown instead of everything else while the bar is minimized. Still
-- draggable, and clicking it (rather than dragging) expands the bar again.
local minimizedButton = CreateFrame("Button", nil, bar)
minimizedButton:SetSize(IconWidth(), IconHeight())
minimizedButton:SetPoint("TOPLEFT", bar, "TOPLEFT", PADDING, -PADDING)
minimizedButton:Hide()

local minimizedIcon = minimizedButton:CreateTexture(nil, "ARTWORK")
minimizedIcon:SetAllPoints()
minimizedIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
minimizedIcon:SetTexture(GetItemIcon(BOLT_OF_RUNECLOTH_ITEM_ID) or "Interface/Icons/INV_Misc_QuestionMark")

minimizedButton:RegisterForDrag("LeftButton")
minimizedButton:SetScript("OnDragStart", function() bar:StartMoving() end)
minimizedButton:SetScript("OnDragStop", function()
    bar:StopMovingOrSizing()
    local point, _, relPoint, x, y = bar:GetPoint()
    ns.db.barPosition = { point = point, relPoint = relPoint, x = x, y = y }
end)
minimizedButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
minimizedButton:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
        Settings.OpenToCategory(ns.OptionsCategoryID)
    else
        ns.db.minimized = false
        ns.RefreshBar()
    end
end)
minimizedButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("LootIQ (minimized)")
    GameTooltip:AddLine("Click to expand, right-click for options.", 1, 1, 1)
    GameTooltip:Show()
end)
minimizedButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- Vendor-junk tally: always the first entry on the bar (when enabled),
-- showing how many Poor-quality sellable items are currently in your bags
-- and what selling them all would be worth. Scanned live from your bags on
-- every refresh, same as the per-item counts below. Its own position never
-- moves, so it's created separately from the pooled per-item icon frames.
local junkFrame = CreateFrame("Frame", nil, bar)
junkFrame:SetSize(IconWidth(), CellHeight())

local junkIcon = junkFrame:CreateTexture(nil, "ARTWORK")
junkIcon:SetPoint("TOP", junkFrame, "TOP", 0, 0)
junkIcon:SetSize(IconWidth(), IconHeight())
junkIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
junkIcon:SetTexture("Interface/Icons/Trade_BlackSmithing")

local junkCountText = junkFrame:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
junkCountText:SetPoint("BOTTOMRIGHT", junkIcon, "BOTTOMRIGHT", -1, 1)

local junkPriceText = junkFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
junkPriceText:SetPoint("TOP", junkIcon, "BOTTOM", 0, -ROW_GAP)
junkPriceText:SetWidth(IconWidth() + PADDING - 4)

junkFrame:EnableMouse(true)
junkFrame:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Vendor Junk")
    GameTooltip:AddLine("Poor-quality items in your bags, and what selling them is worth.", 1, 1, 1)
    GameTooltip:Show()
end)
junkFrame:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- Scans all bags for Poor-quality items with a vendor sell price. Uses
-- GetItemInfo for quality rather than the container info's own quality
-- field, which isn't always reliable for items the client hasn't fully
-- cached yet (matches an issue seen elsewhere in this addon).
local function ScanJunk()
    local count, value = 0, 0
    for bag = BACKPACK_CONTAINER, NUM_BAG_SLOTS do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID then
                local _, _, quality, _, _, _, _, _, _, _, sellPrice = GetItemInfo(info.itemID)
                if quality == 0 and sellPrice and sellPrice > 0 then
                    count = count + info.stackCount
                    value = value + sellPrice * info.stackCount
                end
            end
        end
    end
    return count, value
end

-- Positions a slot frame in the grid: slotIndex is 0-based across the
-- combined junk + tracked-item sequence, wrapping to a new row below every
-- COLUMNS slots.
local function PositionSlot(frame, slotIndex)
    local cols = Columns()
    local col = slotIndex % cols
    local row = math.floor(slotIndex / cols)
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", bar, "TOPLEFT",
        PADDING + HANDLE_WIDTH + PADDING + col * (IconWidth() + PADDING),
        -PADDING - row * (CellHeight() + PADDING))
end

-- Pool of item icon frames laid out in a grid after the handle (or after
-- the junk entry, when it's shown).
local iconFrames = {}

local function GetIconFrame(index)
    local f = iconFrames[index]
    if f then return f end

    f = CreateFrame("Frame", nil, bar)
    f:SetSize(IconWidth(), CellHeight())

    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOP", f, "TOP", 0, 0)
    icon:SetSize(IconWidth(), IconHeight())
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.icon = icon

    local count = f:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    count:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", -1, 1)
    f.count = count

    -- Last known Auctionator price, shown under the icon.
    local price = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    price:SetPoint("TOP", icon, "BOTTOM", 0, -ROW_GAP)
    price:SetWidth(IconWidth() + PADDING - 4)
    f.price = price

    f:EnableMouse(true)
    f:SetScript("OnEnter", function(self)
        if self.link then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetHyperlink(self.link)
            GameTooltip:Show()
        end
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f:SetScript("OnReceiveDrag", HandleItemDrop)
    f:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then
            ShowRemoveMenu(self, self.itemID)
            return
        end

        -- Dropping an item onto the icon still tracks it, same as before;
        -- a plain click with nothing (or something other than an item) on
        -- the cursor jumps to this item's Item Database entry instead.
        if GetCursorInfo() == "item" then
            HandleItemDrop()
        elseif self.itemID then
            ns.GoToItemDatabaseEntry(self.itemID)
        end
    end)

    iconFrames[index] = f
    return f
end

local function RefreshBar()
    local iw, ih, cols, showPrices = IconWidth(), IconHeight(), Columns(), ShowPrices()
    local cellHeight = CellHeight()

    handle:SetSize(HANDLE_WIDTH, ih)
    minimizedButton:SetSize(iw, ih)

    if ns.db.minimized then
        handle:Hide()
        junkFrame:Hide()
        for _, f in ipairs(iconFrames) do
            f:Hide()
        end
        minimizedButton:Show()
        bar:SetSize(iw + PADDING * 2, ih + PADDING * 2)
        return
    end
    minimizedButton:Hide()
    handle:Show()

    junkFrame:SetSize(iw, cellHeight)
    junkIcon:SetSize(iw, ih)
    junkPriceText:SetWidth(iw + PADDING - 4)
    junkPriceText:SetShown(showPrices)

    local junkShown = ns.db.showJunk
    local nextSlot = 0

    if junkShown then
        local junkCount, junkValue = ScanJunk()
        junkCountText:SetText(tostring(junkCount))
        junkPriceText:SetText(ns.FormatPrice(junkValue))
        PositionSlot(junkFrame, nextSlot)
        junkFrame:Show()
        nextSlot = nextSlot + 1
    else
        junkFrame:Hide()
    end

    local order = ns.db.sessionOrder
    local shown = math.min(#order, MAX_ICONS)

    for i = 1, shown do
        local itemID = order[i]
        local data = ns.db.session[itemID]
        local f = GetIconFrame(i)
        f:SetSize(iw, cellHeight)
        f.icon:SetSize(iw, ih)
        f.price:SetWidth(iw + PADDING - 4)
        f.price:SetShown(showPrices)
        PositionSlot(f, nextSlot)
        nextSlot = nextSlot + 1

        -- Icon can be nil for an item seen for the first time before its
        -- data is cached; retry on later refreshes until it resolves.
        local icon = data.icon or GetItemIcon(itemID)
        if icon then data.icon = icon end
        f.icon:SetTexture(icon or "Interface/Icons/INV_Misc_QuestionMark")
        local qty = GetItemCount(itemID) or 0
        f.count:SetText(tostring(qty))

        -- Total value of the stack you're holding (unit price x quantity),
        -- not just the per-unit price.
        local unitPrice = ns.GetItemPrice(data.link)
        f.price:SetText(unitPrice and ns.FormatPrice(unitPrice * qty) or "")

        f.link = data.link
        f.itemID = itemID
        f:Show()
    end
    for i = shown + 1, #iconFrames do
        iconFrames[i]:Hide()
    end

    local totalSlots = nextSlot
    local columnsUsed = math.min(totalSlots, cols)
    local rows = math.max(1, math.ceil(totalSlots / cols))
    bar:SetSize(
        HANDLE_WIDTH + PADDING * 2 + columnsUsed * (iw + PADDING),
        PADDING * 2 + rows * cellHeight + (rows - 1) * PADDING
    )
end
ns.RefreshBar = RefreshBar

-- Small reusable "+" button for adding an item to the loot bar from
-- anywhere items are listed (item database, blacklist, flip list, AH price
-- list, etc). Callers set button.link/button.icon before showing it; click
-- behavior is wired here so every call site stays a one-liner.
function ns.CreateAddToBarButton(parent)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(16, 16)
    btn:SetNormalTexture("Interface/Buttons/UI-PlusButton-Up")
    btn:SetPushedTexture("Interface/Buttons/UI-PlusButton-Down")
    btn:SetHighlightTexture("Interface/Buttons/UI-PlusButton-Hilight", "ADD")
    btn:SetScript("OnClick", function(self)
        if not self.link then return end
        ns.AddSessionItem(self.link, self.icon, true)
        if self.onAfterAdd then self.onAfterAdd() end
    end)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Add to loot bar")
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return btn
end

-- Registers an item to be tracked on the bar. Its displayed count always
-- reflects your current inventory total, not how many you've looted.
-- Pass force=true to override a prior manual removal (e.g. dragging the
-- item back onto the bar); otherwise a removed item stays excluded.
function ns.AddSessionItem(link, icon, force)
    if not link then return end
    local itemID = tonumber(link:match("item:(%d+)"))
    if not itemID then return end

    if force then
        ns.db.excludedItems[itemID] = nil
    elseif ns.db.excludedItems[itemID] then
        return
    end

    local session = ns.db.session
    local entry = session[itemID]
    if not entry then
        entry = { icon = icon, link = link }
        session[itemID] = entry
        table.insert(ns.db.sessionOrder, itemID)
    end
    entry.link = link
    if icon then entry.icon = icon end

    RefreshBar()
end

bar:RegisterEvent("BAG_UPDATE_DELAYED")
bar:SetScript("OnEvent", function(self, event)
    if event == "BAG_UPDATE_DELAYED" then
        RefreshBar()
    end
end)

-- Bans an item (never auto-added again) and, if it's currently tracked,
-- takes it off the bar too. Works even for an item that isn't on the bar
-- yet, so the Loot Bar Blacklist options panel can ban by typed name.
function ns.RemoveSessionItem(itemID)
    if not itemID then return end
    ns.db.excludedItems[itemID] = true
    if ns.db.session[itemID] then
        ns.db.session[itemID] = nil
        for i, id in ipairs(ns.db.sessionOrder) do
            if id == itemID then
                table.remove(ns.db.sessionOrder, i)
                break
            end
        end
    end
    RefreshBar()
end

function ns.ResetSession()
    wipe(ns.db.session)
    wipe(ns.db.sessionOrder)
    RefreshBar()
end

-- Small tab strip across the bar's outside top edge, one per registered
-- options panel (ns.SettingsPanels, populated by every panel file as it
-- registers - see Core.lua), jumping straight to that panel instead of
-- always landing on the main options page. Built once from ns.InitBar
-- below, since ns.SettingsPanels is only fully populated once every file
-- has loaded - Bar.lua itself loads before some panel files that populate
-- it (e.g. AuctionScan.lua), so building any earlier would miss entries.
-- Parented to bar, so the tabs move with it and hide/show along with it
-- automatically. Each tab shows that panel's icon (info.icon) rather than
-- text, so the strip stays compact regardless of panel name length.
local TAB_SIZE = 20
local TAB_GAP = 2

local function CreateSettingsTabs()
    local previous
    for _, info in ipairs(ns.SettingsPanels) do
        local tab = CreateFrame("Button", nil, bar, "BackdropTemplate")
        tab:SetSize(TAB_SIZE, TAB_SIZE)
        tab:SetBackdrop({
            bgFile = "Interface/Tooltips/UI-Tooltip-Background",
            edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
            edgeSize = 8,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        tab:SetBackdropColor(0, 0, 0, 0.6)
        tab:SetHighlightTexture("Interface/QuestFrame/UI-QuestTitleHighlight", "ADD")

        local icon = tab:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", 2, -2)
        icon:SetPoint("BOTTOMRIGHT", -2, 2)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        icon:SetTexture(info.icon or "Interface/Icons/INV_Misc_QuestionMark")

        if previous then
            tab:SetPoint("LEFT", previous, "RIGHT", TAB_GAP, 0)
        else
            tab:SetPoint("BOTTOMLEFT", bar, "TOPLEFT", 0, TAB_GAP)
        end

        tab:SetScript("OnClick", function()
            -- A single call sometimes only opens the options root instead
            -- of the target subcategory; calling twice reliably lands on
            -- it (a known quirk of Settings.OpenToCategory).
            Settings.OpenToCategory(info.id)
            Settings.OpenToCategory(info.id)
        end)
        tab:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(info.name)
            GameTooltip:Show()
        end)
        tab:SetScript("OnLeave", function() GameTooltip:Hide() end)

        previous = tab
    end
end

function ns.InitBar()
    local pos = ns.db.barPosition
    bar:ClearAllPoints()
    bar:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
    if ns.db.barShown then bar:Show() else bar:Hide() end
    CreateSettingsTabs()
    RefreshBar()
end
