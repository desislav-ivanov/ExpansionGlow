local _, ns = ...

-- Bagnon builds its own item buttons and refreshes each one through
-- Bagnon.Item:Update, which is the documented hook other addons use to decorate
-- them. One hook on the shared class covers every button Bagnon ever creates,
-- including bags, bank, guild bank and its cached views of other characters.
--
-- Bagnon's cached views show items that are not in a container slot this
-- character can read, so the item has to come from the button rather than from
-- C_Container. GetItem returns the item link when there is one.

if not Bagnon or not Bagnon.Item then
  return
end

hooksecurefunc(Bagnon.Item, "Update", function(button)
  local itemID

  local link = button.GetItem and button:GetItem()
  if not link and button.GetInfo then
    local info = button:GetInfo()
    link = info and info.link
  end

  if link then
    itemID = (C_Item.GetItemInfoInstant(link))
  end

  ns.UpdateButtonWithItem(button, itemID)
end)
