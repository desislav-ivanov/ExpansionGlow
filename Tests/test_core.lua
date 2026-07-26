-- Smoke test for Core.lua under a stubbed WoW API.
-- Run from this directory:  lua5.1 test_core.lua
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

LE_EXPANSION_LEVEL_CURRENT = 11 -- Midnight, matching the live 12.0.7 client

-- Blizzard exposes localized expansion names as EXPANSION_NAME0..n, 0-based
-- and aligned with expacID.
local EXPANSION_NAMES = {
  [0] = "Classic", "The Burning Crusade", "Wrath of the Lich King", "Cataclysm",
  "Mists of Pandaria", "Warlords of Draenor", "Legion", "Battle for Azeroth",
  "Shadowlands", "Dragonflight", "The War Within", "Midnight",
}
for id, name in pairs(EXPANSION_NAMES) do
  _G["EXPANSION_NAME" .. id] = name
end

local itemExpac = {           -- itemID -> expacID
  [100] = 11,                 -- Midnight       (current)
  [101] = 10,                 -- The War Within (-1)
  [102] = 9,                  -- Dragonflight   (-2)
  [103] = 8,                  -- Shadowlands    (-3)
  [104] = 7,                  -- Battle for Azeroth (-4)
  [105] = 0,                  -- Classic / untagged
  [107] = 6,                  -- Legion
}
local uncached = {[999] = true}
local requestedLoads = {}

