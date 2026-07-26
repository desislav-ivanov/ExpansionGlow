local _, ns = ...

-- ElvUI replaces the bags and bank with its own frames and refreshes each slot
-- through the Bags module's UpdateSlot, which runs for bags and bank alike.
--
-- Hooking that is necessary rather than merely convenient: ElvUI caches the
-- global SetItemButtonQuality into a file-local at load, so the hook in
-- Blizzard.lua never sees ElvUI's calls whenever ElvUI loads before this addon.
--
-- ElvUI stores the slot's bag and index as BagID and SlotID, capitalised
-- deliberately to dodge the taint that the lowercase names pick up through
-- ContainerFrameItemButtonMixin, and Core reads those directly.

local function Setup()
  if not ElvUI then
    return
  end

  local E = unpack(ElvUI)
  local bags = E and E.GetModule and E:GetModule("Bags", true)
  if not bags or not bags.UpdateSlot then
    return
  end

  hooksecurefunc(bags, "UpdateSlot", function(_, frame, bagID, slotID)
    local bag = frame and frame.Bags and frame.Bags[bagID]
    local slot = bag and bag[slotID]
    if slot then
      ns.UpdateButton(slot)
    end
  end)
end

if C_AddOns.IsAddOnLoaded("ElvUI") then
  Setup()
else
  local loader = CreateFrame("Frame")
  loader:RegisterEvent("ADDON_LOADED")
  loader:SetScript("OnEvent", function(self, _, addon)
    if addon == "ElvUI" then
      self:UnregisterEvent("ADDON_LOADED")
      Setup()
    end
  end)
end
