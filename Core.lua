local addonName, ns = ...

-- Expansion age tiers, relative to LE_EXPANSION_LEVEL_CURRENT.
-- prev1/2/3 are the three expansions immediately before the current one;
-- ancient covers everything four or more expansions back.
local TIER_ORDER = {"prev1", "prev2", "prev3", "ancient"}

local TIER_LABEL = {
  prev1 = "one expansion back",
  prev2 = "two expansions back",
  prev3 = "three expansions back",
  ancient = "four or more expansions back",
}

ns.TIER_ORDER = TIER_ORDER
ns.TIER_LABEL = TIER_LABEL

local DEFAULTS = {
  enabled = true,
  style = "tint",   -- "tint" colours the icon, "border" outlines the slot
  tintAlpha = 0.65, -- base opacity of the tint style
  thickness = 2,    -- border style: outline width in pixels
  outset = 1,       -- border style: pixels outside the button edge
  -- itemID -> expacID, persisted. An item's expansion never changes, so this
  -- only ever grows as new items are seen. expacID is stored rather than the
  -- tier because the tier is relative to LE_EXPANSION_LEVEL_CURRENT and every
  -- cached tier would be wrong the day a new expansion ships.
  itemExpansion = {},
  tiers = {
    prev1   = {enabled = true, color = {0.20, 0.80, 0.20, 1.00}},
    prev2   = {enabled = true, color = {1.00, 0.80, 0.00, 1.00}},
    prev3   = {enabled = true, color = {1.00, 0.25, 0.25, 1.00}},
    ancient = {enabled = true, color = {0.55, 0.55, 0.62, 0.70}},
  },
}

local db

local function CopyDefaults(src, dst)
  for key, value in pairs(src) do
    if type(value) == "table" then
      dst[key] = type(dst[key]) == "table" and dst[key] or {}
      CopyDefaults(value, dst[key])
    elseif dst[key] == nil then
      dst[key] = value
    end
  end
end

-- Item expansion lookup -------------------------------------------------------

-- itemIDs whose data was not cached yet the first time we looked at them.
local awaitingItemData = {}

local function ResolveTier(itemID)
  local expacID = db.itemExpansion[itemID]

  if expacID == nil then
    -- 15th return of GetItemInfo is expacID; nil until the client caches the item.
    expacID = select(15, C_Item.GetItemInfo(itemID))
    if expacID == nil then
      if not awaitingItemData[itemID] then
        awaitingItemData[itemID] = true
        C_Item.RequestLoadItemDataByID(itemID)
      end
      return nil
    end
    db.itemExpansion[itemID] = expacID
  end

  local age = LE_EXPANSION_LEVEL_CURRENT - expacID
  if age == 1 then
    return "prev1"
  elseif age == 2 then
    return "prev2"
  elseif age == 3 then
    return "prev3"
  elseif age >= 4 then
    return "ancient"
  end
  return nil
end

-- Markers ---------------------------------------------------------------------

-- Both styles paint only with textures this addon creates and owns. Neither
-- reads nor writes a region belonging to Blizzard or another addon (IconBorder,
-- IconOverlay, NewItemTexture, the flash animation, search overlays, corner
-- widgets), so nothing else's glow is disturbed.
--
-- tint:   one texture on the button itself in the ARTWORK layer. The item icon
--         sits in BORDER and the quality border, item overlays and stack count
--         all sit in OVERLAY, so ARTWORK is the one layer that covers the icon
--         art without covering anything stacked on top of it. The cooldown
--         swirl is a child frame and stays above regardless.
-- border: a child frame above everything on the button, drawn as four edges so
--         it outlines the slot without hiding the icon at all.
--
-- Each button keeps a small table of whichever widgets it has needed so far.
local function GetWidgets(button)
  local widgets = button.ExpansionGlow
  if not widgets then
    widgets = {}
    button.ExpansionGlow = widgets
  end
  return widgets