C_Item = {
  GetItemInfo = function(itemID)
    if uncached[itemID] then return nil end
    -- 14 leading returns, then expacID
    return nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil,
           itemExpac[itemID], nil, nil
  end,
  RequestLoadItemDataByID = function(itemID) requestedLoads[#requestedLoads + 1] = itemID end,
  GetItemInfoInstant = function(link) return tonumber(tostring(link):match("(%d+)")) end,
}

local containerItems = {}     -- "bag:slot" -> itemID
C_Container = {
  GetContainerItemID = function(bag, slot) return containerItems[bag .. ":" .. slot] end,
}

local timers = {}
C_Timer = {After = function(_, fn) timers[#timers + 1] = fn end}
local function RunTimers()
  local queued = timers
  timers = {}
  for _, fn in ipairs(queued) do fn() end
end

local function MockTexture(layer)
  local t = {shown = false, layer = layer}
  function t:SetColorTexture(r, g, b, a) self.color = {r, g, b, a} end
  function t:SetAllPoints(other) self.anchoredTo = other end
  function t:Show() self.shown = true end
  function t:Hide() self.shown = false end
  function t:ClearAllPoints() self.points = {} end
  function t:SetPoint(...) self.points = self.points or {}; self.points[#self.points + 1] = {...} end
  function t:SetHeight(h) self.height = h end
  function t:SetWidth(w) self.width = w end
  return t
end

function CreateFrame()
  local f = {shown = false, events = {}}
  function f:SetFrameLevel(l) self.level = l end
  function f:GetFrameLevel() return self.level or 1 end
  function f:Hide() self.shown = false end
  function f:Show() self.shown = true end
  function f:CreateTexture(_, layer) return MockTexture(layer) end
  function f:ClearAllPoints() self.points = {} end
  function f:SetPoint(...) self.points = self.points or {}; self.points[#self.points + 1] = {...} end
  function f:RegisterEvent(e) self.events[e] = true end
  function f:UnregisterEvent(e) self.events[e] = nil end
  function f:SetScript(_, fn) self.onEvent = fn end
  return f
end

SlashCmdList = {}
local output = {}
print = function(s) output[#output + 1] = tostring(s) end

-- ------------------------------------------------------------------- load

-- Capture frames so we can reach Core.lua's file-scope event frame and drive
-- ADDON_LOADED / GET_ITEM_INFO_RECEIVED through it.
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

check("event frame registered ADDON_LOADED", eventFrame.events["ADDON_LOADED"], true)
check("event frame registered GET_ITEM_INFO_RECEIVED", eventFrame.events["GET_ITEM_INFO_RECEIVED"], true)

-- Item buttons are Frames that host their own icon texture.
local function MockButton(fields)
  fields.GetFrameLevel = function() return 1 end
  if fields.icon == nil then
    fields.icon = MockTexture("BORDER")
  elseif fields.icon == false then
    fields.icon = nil -- a button with no icon region at all
  end
  fields.CreateTexture = function(_, _, layer) return MockTexture(layer) end
  return fields
end

-- Before ADDON_LOADED, UpdateButton must be inert (db is nil).
local early = MockButton{bagID = 0, GetID = function() return 1 end}
containerItems["0:1"] = 101
ns.UpdateButton(early)
check("nothing created before ADDON_LOADED", early.ExpansionGlow, nil)

eventFrame.onEvent(eventFrame, "ADDON_LOADED", "SomeOtherAddon")
check("db not initialised by another addon's load", ns.db, nil)
eventFrame.onEvent(eventFrame, "ADDON_LOADED", "ExpansionGlow")
check("db initialised", type(ns.db), "table")
check("default enabled", ns.db.enabled, true)
check("default mode is age", ns.db.mode, "age")
check("default style is tint", ns.db.style, "tint")
check("default tint alpha", ns.db.tintAlpha, 0.65)
check("default thickness", ns.db.thickness, 2)
check("default outset", ns.db.outset, 1)
check("default prev1 colour g", ns.db.tiers.prev1.color[2], 0.80)
check("ancient alpha weight", ns.db.tiers.ancient.color[4], 0.70)

-- ------------------------------------------------------------ tier mapping

local function ButtonInBag(bag, slot, itemID)
  containerItems[bag .. ":" .. slot] = itemID
  return MockButton{bagID = bag, GetID = function() return slot end}
end

-- Whichever marker is currently visible, and for which colour key.
local function ActiveTier(button)
  local w = button.ExpansionGlow
  if not w then return nil end
  if w.tint and w.tint.shown then return w.tintKey end
  if w.border and w.border.shown then return w.borderKey end
  return nil
end

local function TierOf(itemID)
  local b = ButtonInBag(0, 5, itemID)
  ns.UpdateButton(b)
  return ActiveTier(b)
end

check("current expansion -> unmarked", TierOf(100), nil)
check("-1 -> prev1", TierOf(101), "prev1")
check("-2 -> prev2", TierOf(102), "prev2")
check("-3 -> prev3", TierOf(103), "prev3")
check("-4 -> ancient", TierOf(104), "ancient")
check("expac 0 (Classic/untagged) -> ancient", TierOf(105), "ancient")
check("empty slot -> unmarked", TierOf(nil), nil)

-- ------------------------------------------------------------ tint style

local btn = ButtonInBag(0, 7, 102)
ns.UpdateButton(btn)
local tint = btn.ExpansionGlow.tint
check("tint texture created", type(tint), "table")
check("tint shown", tint.shown, true)
-- ARTWORK sits above the icon (BORDER) and below IconBorder/overlays/Count (OVERLAY).
check("tint drawn in ARTWORK layer", tint.layer, "ARTWORK")
check("tint anchored to the button icon", tint.anchoredTo, btn.icon)
check("tint takes prev2 red", near(tint.color[1]), near(1.00))
-- Per-colour alpha is a weight; the style supplies the base opacity.
check("tint alpha = weight x base", near(tint.color[4]), near(1.00 * 0.65))
check("no border built while tinting", btn.ExpansionGlow.border, nil)

local ancientBtn = ButtonInBag(0, 8, 104)
ns.UpdateButton(ancientBtn)
check("ancient stays subtler", near(ancientBtn.ExpansionGlow.tint.color[4]), near(0.70 * 0.65))

containerItems["0:7"] = nil
ns.UpdateButton(btn)
check("tint hidden when slot emptied", tint.shown, false)
check("tint texture reused", btn.ExpansionGlow.tint, tint)

-- A button with no icon region must be skipped, not error.
local iconless = MockButton{bagID = 0, GetID = function() return 41 end, icon = false}
containerItems["0:41"] = 102
local ok = pcall(ns.UpdateButton, iconless)
check("button with no icon does not error", ok, true)
check("button with no icon is skipped", iconless.ExpansionGlow.tint, false)

-- ---------------------------------------------------------- border style

local slash = SlashCmdList.EXPANSIONGLOW
slash("style border")
RunTimers()
check("style switched to border", ns.db.style, "border")

local bordered = ButtonInBag(0, 12, 102)
ns.UpdateButton(bordered)
local border = bordered.ExpansionGlow.border
check("border frame created", border.shown, true)
check("border frame level above button", border.level, 9)
check("edge count", #border.edges, 4)
check("top edge height = thickness", border.edges[1].height, 2)
check("left edge width = thickness", border.edges[3].width, 2)
check("border takes full weight", near(border.edges[1].color[4]), near(1.00))
check("outset applied to TOPLEFT x", border.points[1][4], -1)

containerItems["0:7"] = 102
ns.UpdateButton(btn)
check("border shown after switch", btn.ExpansionGlow.border.shown, true)
check("tint hidden after switch", btn.ExpansionGlow.tint.shown, false)
slash("style tint")
RunTimers()
check("tint shown after switching back", btn.ExpansionGlow.tint.shown, true)
check("border hidden after switching back", btn.ExpansionGlow.border.shown, false)

slash("style sparkles")
check("unknown style rejected", ns.db.style, "tint")

slash("alpha 0.6")
RunTimers()
check("alpha setting stored", ns.db.tintAlpha, 0.6)
check("alpha applied live", near(btn.ExpansionGlow.tint.color[4]), near(1.00 * 0.6))
slash("alpha 5")
check("out-of-range alpha rejected", ns.db.tintAlpha, 0.6)
slash("alpha 0.65")
RunTimers()

-- --------------------------------------------------------- button sourcing

local bankBtn = MockButton{bankTabID = 13, containerSlotID = 4}
containerItems["13:4"] = 103
ns.UpdateButton(bankBtn)
check("bank button resolves via bankTabID", ActiveTier(bankBtn), "prev3")

local cachedBtn = MockButton{BGR = {itemLink = "|Hitem:104|h[Old]|h"}}
ns.UpdateButton(cachedBtn)
check("Baganator cached button resolves via BGR link", ActiveTier(cachedBtn), "ancient")

local bgrID = MockButton{BGR = {itemID = 101}}
ns.UpdateButton(bgrID)
check("Baganator cached button resolves via BGR itemID", ActiveTier(bgrID), "prev1")

-- A merchant/loot/paperdoll button: no slot fields at all.
local unbound = MockButton{GetID = function() return 1 end}
ns.UpdateButton(unbound)
check("unbound button ignored", unbound.ExpansionGlow, nil)

-- Each bag addon names its slot fields differently; Core adapts to all of them.
local elvui = MockButton{BagID = 0, SlotID = 51}
containerItems["0:51"] = 103
ns.UpdateButton(elvui)
check("ElvUI capitalised BagID/SlotID resolves", ActiveTier(elvui), "prev3")

local ark = MockButton{ARK_Data = {blizzard_id = 0, slot_id = 52}}
containerItems["0:52"] = 102
ns.UpdateButton(ark)
check("ArkInventory ARK_Data resolves", ActiveTier(ark), "prev2")

local adibags = MockButton{bag = 0, slot = 53}
containerItems["0:53"] = 101
ns.UpdateButton(adibags)
check("AdiBags bag/slot resolves", ActiveTier(adibags), "prev1")

-- Hosts that hand over the item directly, for buttons with no readable slot.
local hostSupplied = MockButton{}
ns.UpdateButtonWithItem(hostSupplied, 104)
check("host-supplied itemID marks the button", ActiveTier(hostSupplied), "ancient")

ns.UpdateButtonWithItem(hostSupplied, nil)
check("host-supplied nil clears the button", ActiveTier(hostSupplied), nil)

-- Host-supplied buttons must survive a settings refresh, which is why the
-- itemID is remembered rather than only resolved.
ns.UpdateButtonWithItem(hostSupplied, 102)
ns.RefreshAll()
RunTimers()
check("host-supplied button survives a refresh", ActiveTier(hostSupplied), "prev2")

-- Container slot wins over a stale remembered id.
local stale = ButtonInBag(0, 9, 101)
stale.BGR = {itemID = 104}
ns.UpdateButton(stale)
check("container slot beats stale BGR", ActiveTier(stale), "prev1")

-- ------------------------------------------------------------ uncached item

requestedLoads = {}
local pending = ButtonInBag(0, 11, 999)
ns.UpdateButton(pending)
check("uncached item requests load", requestedLoads[1], 999)
check("uncached item shows nothing yet", ActiveTier(pending), nil)

uncached[999] = nil
itemExpac[999] = 9
eventFrame.onEvent(eventFrame, "GET_ITEM_INFO_RECEIVED", 999, true)
RunTimers()
check("marker appears after GET_ITEM_INFO_RECEIVED", ActiveTier(pending), "prev2")

-- --------------------------------------------------------------- settings

slash("toggle")
RunTimers()
check("toggle disables", ns.db.enabled, false)
check("disabling hides existing marker", ActiveTier(pending), nil)
slash("toggle")
RunTimers()
check("toggle re-enables", ns.db.enabled, true)
check("re-enabling restores marker", ActiveTier(pending), "prev2")

slash("prev2 336699")
RunTimers()
check("hex colour red channel", near(ns.db.tiers.prev2.color[1]), near(0x33 / 255))
check("hex colour recoloured live", near(pending.ExpansionGlow.tint.color[3]), near(0x99 / 255))

slash("prev2")
RunTimers()
check("bare tier name toggles tier off", ns.db.tiers.prev2.enabled, false)
check("disabled tier hides marker", ActiveTier(pending), nil)
slash("prev2")
RunTimers()

slash("thickness 4")
RunTimers()
check("thickness setting stored", ns.db.thickness, 4)
slash("thickness 99")
check("out-of-range thickness rejected", ns.db.thickness, 4)
slash("prev1 zzz")
check("bad hex rejected", near(ns.db.tiers.prev1.color[1]), near(0.20))

local opened = false
ns.OpenOptions = function() opened = true end
slash("")
check("bare command opens the options panel", opened, true)

output = {}
slash("status")
check("status prints header, mode, 4 tiers, style, cache", #output, 8)

-- ------------------------------------------------------- expansion mode

check("past expansions listed newest first", table.concat(ns.PastExpansions(), ","),
  "10,9,8,7,6,5,4,3,2,1,0")
check("expansion names come from the client globals", ns.ExpansionName(9), "Dragonflight")
check("defaults created for every past expansion", ns.db.expansions[0] ~= nil, true)
check("no default for the current expansion", ns.db.expansions[11], nil)
check("no default beyond the current expansion", ns.db.expansions[12], nil)

slash("mode expansion")
RunTimers()
check("mode switched to expansion", ns.db.mode, "expansion")

-- The point of the mode: BfA and Legion share the "ancient" tier by age, but
-- are separate colours here.
local bfa = ButtonInBag(0, 61, 104)     -- expacID 7
local legion = ButtonInBag(0, 62, 107)  -- expacID 6
ns.UpdateButton(bfa)
ns.UpdateButton(legion)
check("BfA keyed to its own expansion", ActiveTier(bfa), "x7")
check("Legion keyed to its own expansion", ActiveTier(legion), "x6")
check("BfA and Legion no longer share a marker", ActiveTier(bfa) ~= ActiveTier(legion), true)

local dfBtn = ButtonInBag(0, 63, 102)   -- expacID 9
ns.UpdateButton(dfBtn)
check("Dragonflight uses its own palette entry",
  near(dfBtn.ExpansionGlow.tint.color[1]), near(0.25))
check("expansion colour honours tint alpha",
  near(dfBtn.ExpansionGlow.tint.color[4]), near(1.00 * ns.db.tintAlpha))

local currentBtn = ButtonInBag(0, 64, 100) -- expacID 11 == current
ns.UpdateButton(currentBtn)
check("current expansion unmarked in expansion mode", ActiveTier(currentBtn), nil)

ns.db.expansions[7].enabled = false
ns.UpdateButton(bfa)
ns.UpdateButton(legion)
check("disabled expansion hides", ActiveTier(bfa), nil)
check("other expansions unaffected", ActiveTier(legion), "x6")
ns.db.expansions[7].enabled = true

output = {}
slash("status")
check("status lists every past expansion", #output, 1 + 1 + 11 + 1 + 1)

slash("mode nonsense")
check("unknown mode rejected", ns.db.mode, "expansion")

slash("mode age")
RunTimers()
check("mode switched back to age", ns.db.mode, "age")
ns.UpdateButton(bfa)
ns.UpdateButton(legion)
check("BfA back to the ancient tier", ActiveTier(bfa), "ancient")
check("Legion back to the ancient tier", ActiveTier(legion), "ancient")

-- ------------------------------------------------- persistent item cache

check("expacID cached for a seen item", ns.db.itemExpansion[101], 10)
check("expacID cached, not the tier", ns.db.itemExpansion[104], 7)
check("expac 0 cached as 0, not skipped", ns.db.itemExpansion[105], 0)
check("unseen item absent from cache", ns.db.itemExpansion[555], nil)

-- A cache hit must not touch the client item API at all.
local liveCalls = 0
local realGetItemInfo = C_Item.GetItemInfo
C_Item.GetItemInfo = function(...) liveCalls = liveCalls + 1; return realGetItemInfo(...) end
ns.UpdateButton(ButtonInBag(0, 21, 101))
check("cached item does not call GetItemInfo", liveCalls, 0)
itemExpac[106] = 8
ns.UpdateButton(ButtonInBag(0, 22, 106))
check("uncached item does call GetItemInfo", liveCalls > 0, true)
C_Item.GetItemInfo = realGetItemInfo

-- Settings and item cache survive a reload: re-load against the saved table.
local saved = EXPANSIONGLOW_CONFIG
local ns2 = {}
created = {}
assert(loadfile(ADDON_DIR .. "Core.lua"))("ExpansionGlow", ns2)
local ef2 = created[#created]
ef2.onEvent(ef2, "ADDON_LOADED", "ExpansionGlow")
check("saved thickness persists across reload", ns2.db.thickness, 4)
check("saved style persists across reload", ns2.db.style, "tint")
check("saved colour persists across reload", near(ns2.db.tiers.prev2.color[1]), near(0x33 / 255))
check("same saved table reused", ns2.db, saved)
check("item cache persists across reload", ns2.db.itemExpansion[101], 10)

-- The cache stores expacID, so tiers re-derive correctly after an expansion
-- launch bumps LE_EXPANSION_LEVEL_CURRENT -- no stale tiers, no purge needed.
LE_EXPANSION_LEVEL_CURRENT = 12
local shifted = ButtonInBag(0, 31, 101) -- expacID 10, was prev1 at level 11
ns2.UpdateButton(shifted)
check("cached item re-tiers after new expansion", ActiveTier(shifted), "prev2")
LE_EXPANSION_LEVEL_CURRENT = 11

-- purge empties the cache synchronously, then the queued refresh re-reads
-- whatever is currently on screen straight back from the client.
SlashCmdList.EXPANSIONGLOW("purge")
check("purge clears the item cache", next(ns2.db.itemExpansion), nil)
RunTimers()
check("visible buttons re-cache after purge", ns2.db.itemExpansion[101], 10)
ns2.UpdateButton(ButtonInBag(0, 32, 103))
check("newly seen item re-caches after purge", ns2.db.itemExpansion[103], 8)

io.write(string.format("\n%d checks, %d failures\n", checks, failures))
os.exit(failures == 0 and 0 or 1)
