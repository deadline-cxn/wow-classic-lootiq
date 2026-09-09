local ADDON_NAME, ns = ...

local ROW_HEIGHT = 20
local LIST_WIDTH = 200
local DETAIL_WIDTH = 380

-- Small "-" button for removing a single entry from a detail-pane list -
-- currently only wired up for a gathering zone's item list (see
-- Mining.lua/Herbalism.lua's RenderDetail), to manually correct a
-- mis-attributed item (e.g. an herb that got recorded into a mining zone
-- because the two gathering casts happened close enough together to
-- overlap - see their FALLBACK_WINDOW comments). Only shown when AddRow's
-- onRemove param is given; the actual removal is the caller's, since each
-- gathering file owns its own store.
local function CreateRemoveButton(parent)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(16, 16)
    btn:SetNormalTexture("Interface/Buttons/UI-MinusButton-Up")
    btn:SetPushedTexture("Interface/Buttons/UI-MinusButton-Down")
    btn:SetHighlightTexture("Interface/Buttons/UI-MinusButton-Hilight", "ADD")
    return btn
end

-- Builds a two-pane "browse a list, click one to see details" settings
-- subcategory: a scrollable list on the left with click-to-select
-- highlighting, and a scrollable detail pane on the right that's
-- (re)rendered whenever the selection changes. Shared by the Creature
-- Database and Item Database panels - only what goes in each row and the
-- detail pane differs between them.
--
-- opts fields:
--   extraSetup(panel, title) -> anchorFrame (optional) - for extra
--     controls above the list, same convention as OptionsLists.lua's
--     BuildListPanel. Defaults to anchoring the list under the title.
--   listLabel, emptyListText, emptyDetailText -> display strings.
--   getIDs() -> array of IDs to list, already in the order they should
--     appear.
--   getListLabel(id) -> string label for id's row in the list.
--   getRowItemLink(id) -> optional; returns itemLink, iconTexture for id's
--     row. When given, each list row gets an "add to loot bar" button
--     (Item Database only - Source Database's rows are creatures/vendors,
--     not items, so it omits this).
--   renderDetail(id, detail) -> populate the detail pane for id. `detail`
--     exposes detail:AddRow(text, fontObject, color, iconTexture, itemLink,
--     onClick, onRemove) for a single line - itemLink is optional (when
--     given, the row gets an "add to loot bar" button), so is onClick (when
--     given, the whole row becomes clickable, e.g. to jump to another
--     panel), and so is onRemove (when given, the row gets a "-" button
--     that calls it - no args, the caller's closure already knows what to
--     remove); detail:AddSection(title, store, kills, onRemove) for the
--     common "sorted drops/skins list with occurrence %" shape (a
--     drops/skins-shaped store per Loot.lua's RecordDropInto) - onRemove
--     here is called as onRemove(itemID) per row, e.g. to let a gathering
--     zone's item list be manually corrected (see Mining.lua/
--     Herbalism.lua); and detail:AddVendorSells(title, store) for a
--     vendor's sale catalog (a store shaped [itemID] = {link, price} - see
--     Loot.lua's RecordVendorSells), sorted alphabetically and showing the
--     vendor's price per item instead of a percentage, since a vendor
--     doesn't have a "chance" to sell something. Every entry in any of
--     these gets the add-to-bar button, and is itself clickable to jump to
--     that item's Item Database entry.
--   isValidID(id) -> whether a previously-selected id is still valid;
--     checked on every show so a stale selection (e.g. after a "clear
--     database" button) doesn't render leftover detail.
--   onShow() -> optional, called every time the panel is shown (e.g. to
--     sync extra checkboxes added via extraSetup).
--   showModel -> optional; when true, shows a 3D model preview above the
--     detail pane, set via PlayerModel:SetCreature(creatureID). The
--     creatureID to preview is `id` itself by default (Source Database),
--     or getModelCreatureID(id)'s result when given - for panels like Item
--     Database whose id isn't already a creatureID.
--   getModelCreatureID(id) -> optional, only consulted when showModel is
--     true; returns creatureID, fallbackIcon. creatureID previews that
--     creature's model; when it's nil, fallbackIcon (a texture path) is
--     shown in the model's place instead (e.g. Trade_Fishing for an item
--     only ever fished up, never looted/skinned from a creature), or
--     nothing at all if fallbackIcon is also nil (no known source yet).
--   icon -> texture path shown on the loot bar's tab strip for this panel
--     (see Bar.lua).
--
-- Returns the panel, a Select(id) function (id may be nil to clear the
-- selection) so callers can drive selection themselves, and a GoTo(id)
-- function that navigates the Settings UI to this panel and selects id
-- there (for a different panel's detail row to link into this one).
function ns.BuildBrowserPanel(panelName, opts)
    local panel = CreateFrame("Frame")
    panel.name = panelName

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(panelName)

    local anchorFrame = title
    if opts.extraSetup then
        anchorFrame = opts.extraSetup(panel, title) or title
    end

    -- opts.searchable opts a panel into a filter box above its list -
    -- currently just the Item and Source Databases (see ItemDatabase.lua/
    -- CreatureDatabase.lua), not every BuildBrowserPanel caller, so this
    -- only exists when asked for. SearchBoxTemplate brings its own
    -- magnifier icon, "Search..." placeholder, and clear (X) button; the
    -- OnTextChanged/OnEscapePressed hooks that actually filter the list are
    -- wired further down, once RefreshList exists to call.
    local searchBox
    if opts.searchable then
        searchBox = CreateFrame("EditBox", nil, panel, "SearchBoxTemplate")
        searchBox:SetSize(200, 20)
        searchBox:SetPoint("TOPLEFT", anchorFrame, "BOTTOMLEFT", 0, -12)
        searchBox:SetAutoFocus(false)
        anchorFrame = searchBox
    end

    local listLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    listLabel:SetPoint("TOPLEFT", anchorFrame, "BOTTOMLEFT", 0, -20)
    listLabel:SetText(opts.listLabel or "Click one to see details:")

    local listScroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    listScroll:SetPoint("TOPLEFT", listLabel, "BOTTOMLEFT", 0, -8)
    listScroll:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 16, 16)
    listScroll:SetWidth(LIST_WIDTH)

    local listContent = CreateFrame("Frame", nil, listScroll)
    listContent:SetSize(LIST_WIDTH, ROW_HEIGHT)
    listScroll:SetScrollChild(listContent)

    -- opts.showModel puts a 3D model preview (or, absent a creature to
    -- preview, a plain fallback icon - see modelFallbackIcon below) above
    -- the detail row list. It's a fixed element outside the scrollable
    -- detail area, not a row, since it shouldn't scroll away with the drops
    -- list beneath it. Every creature here was actually encountered live
    -- (that's how it got recorded at all), so a plain SetCreature(creatureID)
    -- can resolve it from the client's own cached NPC data without needing
    -- a bundled display-ID database.
    local modelFrame, modelFallbackIcon
    if opts.showModel then
        modelFrame = CreateFrame("PlayerModel", nil, panel, "BackdropTemplate")
        modelFrame:SetSize(220, 220)
        modelFrame:SetPoint("TOPLEFT", listScroll, "TOPRIGHT", 40, 0)
        modelFrame:SetBackdrop({
            bgFile = "Interface/Tooltips/UI-Tooltip-Background",
            edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
            edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        modelFrame:SetBackdropColor(0, 0, 0, 0.6)
        modelFrame:Hide()

        -- Same creature tooltip as a Source Database list row (see
        -- GetListRow's rowCreatureTooltip branch) - modelFrame.creatureID
        -- is kept up to date in RefreshDetailPane below, for both the
        -- Source Database (previewing the record itself) and the Item
        -- Database (previewing an item's primary source creature via
        -- opts.getModelCreatureID).
        modelFrame:EnableMouse(true)
        modelFrame:SetScript("OnEnter", function(self)
            if not self.creatureID then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(ns.GetCreatureDisplayName(self.creatureID))
            ns.AddDropLines(GameTooltip, self.creatureID)
            GameTooltip:Show()
        end)
        modelFrame:SetScript("OnLeave", function() GameTooltip:Hide() end)

        -- Default camera distance frames a human-sized model fine but
        -- crops a much bigger one (e.g. a Rock Elemental) at this frame's
        -- size - pulling the camera back fits both. 2 (down from an
        -- earlier 3) trades a little of that headroom for a bigger-looking
        -- model in this smaller frame; the very largest outliers may crop
        -- slightly again. Same idea AtlasLoot uses for its own
        -- creature-model preview, another installed addon that shows
        -- everything from critters to raid bosses in one fixed-size frame.
        modelFrame:SetCamDistanceScale(2)

        -- Shown instead of the model for an item with a known non-creature
        -- source (e.g. fished up rather than looted/skinned from anything) -
        -- see getModelCreatureID's second return value.
        modelFallbackIcon = modelFrame:CreateTexture(nil, "OVERLAY")
        modelFallbackIcon:SetSize(90, 90)
        modelFallbackIcon:SetPoint("CENTER")
        modelFallbackIcon:Hide()
    end

    local detailScroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    if modelFrame then
        detailScroll:SetPoint("TOPLEFT", modelFrame, "BOTTOMLEFT", 0, -12)
    else
        detailScroll:SetPoint("TOPLEFT", listScroll, "TOPRIGHT", 40, 0)
    end
    detailScroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -30, 16)

    local detailContent = CreateFrame("Frame", nil, detailScroll)
    detailContent:SetSize(DETAIL_WIDTH, ROW_HEIGHT)
    detailScroll:SetScrollChild(detailContent)

    local emptyDetailText = detailContent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    emptyDetailText:SetPoint("TOPLEFT", 4, 0)
    emptyDetailText:SetTextColor(0.6, 0.6, 0.6)
    emptyDetailText:SetText(opts.emptyDetailText or "Select an entry from the list to see its details.")

    local selectedID = nil
    local listRows = {}
    local detailRows = {}
    local Select -- forward-declared: list row OnClick handlers close over it

    local function GetListRow(index)
        local row = listRows[index]
        if row then return row end

        row = CreateFrame("Button", nil, listContent)
        row:SetSize(LIST_WIDTH, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", listContent, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
        row:SetHighlightTexture("Interface/QuestFrame/UI-QuestTitleHighlight", "ADD")

        local selectedTexture = row:CreateTexture(nil, "BACKGROUND")
        selectedTexture:SetAllPoints()
        selectedTexture:SetColorTexture(0.3, 0.5, 1, 0.25)
        selectedTexture:Hide()
        row.selectedTexture = selectedTexture

        local text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        text:SetPoint("LEFT", 4, 0)
        text:SetJustifyH("LEFT")
        row.text = text

        if opts.getRowItemLink then
            local addToBarButton = ns.CreateAddToBarButton(row)
            addToBarButton:SetPoint("RIGHT", -2, 0)
            row.addToBarButton = addToBarButton
            text:SetPoint("RIGHT", addToBarButton, "LEFT", -2, 0)

            -- Only a panel whose list rows ARE items (currently just the
            -- Item Database - opts.getRowItemLink is what marks that,
            -- same signal the add-to-bar button above keys off) gets the
            -- real item tooltip on hover; a Source Database row is a
            -- creature/vendor, not an item, so it has no getRowItemLink
            -- and no hyperlink to show here. Reads the link off the
            -- add-to-bar button rather than re-deriving it, since
            -- RefreshList already resolved it there for this exact row.
            row:SetScript("OnEnter", function(self)
                local link = self.addToBarButton and self.addToBarButton.link
                if not link then return end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(link)
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        elseif opts.rowCreatureTooltip then
            -- Source Database only: its list rows ARE creature/vendor IDs
            -- directly (unlike Item Database's, which need getRowItemLink
            -- to resolve an id to a link), so this builds the header line
            -- Blizzard would normally add for a live unit, then appends the
            -- same kills/drops/skins/value lines ns.AddDropLines already
            -- shows on that creature's real in-world tooltip.
            text:SetPoint("RIGHT", -4, 0)
            row:SetScript("OnEnter", function(self)
                if not self.entryID then return end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine(ns.GetCreatureDisplayName(self.entryID))
                ns.AddDropLines(GameTooltip, self.entryID)
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        else
            text:SetPoint("RIGHT", -4, 0)
        end

        row:SetScript("OnClick", function(self)
            if self.entryID ~= nil then Select(self.entryID) end
        end)

        listRows[index] = row
        return row
    end

    local function GetDetailRow(index)
        local row = detailRows[index]
        if row then return row end

        -- A Button (not a plain Frame) so an individual row can opt into
        -- being clickable (see AddRow's onClick param) - mouse stays
        -- disabled by default so a non-clickable row (most of them) behaves
        -- exactly as a plain Frame would.
        row = CreateFrame("Button", nil, detailContent)
        row:SetSize(DETAIL_WIDTH, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", detailContent, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
        row:SetHighlightTexture("Interface/QuestFrame/UI-QuestTitleHighlight", "ADD")
        row:EnableMouse(false)

        -- row.itemLink is (re)set by AddRow below on every render - shows
        -- the real item tooltip for any detail row carrying one (a
        -- creature's drops/skins/sells, a chest's contents, a gathering
        -- zone's catches, etc. - anywhere AddRow's itemLink param is given).
        row:SetScript("OnEnter", function(self)
            if not self.itemLink then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(self.itemLink)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)

        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(16, 16)
        icon:SetPoint("LEFT", 0, 0)
        row.icon = icon

        -- Anchored on every use below (position depends on whether that
        -- row has an icon), so no point is set here.
        local text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        text:SetJustifyH("LEFT")
        row.text = text

        row.addToBarButton = ns.CreateAddToBarButton(row)
        row.addToBarButton:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        row.addToBarButton:Hide()

        row.removeButton = CreateRemoveButton(row)
        row.removeButton:SetPoint("RIGHT", row.addToBarButton, "LEFT", -2, 0)
        row.removeButton:Hide()

        detailRows[index] = row
        return row
    end

    local detailRowIndex -- current write position while rendering the detail pane

    local function AddRow(text, fontObject, color, iconTexture, itemLink, onClick, onRemove)
        local row = GetDetailRow(detailRowIndex)

        row:EnableMouse(onClick ~= nil or itemLink ~= nil)
        row:SetScript("OnClick", onClick)
        row.itemLink = itemLink

        row.text:ClearAllPoints()
        if iconTexture then
            row.icon:SetTexture(iconTexture)
            row.icon:Show()
            row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        else
            row.icon:Hide()
            row.text:SetPoint("LEFT", row, "LEFT", 0, 0)
        end

        if itemLink then
            row.addToBarButton.link = itemLink
            row.addToBarButton.icon = iconTexture
            row.addToBarButton:Show()
        else
            row.addToBarButton:Hide()
        end

        if onRemove then
            row.removeButton:SetScript("OnClick", onRemove)
            row.removeButton:Show()
        else
            row.removeButton:Hide()
        end

        -- Text's right edge anchors to whichever button is leftmost among
        -- the ones actually shown (remove sits left of add-to-bar - see
        -- GetDetailRow), or the row's own edge if neither is shown.
        if onRemove then
            row.text:SetPoint("RIGHT", row.removeButton, "LEFT", -4, 0)
        elseif itemLink then
            row.text:SetPoint("RIGHT", row.addToBarButton, "LEFT", -4, 0)
        else
            row.text:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        end

        row.text:SetFontObject(fontObject or "GameFontHighlightSmall")
        color = color or { 1, 1, 1 }
        row.text:SetTextColor(color[1], color[2], color[3])
        row.text:SetText(text)

        row:Show()
        detailRowIndex = detailRowIndex + 1
    end

    -- onRemove is optional - given by a gathering zone's item list (see
    -- Mining.lua/Herbalism.lua's RenderDetail) to let the player manually
    -- correct a mis-attributed item; omitted by creature drops/skins,
    -- which have no such removal concept.
    local function AddSection(sectionTitle, store, kills, onRemove)
        local items = ns.SortedDrops(store)
        if #items == 0 then return end

        AddRow(sectionTitle, "GameFontNormal", { 0.5, 0.8, 1 })
        for _, d in ipairs(items) do
            local pct = kills > 0 and (d.occurrences / kills * 100) or 0
            local _, _, _, _, _, _, _, _, _, texture = GetItemInfo(d.link)
            local text = ("%s x%d  (%.0f%%)  -  %s"):format(d.link, d.count, pct, ns.FormatSellAndAHPrice(d.link))
            local icon = texture or "Interface/Icons/INV_Misc_QuestionMark"

            -- Blue like a hyperlink, to read as clickable - jumps to that
            -- item's own Item Database entry. Uses ns.GetItemKey (not a
            -- bare itemID parsed from the link) so this matches whatever
            -- key the item is actually stored under - a random-suffix item
            -- ("of the Monkey") is keyed separately from other rolls of the
            -- same base item (see Core.lua's ns.GetItemKey), and onRemove
            -- needs the SAME key the store itself uses or it would delete
            -- (or fail to delete) the wrong entry.
            local key = ns.GetItemKey(d.link)
            if key then
                AddRow(text, nil, { 0.4, 0.7, 1 }, icon, d.link, function() ns.GoToItemDatabaseEntry(key) end,
                    onRemove and function() onRemove(key) end)
            else
                AddRow(text, nil, nil, icon, d.link)
            end
        end
    end

    -- For a vendor's sale catalog (store shaped [itemID] = {link, price} -
    -- see Loot.lua's RecordVendorSells) rather than an occurrence-counted
    -- drops/skins store: there's no "chance" to rank by (a vendor doesn't
    -- occasionally sell something, it just does), so this sorts
    -- alphabetically by item name and shows the vendor's price instead of
    -- a percentage.
    local function AddVendorSells(sectionTitle, store)
        local entries = {}
        for itemID, data in pairs(store) do
            table.insert(entries, { itemID = itemID, link = data.link, price = data.price })
        end
        if #entries == 0 then return end
        table.sort(entries, function(a, b) return (GetItemInfo(a.link) or "") < (GetItemInfo(b.link) or "") end)

        AddRow(sectionTitle, "GameFontNormal", { 0.5, 0.8, 1 })
        for _, e in ipairs(entries) do
            local _, _, _, _, _, _, _, _, _, texture = GetItemInfo(e.link)
            local icon = texture or "Interface/Icons/INV_Misc_QuestionMark"
            local text = ("%s - %s"):format(e.link, ns.FormatSellVendorAndAHPrice(e.price or 0, e.link))
            AddRow(text, nil, { 0.4, 0.7, 1 }, icon, e.link, function() ns.GoToItemDatabaseEntry(e.itemID) end)
        end
    end

    local detailAPI = {
        AddRow = function(_, ...) AddRow(...) end,
        AddSection = function(_, ...) AddSection(...) end,
        AddVendorSells = function(_, ...) AddVendorSells(...) end,
    }

    local function RefreshDetailPane(id)
        if id == nil then
            for _, row in ipairs(detailRows) do row:Hide() end
            detailContent:SetHeight(ROW_HEIGHT)
            emptyDetailText:Show()
            if modelFrame then
                modelFrame:Hide()
                modelFallbackIcon:Hide()
                modelFrame.creatureID = nil
            end
            return
        end
        emptyDetailText:Hide()

        if modelFrame then
            -- getModelCreatureID's second return (a fallback icon texture)
            -- only matters when the first is nil, so destructure both
            -- rather than the old `f() or id` one-liner, which silently
            -- discarded it (Lua's `and/or` only ever keeps one value).
            local creatureID, fallbackIcon
            if opts.getModelCreatureID then
                creatureID, fallbackIcon = opts.getModelCreatureID(id)
            else
                creatureID = id
            end
            modelFrame.creatureID = creatureID

            if creatureID then
                modelFrame:SetCreature(creatureID)
                modelFrame:SetPosition(0, 0, 0)
                modelFrame:Show()
                modelFallbackIcon:Hide()
            elseif fallbackIcon then
                modelFrame:ClearModel()
                modelFrame:Show()
                modelFallbackIcon:SetTexture(fallbackIcon)
                modelFallbackIcon:Show()
            else
                modelFrame:Hide()
                modelFallbackIcon:Hide()
            end
        end

        detailRowIndex = 1
        opts.renderDetail(id, detailAPI)

        for i = detailRowIndex, #detailRows do
            detailRows[i]:Hide()
        end
        detailContent:SetHeight(math.max(ROW_HEIGHT, (detailRowIndex - 1) * ROW_HEIGHT))
    end

    Select = function(id)
        selectedID = id
        for _, row in ipairs(listRows) do
            row.selectedTexture:SetShown(row.entryID == id)
        end
        RefreshDetailPane(id)
    end

    local function RefreshList()
        local ids = opts.getIDs()

        -- Case-insensitive substring match against each row's own label
        -- (already includes the display name, plus whatever count/suffix
        -- that panel appends - e.g. "(5 kills)" or "(vendor)" - matching
        -- against those too is harmless and occasionally useful).
        local filter = searchBox and searchBox:GetText()
        local isFiltered = filter and filter ~= ""
        if isFiltered then
            filter = filter:lower()
            local matched = {}
            for _, id in ipairs(ids) do
                if opts.getListLabel(id):lower():find(filter, 1, true) then
                    table.insert(matched, id)
                end
            end
            ids = matched
        end

        if #ids == 0 then
            local row = GetListRow(1)
            row.entryID = nil
            row.text:SetText(isFiltered and "(no matches)" or (opts.emptyListText or "(none recorded yet)"))
            row.selectedTexture:Hide()
            if row.addToBarButton then row.addToBarButton:Hide() end
            row:Show()
            for i = 2, #listRows do listRows[i]:Hide() end
            listContent:SetHeight(ROW_HEIGHT)
            return
        end

        for i, id in ipairs(ids) do
            local row = GetListRow(i)
            row.entryID = id
            row.text:SetText(opts.getListLabel(id))
            row.selectedTexture:SetShown(id == selectedID)
            if row.addToBarButton then
                local link, icon = opts.getRowItemLink(id)
                row.addToBarButton.link = link
                row.addToBarButton.icon = icon
                row.addToBarButton:SetShown(link ~= nil)
            end
            row:Show()
        end
        for i = #ids + 1, #listRows do
            listRows[i]:Hide()
        end
        listContent:SetHeight(#ids * ROW_HEIGHT)
    end

    if searchBox then
        -- Hooked (not set) so the template's own OnTextChanged handler -
        -- which manages the placeholder text and the clear (X) button's
        -- visibility - still runs.
        searchBox:HookScript("OnTextChanged", RefreshList)
        -- Esc wipes the filter rather than merely dropping focus, which is
        -- what a user pressing Esc on a search box means.
        searchBox:HookScript("OnEscapePressed", function(self)
            self:SetText("")
            self:ClearFocus()
            RefreshList()
        end)
    end

    -- Re-run on every show (the underlying data changes constantly during
    -- play and should reflect whatever's happened since the panel was last
    -- opened) AND once upfront via ns.OptionsRefreshers, since a panel's
    -- first-ever display doesn't fire OnShow (see Core.lua) - without that
    -- upfront call the list would sit empty until the player tabbed away
    -- and back.
    local function RefreshAll()
        if opts.onShow then opts.onShow() end
        if selectedID ~= nil and opts.isValidID and not opts.isValidID(selectedID) then
            selectedID = nil
        end
        RefreshList()
        RefreshDetailPane(selectedID)
    end
    panel:SetScript("OnShow", RefreshAll)
    table.insert(ns.OptionsRefreshers, RefreshAll)

    local subcategory = Settings.RegisterCanvasLayoutSubcategory(ns.OptionsCategory, panel, panelName)
    table.insert(ns.SettingsPanels, {
        name = panelName,
        id = subcategory:GetID(),
        icon = opts.icon,
    })

    -- Navigates to this panel and selects id there - for another panel's
    -- detail row to jump to a specific entry here (see ItemDatabase.lua's
    -- source rows linking into the Source Database).
    local function GoTo(id)
        Select(id)
        -- A single call sometimes only opens the options root instead of
        -- the target subcategory; calling twice reliably lands on it (a
        -- known quirk of Settings.OpenToCategory - see Bar.lua's tab strip).
        Settings.OpenToCategory(subcategory:GetID())
        Settings.OpenToCategory(subcategory:GetID())
    end

    return panel, Select, GoTo
end
