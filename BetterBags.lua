local _, ns = ...

-- BetterBags exposes an Events module that broadcasts 'item/Updated' for every
-- item cell it refreshes, which is the documented decoration point. The message
-- carries an item wrapper rather than a raw button: the frame to draw on is
-- item.button (or item.button.frame on some cell types), and the bag and slot
-- live on item.data.

if not C_AddOns.IsAddOnLoaded("BetterBags") or not LibStub then
  return
end

local aceAddon = LibStub("AceAddon-3.0", true)
if not aceAddon then
  return
end

-- Both lookups pass the silent flag, which returns nil instead of erroring when
-- the name is not registered.
local betterBags = aceAddon:GetAddon("BetterBags", true)
if not betterBags then
  return
end

local events = betterBags.GetModule and betterBags:GetModule("Events", true)
if not events or not events.RegisterMessage then
  return
end

local function OnItemUpdated(_, item)
  if not item or not item.button then
    return
  end

  local button = item.button.frame or item.button
  local data = item.data
  local itemID

  if data then
    if data.bagid and data.slotid then
      itemID = C_Container.GetContainerItemID(data.bagid, data.slotid)
    end
    if not itemID and data.itemInfo then
      itemID = data.itemInfo.itemID
    end
  end

  ns.UpdateButtonWithItem(button, itemID)
end

events:RegisterMessage("item/Updated", OnItemUpdated)
