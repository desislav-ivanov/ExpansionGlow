local _, ns = ...

-- Baganator draws its own bag and bank views, and its item buttons call the
-- ItemButton method SetItemButtonQuality rather than the global one. The global
-- delegates down to the method, never the reverse, so the hook in Blizzard.lua
-- does not see these buttons and each one has to be hooked individually.
--
-- Baganator hands every region it builds to its skin listeners, which is how
-- its own bundled skins hook the same method. Registering as a listener gets us
-- item buttons as they are created; GetAllFrames covers any built before now.
--
-- OptionalDeps in the TOC puts Baganator ahead of us in the load order, so if
-- it is enabled at all its API exists by the time this file runs.

if not Baganator or not Baganator.API or not Baganator.API.Skins then
  return
end

local function HasTag(tags, wanted)
  if tags then
    for _, tag in ipairs(tags) do
      if tag == wanted then
        return true
      end
    end
  end
  return false
end

local function OnRegionAdded(details)
  if details.regionType ~= "ItemButton" then
    return
  end

  local button = details.region

  -- containerBag marks the equipped-bag icons on the bag bar. Those show a bag,
  -- not the contents of a slot. Remember the decision: Baganator registers its
  -- cached bag slots twice, tagged and then untagged, so skipping on the tag
  -- alone lets the second registration hook the bag bar anyway.
  if HasTag(details.tags, "containerBag") then
    button.expansionGlowSkip = true
    return
  end

  if button.expansionGlowSkip or button.expansionGlowHooked
      or not button.SetItemButtonQuality then
    return
  end
  button.expansionGlowHooked = true

  -- Go by what the button was told to show rather than by the slot it is bound
  -- to. Baganator's stacked "empty slots" button keeps a real bag and slot but
  -- draws nothing, so the slot is not a safe source here.
  hooksecurefunc(button, "SetItemButtonQuality", function(self, quality, itemIDOrLink)
    ns.UpdateButtonFromQuality(self, quality, itemIDOrLink)
  end)
end

for _, details in ipairs(Baganator.API.Skins.GetAllFrames()) do
  OnRegionAdded(details)
end

Baganator.API.Skins.RegisterListener(OnRegionAdded)