end

-- Blizzard's GetItemButtonIconTexture falls back to a global name lookup that
-- errors on anonymous buttons, so read the two fields it checks directly.
local function GetIconTexture(button)
  return button.Icon or button.icon
end

local function CreateTint(button)
  local icon = GetIconTexture(button)
  if not icon then
    return false
  end
  local tint = button:CreateTexture(nil, "ARTWORK")
  tint:SetAllPoints(icon)
  tint:Hide()
  return tint
end

local function CreateBorder(button)
  local border = CreateFrame("Frame", nil, button)
  border:SetFrameLevel(button:GetFrameLevel() + 8)
  border:Hide()

  border.edges = {}
  for i = 1, 4 do
    border.edges[i] = border:CreateTexture(nil, "OVERLAY", nil, 7)
  end
  return border
end

local function LayoutBorder(border, button)
  local outset, thickness = db.outset, db.thickness
  if border.outset == outset and border.thickness == thickness then
    return
  end
  border.outset, border.thickness = outset, thickness

  border:ClearAllPoints()
  border:SetPoint("TOPLEFT", button, "TOPLEFT", -outset, outset)
  border:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", outset, -outset)

  local top, bottom, left, right = border.edges[1], border.edges[2], border.edges[3], border.edges[4]

  top:ClearAllPoints()
  top:SetPoint("TOPLEFT")
  top:SetPoint("TOPRIGHT")
  top:SetHeight(thickness)

  bottom:ClearAllPoints()
  bottom:SetPoint("BOTTOMLEFT")
  bottom:SetPoint("BOTTOMRIGHT")
  bottom:SetHeight(thickness)

  left:ClearAllPoints()
  left:SetPoint("TOPLEFT", 0, -thickness)
  left:SetPoint("BOTTOMLEFT", 0, thickness)
  left:SetWidth(thickness)

  right:ClearAllPoints()
  right:SetPoint("TOPRIGHT", 0, -thickness)
  right:SetPoint("BOTTOMRIGHT", 0, thickness)
  right:SetWidth(thickness)
end

local function ShowTint(button, widgets, tier)
  if widgets.border then
    widgets.border:Hide()
  end

  if widgets.tint == nil then
    widgets.tint = CreateTint(button)
  end
  local tint = widgets.tint
  if not tint then
    return
  end

  -- A tier's stored alpha is a weight, not a final opacity: the style supplies
  -- the base. That keeps ancient items subtler than the rest in both styles.
  if widgets.tintTier ~= tier or widgets.tintAlpha ~= db.tintAlpha then
    widgets.tintTier, widgets.tintAlpha = tier, db.tintAlpha
    local color = db.tiers[tier].color
    tint:SetColorTexture(color[1], color[2], color[3], color[4] * db.tintAlpha)
  end

  tint:Show()
end

local function ShowBorder(button, widgets, tier)
  if widgets.tint then
    widgets.tint:Hide()
  end

  local border = widgets.border
  if not border then
    border = CreateBorder(button)
    widgets.border = border
  end
  LayoutBorder(border, button)

  if widgets.borderTier ~= tier then
    widgets.borderTier = tier
    local color = db.tiers[tier].color
    for _, edge in ipairs(border.edges) do
      edge:SetColorTexture(color[1], color[2], color[3], color[4])
    end
  end

  border:Show()
end

local function ShowMarker(button, tier)
  local widgets = GetWidgets(button)
  if db.style == "border" then
    ShowBorder(button, widgets, tier)
  else
    ShowTint(button, widgets, tier)
  end
end

local function HideMarker(button)
  local widgets = button.ExpansionGlow
  if widgets then
    if widgets.tint then
      widgets.tint:Hide()
    end
    if widgets.border then
      widgets.border:Hide()
    end
  end
end

-- Button updates --------------------------------------------------------------

