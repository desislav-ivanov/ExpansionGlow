-- Smoke test for Options.lua under a stubbed WoW UI.
-- Run from this directory:  lua5.1 test_options.lua
local ADDON_DIR = "../"

local failures, checks = 0, 0
local function check(label, got, want)
  checks = checks + 1
  if got ~= want then
    failures = failures + 1
    io.write(string.format("FAIL  %-56s got=%s want=%s\n", label, tostring(got), tostring(want)))
  else
    io.write(string.format("ok    %-56s %s\n", label, tostring(got)))
  end
end

local function near(x) return x and string.format("%.4f", x) or "nil" end

-- ---------------------------------------------------------------- WoW stubs

LE_EXPANSION_LEVEL_CURRENT = 11

local EXPANSION_NAMES = {
  [0] = "Classic", "The Burning Crusade", "Wrath of the Lich King", "Cataclysm",
  "Mists of Pandaria", "Warlords of Draenor", "Legion", "Battle for Azeroth",
  "Shadowlands", "Dragonflight", "The War Within", "Midnight",
}
for id, name in pairs(EXPANSION_NAMES) do
  _G["EXPANSION_NAME" .. id] = name
end

C_Item = {
  GetItemInfo = function() return nil end,
  RequestLoadItemDataByID = function() end,
  GetItemInfoInstant = function() return nil end,
}
C_Container = {GetContainerItemID = function() return nil end}

