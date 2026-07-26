-- Smoke test for the per-bag-UI integration files.
--
-- None of these host addons are installed here, so this cannot prove the
-- integrations work against the real thing. What it does prove is the wiring:
-- that each file hooks what it claims to, resolves the right button and item
-- from the shapes those addons document, and stays completely inert when its
-- host is absent.
--
-- Run from this directory:  lua5.1 test_hosts.lua
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

-- ---------------------------------------------------------------- harness

-- Records what each integration asks Core to do, so assertions are about the
-- call rather than about any drawing.
local function NewNS()
  local ns = {calls = {}}
  function ns.UpdateButton(button)
    ns.calls[#ns.calls + 1] = {button = button, viaItem = false}
  end
  function ns.UpdateButtonWithItem(button, itemID)
    ns.calls[#ns.calls + 1] = {button = button, itemID = itemID, viaItem = true}
  end
  -- Records the hook arguments verbatim. Whether those arguments mean "this
  -- item", "explicitly empty" or "read the slot" is Core's decision and is
  -- asserted in test_core.lua, so it must not be re-implemented here.
  function ns.UpdateButtonFromQuality(button, quality, itemIDOrLink)
    ns.calls[#ns.calls + 1] = {
      button = button, quality = quality, itemIDOrLink = itemIDOrLink,
      fromQuality = true,
    }
  end
  function ns.last() return ns.calls[#ns.calls] end
  return ns
end

local globalHooks, methodHooks

local function ResetHooks()
  globalHooks, methodHooks = {}, {}
end

function hooksecurefunc(a, b, c)
  if type(a) == "string" then
    globalHooks[a] = b            -- hooksecurefunc("Name", fn)
  else
    methodHooks[a] = methodHooks[a] or {}
    methodHooks[a][b] = c         -- hooksecurefunc(table, "method", fn)
  end
end

local loadedAddons = {}
C_AddOns = {
  IsAddOnLoaded = function(name) return loadedAddons[name] or false end,
}

local containerItems = {}
C_Container = {
  GetContainerItemID = function(bag, slot) return containerItems[bag .. ":" .. slot] end,
}

C_Item = {
  GetItemInfoInstant = function(link) return tonumber(tostring(link):match("(%d+)")) end,
}

function CreateFrame()
  local f = {events = {}}
  function f:RegisterEvent(e) self.events[e] = true end
  function f:UnregisterEvent(e) self.events[e] = nil end
  function f:SetScript(_, fn) self.onEvent = fn end
  return f
end

local function Load(file, ns)
  ResetHooks()
  return assert(loadfile(ADDON_DIR .. file))("ExpansionGlow", ns)
end

-- Clear every host global between sections so one host cannot mask another.
local function ClearHosts()
  Baganator, Bagnon, ArkInventory, ElvUI, LibStub = nil, nil, nil, nil, nil
  loadedAddons = {}
  containerItems = {}
end

-- ============================================================ Blizzard.lua

ClearHosts()
do
  local ns = NewNS()
  Load("Blizzard.lua", ns)

  check("Blizzard hooks the global SetItemButtonQuality",
    type(globalHooks.SetItemButtonQuality), "function")

  local button = {}
  globalHooks.SetItemButtonQuality(button, 3, "|Hitem:101|h")
  check("Blizzard forwards the button to Core", ns.last().button, button)
  check("Blizzard forwards the quality", ns.last().quality, 3)
  check("Blizzard forwards the item it was handed", ns.last().itemIDOrLink, "|Hitem:101|h")

  -- The global fires for buttons that are not item buttons at all.
  local before = #ns.calls
  globalHooks.SetItemButtonQuality(nil)
  check("Blizzard ignores a nil button", #ns.calls, before)
end

-- =========================================================== Baganator.lua

ClearHosts()
do
  local ns = NewNS()
  local listeners, allFrames = {}, {}
  Baganator = {
    API = {
      Skins = {
        GetAllFrames = function() return allFrames end,
        RegisterListener = function(fn) listeners[#listeners + 1] = fn end,
      },
    },
  }

  -- A button built before we loaded, plus a bag-bar icon that must be skipped.
  local preexisting = {SetItemButtonQuality = function() end}
  local bagBarIcon = {SetItemButtonQuality = function() end}
  allFrames = {
    {regionType = "ItemButton", region = preexisting},
    {regionType = "ItemButton", region = bagBarIcon, tags = {"containerBag"}},
    {regionType = "ButtonFrame", region = {}},
  }

  Load("Baganator.lua", ns)

  check("Baganator registers a skin listener", #listeners, 1)
  check("Baganator hooks a pre-existing item button",
    type(methodHooks[preexisting] and methodHooks[preexisting].SetItemButtonQuality), "function")
  check("Baganator skips the bag-bar icons", methodHooks[bagBarIcon], nil)

  -- A button created later arrives through the listener.
  local later = {SetItemButtonQuality = function() end}
  listeners[1]({regionType = "ItemButton", region = later})
  check("Baganator hooks a later item button",
    type(methodHooks[later] and methodHooks[later].SetItemButtonQuality), "function")

  methodHooks[later].SetItemButtonQuality(later, 3, "|Hitem:101|h[Thing]|h")
  check("Baganator forwards the button to Core", ns.last().button, later)
  check("Baganator forwards the item it was handed",
    ns.last().itemIDOrLink, "|Hitem:101|h[Thing]|h")

  -- Baganator binds its stacked "Empty" button to a real bag and slot, but
  -- renders nothing when told to display empty even if that slot has contents
  -- (ItemButton.lua: "Keep cache and display in sync"). Reading the slot
  -- ourselves would paint an item onto a button showing an empty stack.
  local emptyStack = {SetItemButtonQuality = function() end, bagID = 0, GetID = function() return 1 end}
  containerItems["0:1"] = 101
  listeners[1]({regionType = "ItemButton", region = emptyStack})
  methodHooks[emptyStack].SetItemButtonQuality(emptyStack, nil, nil)
  -- The hook args, not the bound slot, are what reach Core. That slot holds an
  -- item; forwarding the args is what stops it being painted.
  check("Baganator empty stack forwards no item", ns.last().itemIDOrLink, nil)
  check("Baganator empty stack forwards no quality", ns.last().quality, nil)
  check("Baganator empty stack goes through the quality path", ns.last().fromQuality, true)

  -- Hooking the same button twice would double every update.
  listeners[1]({regionType = "ItemButton", region = later})
  check("Baganator marks a button as hooked", later.expansionGlowHooked, true)

  -- Baganator registers its cached bag slots twice: once tagged containerBag
  -- (ContainerSlots.lua:481) and once with no tags at all (:497). Skipping only
  -- the tagged registration lets the second one hook the bag bar.
  local bagBarButton = {SetItemButtonQuality = function() end, isBag = true}
  listeners[1]({regionType = "ItemButton", region = bagBarButton, tags = {"containerBag"}})
  listeners[1]({regionType = "ItemButton", region = bagBarButton})
  check("Baganator keeps skipping a bag slot re-registered untagged",
    methodHooks[bagBarButton], nil)
end

ClearHosts()
do
  local ns = NewNS()
  Load("Baganator.lua", ns)
  check("Baganator inert without its host", next(methodHooks), nil)
end

-- ============================================================== Bagnon.lua

ClearHosts()
do
  local ns = NewNS()
  Bagnon = {Item = {}}
  Load("Bagnon.lua", ns)

  local hook = methodHooks[Bagnon.Item] and methodHooks[Bagnon.Item].Update
  check("Bagnon hooks Item:Update", type(hook), "function")

  -- Live view: the button reports its own link.
  local live = {GetItem = function() return "|Hitem:102|h[Thing]|h" end}
  hook(live)
  check("Bagnon resolves the item from GetItem", ns.last().itemID, 102)
  check("Bagnon supplies the item itself", ns.last().viaItem, true)

  -- Guild bank cells expose the link through GetInfo instead.
  local viaInfo = {
    GetItem = function() return nil end,
    GetInfo = function() return {link = "|Hitem:103|h[Other]|h"} end,
  }
  hook(viaInfo)
  check("Bagnon falls back to GetInfo().link", ns.last().itemID, 103)

  -- Empty slot.
  local empty = {GetItem = function() return nil end, GetInfo = function() return {} end}
  hook(empty)
  check("Bagnon reports nil for an empty slot", ns.last().itemID, nil)
  check("Bagnon still clears the button", ns.last().button, empty)
end

ClearHosts()
do
  local ns = NewNS()
  Load("Bagnon.lua", ns)
  check("Bagnon inert without its host", next(methodHooks), nil)
end

-- ========================================================== BetterBags.lua

ClearHosts()
do
  local ns = NewNS()
  loadedAddons.BetterBags = true

  local messages = {}
  local eventsModule = {
    RegisterMessage = function(_, name, fn) messages[name] = fn end,
  }
  local betterBags = {
    GetModule = function(_, name) return name == "Events" and eventsModule or nil end,
  }
  LibStub = function(name)
    if name == "AceAddon-3.0" then
      return {GetAddon = function(_, n) return n == "BetterBags" and betterBags or nil end}
    end
  end

  Load("BetterBags.lua", ns)
  check("BetterBags subscribes to item/Updated", type(messages["item/Updated"]), "function")

  containerItems["0:4"] = 104
  local button = {}
  messages["item/Updated"](nil, {button = button, data = {bagid = 0, slotid = 4}})
  check("BetterBags resolves via bagid/slotid", ns.last().itemID, 104)
  check("BetterBags targets the item button", ns.last().button, button)

  -- Some cell types nest the real frame.
  local inner = {}
  messages["item/Updated"](nil, {button = {frame = inner}, data = {bagid = 0, slotid = 4}})
  check("BetterBags prefers button.frame when present", ns.last().button, inner)

  -- Slot not readable through C_Container: fall back to the reported item.
  messages["item/Updated"](nil, {button = button, data = {itemInfo = {itemID = 105}}})
  check("BetterBags falls back to data.itemInfo", ns.last().itemID, 105)

  local before = #ns.calls
  messages["item/Updated"](nil, {})
  check("BetterBags ignores an item with no button", #ns.calls, before)
end

ClearHosts()
do
  local ns = NewNS()
  Load("BetterBags.lua", ns)
  check("BetterBags inert without its host", next(globalHooks), nil)
end

-- ======================================================== ArkInventory.lua

ClearHosts()
do
  local ns = NewNS()
  loadedAddons.ArkInventory = true

  local existing = {ARK_Data = {blizzard_id = 0, slot_id = 7}}
  ArkInventory = {
    API = {
      ItemFrameUpdated = function() end,
      ItemFrameLoadedIterate = function()
        local done = false
        return function()
          if done then return nil end
          done = true
          return "frame1", existing
        end
      end,
    },
  }

  Load("ArkInventory.lua", ns)

  check("ArkInventory hooks ItemFrameUpdated",
    type(methodHooks[ArkInventory.API] and methodHooks[ArkInventory.API].ItemFrameUpdated),
    "function")
  check("ArkInventory sweeps already-built frames", ns.calls[1].button, existing)

  local later = {ARK_Data = {blizzard_id = 0, slot_id = 8}}
  methodHooks[ArkInventory.API].ItemFrameUpdated(later)
  check("ArkInventory forwards updated frames", ns.last().button, later)
  check("ArkInventory lets Core read ARK_Data", ns.last().viaItem, false)

  local before = #ns.calls
  methodHooks[ArkInventory.API].ItemFrameUpdated(nil)
  check("ArkInventory ignores a nil frame", #ns.calls, before)
end

ClearHosts()
do
  local ns = NewNS()
  Load("ArkInventory.lua", ns)
  check("ArkInventory inert without its host", next(methodHooks), nil)
end

-- =============================================================== ElvUI.lua

ClearHosts()
do
  local ns = NewNS()
  loadedAddons.ElvUI = true

  local slot = {BagID = 0, SlotID = 3}
  local bagsModule = {UpdateSlot = function() end}
  local E = {
    GetModule = function(_, name) return name == "Bags" and bagsModule or nil end,
  }
  ElvUI = {E}

  Load("ElvUI.lua", ns)

  local hook = methodHooks[bagsModule] and methodHooks[bagsModule].UpdateSlot
  check("ElvUI hooks the Bags module UpdateSlot", type(hook), "function")

  -- UpdateSlot is a method, so the hook receives self first.
  local frame = {Bags = {[0] = {[3] = slot}}}
  hook(bagsModule, frame, 0, 3)
  check("ElvUI resolves the slot from frame.Bags", ns.last().button, slot)
  check("ElvUI lets Core read BagID/SlotID", ns.last().viaItem, false)

  local before = #ns.calls
  hook(bagsModule, frame, 9, 9)
  check("ElvUI ignores an unknown bag or slot", #ns.calls, before)
  hook(bagsModule, nil, 0, 3)
  check("ElvUI ignores a nil frame", #ns.calls, before)
end

ClearHosts()
do
  local ns = NewNS()
  Load("ElvUI.lua", ns)
  check("ElvUI inert without its host", next(methodHooks), nil)
end

io.write(string.format("\n%d checks, %d failures\n", checks, failures))
os.exit(failures == 0 and 0 or 1)
