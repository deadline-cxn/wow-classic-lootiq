local ADDON_NAME, ns = ...

-- Sells every bag item on the Always Vendor List whenever a merchant window
-- opens. UseContainerItem is the same call the default UI makes for a
-- right-click on a bag item; with a merchant window open, that sells the
-- item to the vendor rather than using it, even for items with a use effect.
local function SellAlwaysVendorItems()
    if not ns.db.autoVendorEnabled then return end

    local sold, totalValue = 0, 0
    for bag = BACKPACK_CONTAINER, NUM_BAG_SLOTS do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID and ns.db.alwaysVendor[info.itemID] then
                local sellPrice = select(11, GetItemInfo(info.itemID))
                if sellPrice and sellPrice > 0 then
                    totalValue = totalValue + sellPrice * info.stackCount
                end
                C_Container.UseContainerItem(bag, slot)
                sold = sold + 1
            end
        end
    end
    if sold > 0 then
        ns.DebugPrint("sold %d always-vendor item stack(s) for %s.", sold, ns.FormatPrice(totalValue))
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("MERCHANT_SHOW")
frame:SetScript("OnEvent", SellAlwaysVendorItems)

-- Reverse direction from the Always Vendor List itself: instead of curating
-- the list by hand, watch what the player actually sells to a vendor (by
-- any method - right-click, shift-click, or dragging onto the merchant
-- window all funnel through this same call) and, if its quality is at or
-- below the configured ceiling, add it to the list so future copies get
-- auto-sold too. hooksecurefunc fires after the sell request is issued but
-- before the server confirms it, so the item is still in that bag/slot -
-- and fires for every caller including our own SellAlwaysVendorItems
-- above, which is harmless since an already-listed item is skipped.
local function OnContainerItemUsed(bag, slot)
    if not (ns.db.autoLearnVendorEnabled and MerchantFrame and MerchantFrame:IsShown()) then return end

    local itemID = C_Container.GetContainerItemID(bag, slot)
    if not itemID or ns.db.alwaysVendor[itemID] then return end

    local name, _, quality = GetItemInfo(itemID)
    if not (quality and quality <= ns.db.autoLearnVendorMaxQuality) then return end

    ns.db.alwaysVendor[itemID] = true
    print(("|cff33ff99LootIQ|r: added %s to the Always Vendor List (sold to a vendor)."):format(name or ("item:" .. itemID)))
end
hooksecurefunc(C_Container, "UseContainerItem", OnContainerItemUsed)

-- Mirror of the learning above: buying an item back means the player
-- didn't actually want it gone, so take it off the Always Vendor List -
-- unconditionally, regardless of the auto-learn toggle, since this is
-- undoing a listing rather than creating one. GetBuybackItemLink(index)
-- still reflects the bought-back item here even though the hook fires
-- after BuybackItem's call: the buyback list only reshuffles once
-- MERCHANT_UPDATE fires after the server confirms the purchase, which
-- hasn't happened yet at this point.
local function OnItemBoughtBack(index)
    local link = GetBuybackItemLink(index)
    local itemID = link and tonumber(link:match("item:(%d+)"))
    if not itemID or not ns.db.alwaysVendor[itemID] then return end

    ns.db.alwaysVendor[itemID] = nil
    print(("|cff33ff99LootIQ|r: removed %s from the Always Vendor List (bought back from a vendor)."):format(link))
end
hooksecurefunc("BuybackItem", OnItemBoughtBack)
