local addonName, ns = ...

-- In-game options panel, registered as a canvas category so it can hold colour
-- swatches -- the Settings framework has slider and checkbox controls but no
-- colour control, so the layout is built by hand here.
--
-- Widgets are created once at load. Values are read from the saved settings in
-- Refresh, which runs on show: this file loads before ADDON_LOADED, so there is
-- no db to read from yet at creation time.

local panel = CreateFrame("Frame")
panel.name = addonName

-- Set while Refresh is pushing values into widgets, so the change handlers that
-- fire as a side effect of SetValue/SetChecked do not write straight back.
local refreshing = false

local controls = {}

-- Every widget is positioned against the panel itself from a running vertical
-- cursor. Chaining each row off the previous one instead makes indents
-- accumulate down the panel, staircasing the rows to the right.
local MARGIN, INDENT, SUB_INDENT = 16, 14, 18
local cursor = -MARGIN

local function Place(frame, x, gap, height)
  cursor = cursor - gap
  frame:SetPoint("TOPLEFT", panel, "TOPLEFT", x, cursor)
  cursor = cursor - height
end

local function Label(text, font, x, gap, height)
  local label = panel:CreateFontString(nil, "ARTWORK", font)
  label:SetText(text)
  Place(label, x, gap, height)
  return label
end

local function Checkbox(text, tooltip, x, gap, onClick)
  local box = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
  box:SetSize(24, 24)
  Place(box, x, gap, 24)
  box.Text:SetText(text)
  box:SetScript("OnClick", function(self)
    if not refreshing then
      onClick(self:GetChecked())
    end
  end)
  if tooltip then
    box:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(text, 1, 1, 1)
      GameTooltip:AddLine(tooltip, nil, nil, nil, true)
      GameTooltip:Show()
    end)
    box:SetScript("OnLeave", GameTooltip_Hide)
  end
  return box
end

-- MinimalSliderWithSteppersTemplate is the current settings slider;
-- OptionsSliderTemplate now lives in Blizzard's DeprecatedTemplates.
local function Slider(text, minValue, maxValue, steps, decimals, onChanged)
  Label(text, "GameFontHighlightSmall", SUB_INDENT, 10, 16)

  local slider = CreateFrame("Frame", nil, panel, "MinimalSliderWithSteppersTemplate")
  slider:SetWidth(260)
  Place(slider, SUB_INDENT, 4, 28)

  local format = "%." .. decimals .. "f"
  local scale = 10 ^ decimals
  slider.formatters = {
    [MinimalSliderWithSteppersMixin.Label.Right] = function(value)
      return format:format(value)
    end,
  }

  slider:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(_, value)
    if not refreshing then
      -- Slider positions land on values like 0.7500000001; snap them.
      onChanged(math.floor(value * scale + 0.5) / scale)
    end
  end, panel)

  slider.egMin, slider.egMax, slider.egSteps = minValue, maxValue, steps
  return slider
end

local function SetSliderValue(slider, value)
  slider:Init(value, slider.egMin, slider.egMax, slider.egSteps, slider.formatters)
end

-- A plain button rather than ColorSwatchTemplate: that template is a Frame with
-- propagateMouseInput, meant to be a visual inside a button, so it cannot take
-- the click itself.
local function ColorSwatch(tier, rowAnchor)
  local swatch = CreateFrame("Button", nil, panel)
  swatch:SetSize(20, 20)
  swatch:SetPoint("RIGHT", rowAnchor, "LEFT", -4, 0)

  local border = swatch:CreateTexture(nil, "BACKGROUND")
  border:SetAllPoints()
  border:SetColorTexture(0, 0, 0, 1)

  local fill = swatch:CreateTexture(nil, "ARTWORK")
  fill:SetPoint("TOPLEFT", 2, -2)
  fill:SetPoint("BOTTOMRIGHT", -2, 2)
  swatch.fill = fill

  local highlight = swatch:CreateTexture(nil, "HIGHLIGHT")
  highlight:SetAllPoints()
  highlight:SetColorTexture(1, 1, 1, 0.25)

  swatch:SetScript("OnClick", function()
    local color = ns.db.tiers[tier].color

    local function Apply(r, g, b)
      color[1], color[2], color[3] = r, g, b
      fill:SetColorTexture(r, g, b)
      ns.Restyle()
    end

    ColorPickerFrame:SetupColorPickerAndShow({
      r = color[1], g = color[2], b = color[3],
      hasOpacity = false,
      swatchFunc = function() Apply(ColorPickerFrame:GetColorRGB()) end,
      cancelFunc = function() Apply(ColorPickerFrame:GetPreviousValues()) end,
    })
  end)

  return swatch