-- Weak keys so recycled or discarded buttons do not keep frames alive.
local trackedButtons = setmetatable({}, {__mode = "k"})

-- Returns the itemID shown by an item button, or nil if it holds no item.
--
-- The container slot is checked first because it is authoritative for anything
-- showing live inventory. Baganator's own item details are the fallback: they
-- are the only source in its cached views of other characters' bags, which are
-- not bound to a container slot at all.
local function ResolveItemID(button)
  -- bagID and bankTabID are only set once a button has been bound to a
  -- container slot, so reading them is what filters out the merchant, loot,
  -- mail and paperdoll buttons that route through the same hook. Read the
  -- fields rather than calling GetBagID(), whose documented fallback is the
  -- parent frame's ID -- that would report bag 0 (the backpack) for an unbound
  -- button whose parent has no ID.
  local bagID = button.bagID
  if bagID then
    return C_Container.GetContainerItemID(bagID, button:GetID())
  end

  local bankTabID = button.bankTabID
  if bankTabID then
    return C_Container.GetContainerItemID(bankTabID, button.containerSlotID)
  end

  local bgr = button.BGR
  if bgr then
    if bgr.itemID then
      return bgr.itemID
    elseif bgr.itemLink then
      return (C_Item.GetItemInfoInstant(bgr.itemLink))
    end
  end

  return nil
end

function ns.UpdateButton(button)
  if not db then
    return
  end

  local itemID = ResolveItemID(button)
  if not itemID then
    HideMarker(button)
    return
  end

  trackedButtons[button] = true

  local tier = db.enabled and ResolveTier(itemID)
  if tier and db.tiers[tier].enabled then
    ShowMarker(button, tier)
  else
    HideMarker(button)
  end
end

local refreshQueued = false
function ns.RefreshAll()
  if refreshQueued or not db then
    return
  end
  refreshQueued = true
  C_Timer.After(0, function()
    refreshQueued = false
    for button in pairs(trackedButtons) do
      ns.UpdateButton(button)
    end
  end)
end

-- Drop cached geometry and colours so the next update rebuilds them.
function ns.Restyle()
  for button in pairs(trackedButtons) do
    local widgets = button.ExpansionGlow
    if widgets then
      widgets.tintTier, widgets.tintAlpha, widgets.borderTier = nil, nil, nil
      if widgets.border then
        widgets.border.outset, widgets.border.thickness = nil, nil
      end
    end
  end
  ns.RefreshAll()
end

-- Restores every setting while keeping the learned item expansions, which are
-- cached facts about items rather than preferences.
function ns.ResetDefaults()
  for key in pairs(db) do
    if key ~= "itemExpansion" then
      db[key] = nil
    end
  end
  CopyDefaults(DEFAULTS, db)
  ns.Restyle()
end

-- Events ----------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("GET_ITEM_INFO_RECEIVED")
events:SetScript("OnEvent", function(_, event, arg1, success)
  if event == "ADDON_LOADED" then
    if arg1 ~= addonName then
      return
    end
    EXPANSIONGLOW_CONFIG = EXPANSIONGLOW_CONFIG or {}
    CopyDefaults(DEFAULTS, EXPANSIONGLOW_CONFIG)
    db = EXPANSIONGLOW_CONFIG
    ns.db = db
    events:UnregisterEvent("ADDON_LOADED")
    ns.RefreshAll()
  elseif event == "GET_ITEM_INFO_RECEIVED" then
    if awaitingItemData[arg1] then
      awaitingItemData[arg1] = nil
      if success then
        ns.RefreshAll()
      end
    end
  end
end)

-- Slash command ---------------------------------------------------------------

local function Print(message)
  print("|cff00ccff" .. addonName .. "|r: " .. message)
end

local function ToHex(color)
  return ("%02x%02x%02x"):format(
    math.floor(color[1] * 255 + 0.5),
    math.floor(color[2] * 255 + 0.5),
    math.floor(color[3] * 255 + 0.5))
