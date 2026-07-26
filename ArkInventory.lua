local _, ns = ...

-- ArkInventory is the one bag addon here with a purpose-built decoration API.
-- ItemFrameUpdated fires per button whenever its contents change, and
-- ItemFrameLoadedIterate walks the buttons that already exist, which covers the
-- ones built before this file ran.
--
-- Its buttons carry the Blizzard bag and slot on ARK_Data, which Core reads
-- directly, so there is no item lookup to do here.

local function Setup()
  local api = ArkInventory and ArkInventory.API
  if not api or not api.ItemFrameUpdated or not api.ItemFrameLoadedIterate then
    return
  end

  hooksecurefunc(api, "ItemFrameUpdated", function(frame)
    if frame then
      ns.UpdateButton(frame)
    end
  end)

  for _, frame in api.ItemFrameLoadedIterate() do
    if frame then
      ns.UpdateButton(frame)
    end
  end
end

if C_AddOns.IsAddOnLoaded("ArkInventory") then
  Setup()
else
  -- ArkInventory is load-on-demand for some users, so it can arrive after us
  -- even with OptionalDeps declared.
  local loader = CreateFrame("Frame")
  loader:RegisterEvent("ADDON_LOADED")
  loader:SetScript("OnEvent", function(self, _, addon)
    if addon == "ArkInventory" then
      self:UnregisterEvent("ADDON_LOADED")
      Setup()
    end
  end)
end