end

-- Layout ----------------------------------------------------------------------

Label(addonName, "GameFontNormalLarge", MARGIN, 0, 22)
Label("Marks items in bags and the bank by how many expansions old they are.",
  "GameFontHighlightSmall", MARGIN, 2, 16)

controls.enabled = Checkbox("Enable " .. addonName, nil, INDENT, 10,
  function(checked)
    ns.db.enabled = checked
    ns.RefreshAll()
  end)

Label("Style", "GameFontNormal", MARGIN, 10, 18)

-- Two checkboxes acting as a radio pair: style is one value, but a pair of
-- labelled boxes names both options instead of hiding one behind "unchecked".
local function SetStyle(style)
  ns.db.style = style
  controls.styleTint:SetChecked(style == "tint")
  controls.styleBorder:SetChecked(style == "border")
  ns.Restyle()
end

controls.styleTint = Checkbox(
  "Tint the item icon",
  "Washes the icon art with the expansion colour.",
  INDENT, 2, function() SetStyle("tint") end)

controls.styleBorder = Checkbox(
  "Outline the item slot",
  "Draws a coloured border around the slot and leaves the icon untouched.",
  INDENT, 0, function() SetStyle("border") end)

controls.tintAlpha = Slider("Tint opacity", 0.05, 1, 19, 2,
  function(value)
    ns.db.tintAlpha = value
    ns.Restyle()
  end)

Label("Expansion colours", "GameFontNormal", MARGIN, 18, 18)

-- Each row is a checkbox with its swatch hung off the checkbox's left edge, so
-- the swatches line up in a column without needing their own cursor maths.
controls.tiers = {}
for index, tier in ipairs(ns.TIER_ORDER) do
  local row = {}
  row.enabled = Checkbox(ns.TIER_LABEL[tier], nil, INDENT + 26, index == 1 and 4 or 0,
    function(checked)
      ns.db.tiers[tier].enabled = checked
      ns.RefreshAll()
    end)
  row.swatch = ColorSwatch(tier, row.enabled)
  controls.tiers[tier] = row
end

Label("Outline size", "GameFontNormal", MARGIN, 18, 18)

controls.thickness = Slider("Width in pixels", 1, 6, 5, 0,
  function(value)
    ns.db.thickness = value
    ns.Restyle()
  end)

controls.outset = Slider("Distance outside the slot", 0, 6, 6, 0,
  function(value)
    ns.db.outset = value
    ns.Restyle()
  end)

local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
reset:SetSize(160, 24)
Place(reset, MARGIN, 24, 24)
reset:SetText("Reset to defaults")
reset:SetScript("OnClick", function()
  ns.ResetDefaults()
  panel:Refresh()
end)

-- Refresh ---------------------------------------------------------------------

function panel:Refresh()
  local db = ns.db
  if not db then
    return
  end

  refreshing = true

  controls.enabled:SetChecked(db.enabled)
  controls.styleTint:SetChecked(db.style == "tint")
  controls.styleBorder:SetChecked(db.style == "border")

  SetSliderValue(controls.tintAlpha, db.tintAlpha)
  SetSliderValue(controls.thickness, db.thickness)
  SetSliderValue(controls.outset, db.outset)

  for tier, row in pairs(controls.tiers) do
    local settings = db.tiers[tier]
    row.enabled:SetChecked(settings.enabled)
    row.swatch.fill:SetColorTexture(settings.color[1], settings.color[2], settings.color[3])
  end

  refreshing = false
end

panel:SetScript("OnShow", panel.Refresh)

local category = Settings.RegisterCanvasLayoutCategory(panel, addonName)
Settings.RegisterAddOnCategory(category)

function ns.OpenOptions()
  Settings.OpenToCategory(category:GetID())
end