end

local function Status()
  Print(db.enabled and "enabled" or "disabled")
  for _, tier in ipairs(TIER_ORDER) do
    local settings = db.tiers[tier]
    local hex = ToHex(settings.color)
    Print(("  %s - %s - %s - |cff%s#%s|r"):format(
      tier, TIER_LABEL[tier], settings.enabled and "on" or "off", hex, hex))
  end
  local cached = 0
  for _ in pairs(db.itemExpansion) do
    cached = cached + 1
  end
  if db.style == "border" then
    Print(("  style border, thickness %s, outset %s"):format(db.thickness, db.outset))
  else
    Print(("  style tint, alpha %s"):format(db.tintAlpha))
  end
  Print(("  %d items cached"):format(cached))
end

SLASH_EXPANSIONGLOW1 = "/expglow"
SLASH_EXPANSIONGLOW2 = "/expansionglow"
SlashCmdList.EXPANSIONGLOW = function(input)
  if not db then
    return
  end

  local command, rest = input:match("^(%S*)%s*(.-)%s*$")
  command = command:lower()

  if command == "" or command == "config" or command == "options" then
    ns.OpenOptions()
  elseif command == "status" then
    Status()
  elseif command == "toggle" then
    db.enabled = not db.enabled
    ns.RefreshAll()
    Print(db.enabled and "enabled" or "disabled")
  elseif db.tiers[command] then
    local hex = rest:match("^#?(%x%x%x%x%x%x)$")
    if hex then
      local color = db.tiers[command].color
      color[1] = tonumber(hex:sub(1, 2), 16) / 255
      color[2] = tonumber(hex:sub(3, 4), 16) / 255
      color[3] = tonumber(hex:sub(5, 6), 16) / 255
      ns.Restyle()
      Print(command .. " colour set to #" .. hex)
    elseif rest == "" then
      db.tiers[command].enabled = not db.tiers[command].enabled
      ns.RefreshAll()
      Print(command .. " " .. (db.tiers[command].enabled and "on" or "off"))
    else
      Print("expected a hex colour, e.g. /expglow " .. command .. " 33cc33")
    end
  elseif command == "style" then
    if rest == "tint" or rest == "border" then
      db.style = rest
      ns.Restyle()
      Print("style set to " .. rest)
    else
      Print("style expects tint or border")
    end
  elseif command == "alpha" then
    local value = tonumber(rest)
    if value and value > 0 and value <= 1 then
      db.tintAlpha = value
      ns.Restyle()
      Print("tint alpha set to " .. value)
    else
      Print("alpha expects a number above 0 and up to 1")
    end
  elseif command == "purge" then
    -- Only needed if Blizzard ever re-tags an item's expansion; the cache is
    -- otherwise permanently valid and rebuilds itself as bags are opened.
    db.itemExpansion = {}
    ns.RefreshAll()
    Print("cached item expansions cleared")
  elseif command == "thickness" or command == "outset" then
    local value = tonumber(rest)
    if value and value >= 0 and value <= 10 then
      db[command] = value
      ns.Restyle()
      Print(command .. " set to " .. value)
    else
      Print(command .. " expects a number from 0 to 10")
    end
  else
    Print("commands:")
    Print("  /expglow                                    open the options panel")
    Print("  /expglow status                             print current settings")
    Print("  /expglow toggle                             all markers on or off")
    Print("  /expglow prev1|prev2|prev3|ancient          toggle that tier")
    Print("  /expglow prev1|prev2|prev3|ancient <hex>    set that tier's colour")
    Print("  /expglow style tint|border                  colour the icon, or outline the slot")
    Print("  /expglow alpha <0-1>                        tint strength")
    Print("  /expglow thickness <0-10>                   border width in pixels")
    Print("  /expglow outset <0-10>                      border distance outside the button")
    Print("  /expglow purge                              clear the cached item expansions")
  end
end
