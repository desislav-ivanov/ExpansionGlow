local addonName, ns = ...

-- In-game options panel, registered as a canvas category so it can hold colour
-- swatches -- the Settings framework has slider and checkbox controls but no
-- colour control, so the layout is built by hand here.
--
-- Widgets are created once at load. Values are read from the saved settings in
-- Refresh, which runs on show: this file loads before ADDON_LOADED, so there is
-- no db to read from yet at creation time.
--
-- Sections appear and disappear with the selected mode and style, so positions
-- cannot be baked in at creation. Every widget belongs to a block, and Layout
-- walks the blocks top to bottom placing only the visible ones.

local panel = CreateFrame("Frame")
panel.name = addonName

-- Set while Refresh is pushing values into widgets, so the change handlers that
-- fire as a side effect of SetValue/SetChecked do not write straight back.
local refreshing = false

local MARGIN, INDENT, SUB_INDENT, ROW_INDENT = 16, 14, 18, 40
local COLUMN_WIDTH = 230

local controls = {}
local blocks = {}

local function AddBlock(block)
  blocks[#blocks + 1] = block
  return block
end

local function Layout()
  local y = -MARGIN
  for _, block in ipairs(blocks) do
    local visible = not block.visible or block.visible()
    for _, frame in ipairs(block.frames) do
      frame:SetShown(visible)
    end
    if visible then
      y = y - (block.gap or 0)
      block.place(y)
      y = y - block.height
    end
  end
end

local function InAgeMode() return ns.db.mode ~= "expansion" end
local function InExpansionMode() return ns.db.mode == "expansion" end
local function InBorderStyle() return ns.db.style == "border" end

-- Widget constructors ---------------------------------------------------------

local function NewLabel(text, font, width)
  local label = panel:CreateFontString(nil, "ARTWORK", font)
  label:SetText(text)
  label:SetJustifyH("LEFT")
  if width then
    label:SetWidth(width)
  end
  return label
end

local function NewCheckbox(text, tooltip, onClick)
  local box = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
  box:SetSize(24, 24)
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
local function NewSlider(minValue, maxValue, steps, decimals, onChanged)
  local slider = CreateFrame("Frame", nil, panel, "MinimalSliderWithSteppersTemplate")
  slider:SetWidth(260)

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
-- the click itself. getColor returns the live table so the swatch keeps working
-- after a reset replaces it.
local function NewColorSwatch(getColor)
  local swatch = CreateFrame("Button", nil, panel)
  swatch:SetSize(20, 20)

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
    local color = getColor()

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

  swatch.getColor = getColor
  return swatch
end

-- Block helpers ---------------------------------------------------------------

local function LabelBlock(text, font, gap, height, visible, indent)
  local label = NewLabel(text, font)
  AddBlock({
    frames = {label}, gap = gap, height = height, visible = visible,
    place = function(y) label:SetPoint("TOPLEFT", panel, "TOPLEFT", indent, y) end,
  })
  return label
end

local function CheckboxBlock(box, gap, visible, indent)
  AddBlock({
    frames = {box}, gap = gap, height = 24, visible = visible,
    place = function(y) box:SetPoint("TOPLEFT", panel, "TOPLEFT", indent, y) end,
  })
  return box
end

local function SliderBlock(text, slider, gap, visible)
  local label = NewLabel(text, "GameFontHighlightSmall")
  AddBlock({
    frames = {label, slider}, gap = gap, height = 16 + 4 + 28, visible = visible,
    place = function(y)
      label:SetPoint("TOPLEFT", panel, "TOPLEFT", SUB_INDENT, y)
      slider:SetPoint("TOPLEFT", panel, "TOPLEFT", SUB_INDENT, y - 20)
    end,
  })
  return slider
end

-- A colour row: swatch, then a checkbox whose label names the tier or expansion.
local function ColorRow(labelText, getColor, onToggle)
  local swatch = NewColorSwatch(getColor)
  local box = NewCheckbox(labelText, nil, onToggle)
  return {swatch = swatch, box = box}
end

-- Layout ----------------------------------------------------------------------

LabelBlock(addonName, "GameFontNormalLarge", 0, 22, nil, MARGIN)
LabelBlock("Marks items in bags and the bank by how many expansions old they are.",
  "GameFontHighlightSmall", 2, 16, nil, MARGIN)

controls.enabled = CheckboxBlock(
  NewCheckbox("Enable " .. addonName, nil, function(checked)
    ns.db.enabled = checked
    ns.RefreshAll()
  end), 10, nil, INDENT)

-- Mode -----------------------------------------------------------------------

LabelBlock("Colouring", "GameFontNormal", 10, 18, nil, MARGIN)

local function SetMode(mode)
  ns.db.mode = mode
  controls.modeAge:SetChecked(mode == "age")
  controls.modeExpansion:SetChecked(mode == "expansion")
  Layout()
  ns.Restyle()
end

controls.modeAge = CheckboxBlock(
  NewCheckbox("By age, in four tiers",
    "Groups everything by how many expansions back it is.",
    function() SetMode("age") end), 2, nil, INDENT)

controls.modeExpansion = CheckboxBlock(
  NewCheckbox("By expansion, one colour each",
    "Gives every past expansion its own colour.",
    function() SetMode("expansion") end), 0, nil, INDENT)

-- Style ----------------------------------------------------------------------

LabelBlock("Style", "GameFontNormal", 12, 18, nil, MARGIN)

local function SetStyle(style)
  ns.db.style = style
  controls.styleTint:SetChecked(style == "tint")
  controls.styleBorder:SetChecked(style == "border")
  Layout()
  ns.Restyle()
end

controls.styleTint = CheckboxBlock(
  NewCheckbox("Tint the item icon",
    "Washes the icon art with the colour.",
    function() SetStyle("tint") end), 2, nil, INDENT)

controls.styleBorder = CheckboxBlock(
  NewCheckbox("Outline the item slot",
    "Draws a coloured border around the slot and leaves the icon untouched.",
    function() SetStyle("border") end), 0, nil, INDENT)

controls.tintAlpha = SliderBlock("Tint opacity",
  NewSlider(0.05, 1, 19, 2, function(value)
    ns.db.tintAlpha = value
    ns.Restyle()
  end), 10, function() return not InBorderStyle() end)

-- Colours --------------------------------------------------------------------

LabelBlock("Colours", "GameFontNormal", 14, 18, nil, MARGIN)

controls.tiers = {}
for index, tier in ipairs(ns.TIER_ORDER) do
  local row = ColorRow(
    ns.TIER_LABEL[tier],
    function() return ns.db.tiers[tier].color end,
    function(checked)
      ns.db.tiers[tier].enabled = checked
      ns.RefreshAll()
    end)

  AddBlock({
    frames = {row.swatch, row.box}, gap = index == 1 and 4 or 0, height = 24,
    visible = InAgeMode,
    place = function(y)
      row.swatch:SetPoint("TOPLEFT", panel, "TOPLEFT", INDENT + 4, y - 2)
      row.box:SetPoint("TOPLEFT", panel, "TOPLEFT", ROW_INDENT, y)
    end,
  })
  controls.tiers[tier] = row
end

-- Two columns, because the list grows by one every time an expansion ships and
-- a single column would run off the bottom of the settings frame.
controls.expansions = {}
local pastExpansions = ns.PastExpansions()
for index = 1, #pastExpansions, 2 do
  local rowFrames, placers = {}, {}

  for column = 0, 1 do
    local id = pastExpansions[index + column]
    if id then
      local label = ns.ExpansionName(id)
      local row = ColorRow(
        label,
        function() return ns.db.expansions[id].color end,
        function(checked)
          ns.db.expansions[id].enabled = checked
          ns.RefreshAll()
        end)

      local x = INDENT + 4 + column * COLUMN_WIDTH
      rowFrames[#rowFrames + 1] = row.swatch
      rowFrames[#rowFrames + 1] = row.box
      placers[#placers + 1] = function(y)
        row.swatch:SetPoint("TOPLEFT", panel, "TOPLEFT", x, y - 2)
        row.box:SetPoint("TOPLEFT", panel, "TOPLEFT", x + 26, y)
      end
      controls.expansions[id] = row
    end
  end

  AddBlock({
    frames = rowFrames, gap = index == 1 and 4 or 0, height = 24,
    visible = InExpansionMode,
    place = function(y)
      for _, place in ipairs(placers) do
        place(y)
      end
    end,
  })
end

-- The disclaimer the expansion mode needs: the client reports 0 both for real
-- Classic items and for anything it has no expansion data for, and the two are
-- indistinguishable, so the oldest colour is not a reliable claim.
do
  local disclaimer = NewLabel(
    "Note: the game reports no expansion for a large number of items, and those are "
    .. "indistinguishable from genuine " .. ns.ExpansionName(0) .. " items. Both end up "
    .. "under " .. ns.ExpansionName(0) .. " above. Switch that one off if it is noisy.",
    "GameFontDisableSmall", 470)
  AddBlock({
    frames = {disclaimer}, gap = 10, height = 34, visible = InExpansionMode,
    place = function(y) disclaimer:SetPoint("TOPLEFT", panel, "TOPLEFT", MARGIN, y) end,
  })
end

-- Outline sizing -------------------------------------------------------------

LabelBlock("Outline size", "GameFontNormal", 14, 18, InBorderStyle, MARGIN)

controls.thickness = SliderBlock("Width in pixels",
  NewSlider(1, 6, 5, 0, function(value)
    ns.db.thickness = value
    ns.Restyle()
  end), 4, InBorderStyle)

controls.outset = SliderBlock("Distance outside the slot",
  NewSlider(0, 6, 6, 0, function(value)
    ns.db.outset = value
    ns.Restyle()
  end), 10, InBorderStyle)

-- Reset ----------------------------------------------------------------------

do
  local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  reset:SetSize(160, 24)
  reset:SetText("Reset to defaults")
  reset:SetScript("OnClick", function()
    ns.ResetDefaults()
    panel:Refresh()
  end)
  AddBlock({
    frames = {reset}, gap = 20, height = 24,
    place = function(y) reset:SetPoint("TOPLEFT", panel, "TOPLEFT", MARGIN, y) end,
  })
  controls.reset = reset
end

-- Refresh ---------------------------------------------------------------------

function panel:Refresh()
  local db = ns.db
  if not db then
    return
  end

  refreshing = true

  controls.enabled:SetChecked(db.enabled)
  controls.modeAge:SetChecked(db.mode ~= "expansion")
  controls.modeExpansion:SetChecked(db.mode == "expansion")
  controls.styleTint:SetChecked(db.style == "tint")
  controls.styleBorder:SetChecked(db.style == "border")

  SetSliderValue(controls.tintAlpha, db.tintAlpha)
  SetSliderValue(controls.thickness, db.thickness)
  SetSliderValue(controls.outset, db.outset)

  for tier, row in pairs(controls.tiers) do
    local settings = db.tiers[tier]
    row.box:SetChecked(settings.enabled)
    row.swatch.fill:SetColorTexture(settings.color[1], settings.color[2], settings.color[3])
  end

  for id, row in pairs(controls.expansions) do
    local settings = db.expansions[id]
    row.box:SetChecked(settings.enabled)
    row.swatch.fill:SetColorTexture(settings.color[1], settings.color[2], settings.color[3])
  end

  Layout()

  refreshing = false
end

panel:SetScript("OnShow", panel.Refresh)

local category = Settings.RegisterCanvasLayoutCategory(panel, addonName)
Settings.RegisterAddOnCategory(category)

function ns.OpenOptions()
  Settings.OpenToCategory(category:GetID())
end