local timers = {}
C_Timer = {After = function(_, fn) timers[#timers + 1] = fn end}
local function RunTimers()
  local queued = timers
  timers = {}
  for _, fn in ipairs(queued) do fn() end
end

MinimalSliderWithSteppersMixin = {
  Label = {Left = 1, Right = 2, Top = 3, Min = 4, Max = 5},
  Event = {OnValueChanged = "OnValueChanged"},
}

local fontStrings = {}

local function MockRegion()
  local r = {shown = true}
  function r:SetPoint() end
  function r:SetAllPoints() end
  function r:SetSize() end
  function r:SetWidth() end
  function r:SetJustifyH() end
  function r:SetShown(v) self.shown = v and true or false end
  function r:IsShown() return self.shown end
  function r:Show() self.shown = true end
  function r:Hide() self.shown = false end
  function r:SetText(t) self.text = t end
  function r:SetColorTexture(a, b, c, d) self.color = {a, b, c, d} end
  return r
end

function CreateFrame(_, _, _, template)
  local f = {template = template, scripts = {}, events = {}, shown = false}
  function f:CreateFontString()
    local fs = MockRegion()
    fontStrings[#fontStrings + 1] = fs
    return fs
  end
  function f:CreateTexture(_, layer) local t = MockRegion(); t.layer = layer; return t end
  function f:SetPoint() end
  function f:SetSize() end
  function f:SetWidth() end
  function f:SetFrameLevel(l) self.level = l end
  function f:GetFrameLevel() return self.level or 1 end
  function f:Show() self.shown = true end
  function f:Hide() self.shown = false end
  function f:SetShown(v) self.shown = v and true or false end
  function f:IsShown() return self.shown end
  function f:SetJustifyH() end
  function f:ClearAllPoints() end
  function f:SetScript(k, fn) self.scripts[k] = fn end
  function f:GetScript(k) return self.scripts[k] end
  function f:RegisterEvent(e) self.events[e] = true end
  function f:UnregisterEvent(e) self.events[e] = nil end
  function f:SetChecked(v) self.checked = v and true or false end
  function f:GetChecked() return self.checked end
  function f:SetText(t) self.text = t end
  function f:Click() if self.scripts.OnClick then self.scripts.OnClick(self) end end

  if template == "UICheckButtonTemplate" then
    f.Text = MockRegion()
  elseif template == "MinimalSliderWithSteppersTemplate" then
    f.callbacks = {}
    function f:RegisterCallback(event, fn) self.callbacks[event] = fn end
    -- The real Init calls Slider:SetValue, which fires OnValueChanged. Mirror
    -- that so the refresh guard is actually exercised.
    function f:Init(value)
      self.value = value
      local cb = self.callbacks[MinimalSliderWithSteppersMixin.Event.OnValueChanged]
      if cb then cb(self, value) end
    end
    -- Simulate a user drag landing on an imprecise value.
    function f:Drag(value)
      local cb = self.callbacks[MinimalSliderWithSteppersMixin.Event.OnValueChanged]
      if cb then cb(self, value) end
    end
  end
  return f
end

local registered = {}
Settings = {
  RegisterCanvasLayoutCategory = function(frame, name)
    registered.frame, registered.name = frame, name
    return {GetID = function() return 42 end}
  end,
  RegisterAddOnCategory = function(category) registered.category = category end,
  OpenToCategory = function(id) registered.openedID = id end,
}

ColorPickerFrame = {}
function ColorPickerFrame:SetupColorPickerAndShow(info) self.info = info end
function ColorPickerFrame:GetColorRGB() return self.pickR, self.pickG, self.pickB end
function ColorPickerFrame:GetPreviousValues()
  return self.info.r, self.info.g, self.info.b, self.info.opacity
end

GameTooltip = {}
function GameTooltip:SetOwner() end
function GameTooltip:SetText() end
function GameTooltip:AddLine() end
function GameTooltip:Show() end
function GameTooltip_Hide() end

SlashCmdList = {}
print = function() end

-- ------------------------------------------------------------------- load

local created = {}
local baseCreate = CreateFrame
function CreateFrame(...)
  local f = baseCreate(...)
  created[#created + 1] = f
  return f
end

local ns = {}
EXPANSIONGLOW_CONFIG = nil
assert(loadfile(ADDON_DIR .. "Core.lua"))("ExpansionGlow", ns)
local eventFrame = created[#created]
eventFrame.onEvent = eventFrame.scripts.OnEvent
eventFrame.onEvent(eventFrame, "ADDON_LOADED", "ExpansionGlow")
check("core initialised", type(ns.db), "table")

assert(loadfile(ADDON_DIR .. "Options.lua"))("ExpansionGlow", ns)

check("panel registered as a canvas category", registered.name, "ExpansionGlow")
check("panel registered as an addon category", registered.category ~= nil, true)

local panel = registered.frame
check("panel exposes Refresh", type(panel.Refresh), "function")
check("panel refreshes on show", panel.scripts.OnShow, panel.Refresh)

ns.OpenOptions()
check("OpenOptions opens the registered category", registered.openedID, 42)

-- --------------------------------------------------------- widget lookup

-- Find widgets by identity rather than creation order, so adding a control does
-- not silently shift every assertion in this file.
local function Checkbox(text)
  for _, f in ipairs(created) do
    if f.template == "UICheckButtonTemplate" and f.Text and f.Text.text == text then
      return f
    end
  end
end

-- Swatches expose getColor, which returns the live colour table, so identity of
-- that table tells us exactly which setting a swatch is bound to.
local function SwatchFor(colorTable)
  for _, f in ipairs(created) do
    if f.getColor and f.getColor() == colorTable then
      return f
    end
  end
end

local function Sliders()
  local list = {}
  for _, f in ipairs(created) do
    if f.template == "MinimalSliderWithSteppersTemplate" then
      list[#list + 1] = f
    end
  end
  return list
end

local function FontStringContaining(needle)
  for _, fs in ipairs(fontStrings) do
    if fs.text and fs.text:find(needle, 1, true) then
      return fs
    end
  end
end

local cbEnabled = Checkbox("Enable ExpansionGlow")
local cbModeAge = Checkbox("By age, in four tiers")
local cbModeExpansion = Checkbox("By expansion, one colour each")
local cbTint = Checkbox("Tint the item icon")
local cbBorder = Checkbox("Outline the item slot")
local resetButton
for _, f in ipairs(created) do
  if f.template == "UIPanelButtonTemplate" then resetButton = f end
end

check("enable checkbox found", cbEnabled ~= nil, true)
check("both mode checkboxes found", cbModeAge ~= nil and cbModeExpansion ~= nil, true)
check("both style checkboxes found", cbTint ~= nil and cbBorder ~= nil, true)
check("reset button found", resetButton ~= nil, true)

local slAlpha, slThickness, slOutset = unpack(Sliders())
check("three sliders created", #Sliders(), 3)

check("a checkbox per tier", Checkbox(ns.TIER_LABEL.prev1) ~= nil, true)
check("a checkbox per expansion", Checkbox("Dragonflight") ~= nil, true)
check("no checkbox for the current expansion", Checkbox("Midnight"), nil)

local swatchCount = 0
for _, f in ipairs(created) do
  if f.getColor then swatchCount = swatchCount + 1 end
end
check("a swatch per tier plus per past expansion", swatchCount, 4 + 11)

-- ------------------------------------------------------- refresh is inert

ns.db.tintAlpha = 0.75
ns.db.thickness = 3
ns.db.outset = 2
ns.db.style = "border"
ns.db.mode = "age"
ns.db.enabled = false

panel:Refresh()

check("refresh left tintAlpha untouched", ns.db.tintAlpha, 0.75)
check("refresh left thickness untouched", ns.db.thickness, 3)
check("refresh left outset untouched", ns.db.outset, 2)
check("refresh left style untouched", ns.db.style, "border")
check("refresh left mode untouched", ns.db.mode, "age")
check("refresh left enabled untouched", ns.db.enabled, false)

check("enable box reflects db", cbEnabled.checked, false)
check("age mode box reflects db", cbModeAge.checked, true)
check("expansion mode box reflects db", cbModeExpansion.checked, false)
check("border box reflects db", cbBorder.checked, true)
check("alpha slider reflects db", slAlpha.value, 0.75)
check("thickness slider reflects db", slThickness.value, 3)

-- ------------------------------------------------- mode drives visibility

local tierRowBox = Checkbox(ns.TIER_LABEL.prev1)
local expansionRowBox = Checkbox("Dragonflight")
local disclaimer = FontStringContaining("no expansion")
check("disclaimer text exists", disclaimer ~= nil, true)

check("age mode shows tier rows", tierRowBox.shown, true)
check("age mode hides expansion rows", expansionRowBox.shown, false)
check("age mode hides the disclaimer", disclaimer.shown, false)

cbModeExpansion:Click()
check("expansion checkbox writes db", ns.db.mode, "expansion")
check("expansion checkbox unchecks age", cbModeAge.checked, false)
check("expansion mode hides tier rows", tierRowBox.shown, false)
check("expansion mode shows expansion rows", expansionRowBox.shown, true)
check("expansion mode shows the disclaimer", disclaimer.shown, true)

cbModeAge:Click()
check("age checkbox writes db", ns.db.mode, "age")
check("age checkbox unchecks expansion", cbModeExpansion.checked, false)
check("tier rows back", tierRowBox.shown, true)

-- ------------------------------------------ style drives outline controls

check("border style shows the width slider", slThickness.shown, true)
check("border style hides the opacity slider", slAlpha.shown, false)

cbTint:Click()
check("tint checkbox writes db", ns.db.style, "tint")
check("tint style hides the width slider", slThickness.shown, false)
check("tint style hides the outset slider", slOutset.shown, false)
check("tint style shows the opacity slider", slAlpha.shown, true)

-- ---------------------------------------------------------- write-back

cbEnabled:SetChecked(true)
cbEnabled:Click()
RunTimers()
check("enable checkbox writes db", ns.db.enabled, true)

tierRowBox:SetChecked(false)
tierRowBox:Click()
check("tier checkbox writes db", ns.db.tiers.prev1.enabled, false)

expansionRowBox:SetChecked(false)
expansionRowBox:Click()
check("expansion checkbox writes db", ns.db.expansions[9].enabled, false)
check("other expansions untouched", ns.db.expansions[8].enabled, true)

slAlpha:Drag(0.6500000001)
check("alpha snapped to 2 decimals", near(ns.db.tintAlpha), near(0.65))
slThickness:Drag(3.9999999)
check("thickness snapped to whole pixels", ns.db.thickness, 4)

-- ------------------------------------------------------------ colour picker

local dfSwatch = SwatchFor(ns.db.expansions[9].color)
check("swatch bound to the Dragonflight colour", dfSwatch ~= nil, true)

dfSwatch:Click()
check("swatch opens the colour picker", ColorPickerFrame.info ~= nil, true)
check("picker seeded with the expansion colour",
  near(ColorPickerFrame.info.r), near(ns.db.expansions[9].color[1]))
check("picker opens without an opacity slider", ColorPickerFrame.info.hasOpacity, false)

ColorPickerFrame.pickR, ColorPickerFrame.pickG, ColorPickerFrame.pickB = 0.1, 0.2, 0.3
ColorPickerFrame.info.swatchFunc()
check("picking writes the expansion colour", near(ns.db.expansions[9].color[1]), near(0.1))
check("swatch fill follows the pick", near(dfSwatch.fill.color[1]), near(0.1))

ColorPickerFrame.info.cancelFunc()
check("cancel restores the original colour",
  near(ns.db.expansions[9].color[1]), near(ColorPickerFrame.info.r))

-- ------------------------------------------------------------------ reset

ns.db.tintAlpha = 0.1
ns.db.mode = "expansion"
ns.db.style = "border"
ns.db.itemExpansion[12345] = 9
resetButton:Click()

check("reset restores alpha default", ns.db.tintAlpha, 0.65)
check("reset restores mode default", ns.db.mode, "age")
check("reset restores style default", ns.db.style, "tint")
check("reset restores tier colour", near(ns.db.tiers.prev1.color[1]), near(0.20))
check("reset rebuilds expansion defaults", ns.db.expansions[9] ~= nil, true)
check("reset keeps the learned item cache", ns.db.itemExpansion[12345], 9)
check("reset refreshes the widgets", slAlpha.value, 0.65)

-- After a reset the colour tables are new objects; swatches must still be bound
-- to the live ones, which is why they resolve the table on each click.
check("swatch still bound after reset", SwatchFor(ns.db.expansions[9].color) ~= nil, true)
check("tier swatch still bound after reset", SwatchFor(ns.db.tiers.prev1.color) ~= nil, true)

io.write(string.format("\n%d checks, %d failures\n", checks, failures))
os.exit(failures == 0 and 0 or 1)
