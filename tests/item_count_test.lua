-- Tests for AuctionatorFinderItemCount.lua -- the item-quantity / bag-location
-- tooltip feature.  Exercises the pure logic without a game client:
--   * Atr_ItemCount_ScanBags   - walking containers into the per-character cache
--   * Atr_ItemCount_Query      - totalling across characters, sort order
--   * Atr_ItemCount_AddToTip   - the tooltip lines, modifier gating, breadcrumb
--
-- Run:  lua5.1 tests/item_count_test.lua   (from the repo root)

-- ---- Minimal WoW/client surface the module touches ----

_G.time = os.time

_G.NUM_BAG_SLOTS     = 4
_G.NUM_BANKBAGSLOTS  = 7
_G.RAID_CLASS_COLORS = {}

-- Modifier state, driven by the tests.
local mod = { shift = false, ctrl = false, alt = false }
_G.IsShiftKeyDown   = function () return mod.shift end
_G.IsControlKeyDown = function () return mod.ctrl  end
_G.IsAltKeyDown     = function () return mod.alt   end

-- Current character identity.
_G.UnitName         = function () return "CharA" end
_G.GetRealmName     = function () return "Realm" end
_G.UnitClass        = function () return "Mage", "MAGE" end
_G.UnitFactionGroup = function () return "Alliance" end

_G.ZT = function (s) return s end

-- Container stubs, filled per-test via `bagData`.
local bagData = {}   -- [bag] = { {id=, count=}, ... }
_G.GetContainerNumSlots  = function (bag) return bagData[bag] and #bagData[bag] or 0 end
_G.GetContainerItemLink  = function (bag, slot)
  local e = bagData[bag] and bagData[bag][slot]
  return e and ("item:" .. e.id) or nil
end
_G.GetContainerItemInfo  = function (bag, slot)
  local e = bagData[bag] and bagData[bag][slot]
  return nil, e and e.count or nil
end

-- A CreateFrame dummy so the load-time event wiring succeeds.
_G.CreateFrame = function ()
  local fr = {}
  function fr:RegisterEvent () end
  function fr:SetScript () end
  function fr:Hide () end
  function fr:Show () end
  return fr
end

local addonTable = { zc = {
  ItemIDfromLink = function (link) return link and link:match ("item:(%d+)") end,
} }

local chunk, err = loadfile ("Auctionator-Finder-Ascension/AuctionatorFinderItemCount.lua")
assert (chunk, "loadfile failed: " .. tostring (err))
assert (pcall (chunk, "Auctionator-Finder-Ascension", addonTable))

local pass = 0
local function ok (cond, msg)
  assert (cond, "FAIL: " .. msg)
  pass = pass + 1
  print (string.format ("PASS %d  %s", pass, msg))
end

-- A fake tooltip that records what the feature draws onto it.
local function newTip ()
  local t = { lines = {}, shown = 0 }
  function t:AddDoubleLine (l, r) self.lines[#self.lines + 1] = { l = l, r = r } end
  function t:AddLine (l)          self.lines[#self.lines + 1] = { l = l } end
  function t:Show ()              self.shown = self.shown + 1 end
  return t
end

local function stripColor (s) return (s or ""):gsub ("|c%x%x%x%x%x%x%x%x", ""):gsub ("|r", "") end

-- ---- Atr_ItemCount_ScanBags: containers -> current character's bag cache ----

AUCTIONATOR_ITEM_LOCATIONS = {}
bagData = {
  [0] = { { id = 100, count = 3 } },
  [1] = { { id = 100, count = 2 }, { id = 200, count = 1 } },
}
Atr_ItemCount_ScanBags ()
local me = AUCTIONATOR_ITEM_LOCATIONS["Realm-CharA"]
ok (me ~= nil,               "scanning creates the current-character entry")
ok (me.bags[100] == 5,       "counts of one item across bags are summed (3 + 2)")
ok (me.bags[200] == 1,       "a second item is tracked independently")
ok (me.class == "MAGE",      "the character's class is recorded for colouring")

-- ---- Atr_ItemCount_Query: totalling across characters + sort order ----

AUCTIONATOR_ITEM_LOCATIONS = {
  ["Realm-CharA"] = { name = "CharA", realm = "Realm", bags = { [100] = 20 }, bank = { [100] = 10 } },
  ["Realm-CharB"] = { name = "CharB", realm = "Realm", bags = { [100] = 5  }, bank = {}            },
  ["Realm-CharC"] = { name = "CharC", realm = "Realm", bags = {},            bank = { [999] = 1 }  },
}
local total, list = Atr_ItemCount_Query (100)
ok (total == 35,             "Query totals the item across every character (20+10+5)")
ok (#list == 2,              "characters that do not hold the item are excluded")
ok (list[1].name == "CharA", "the current character sorts first")
ok (list[1].bags == 20 and list[1].bank == 10, "the current character's split is reported")
ok (list[2].name == "CharB", "other holders follow, largest-first")

ok (Atr_ItemCount_Query (999) == 1, "an item only in a bank is still counted")
ok (Atr_ItemCount_Query (12345) == 0, "an unheld item totals zero")

-- ---- Atr_ItemCount_AddToTip: the rendered lines ----

-- Default modes: quantity always (5), locations on ALT (3).
AUCTIONATOR_QTY_TIPS     = 5
AUCTIONATOR_QTY_LOC_TIPS = 3

-- ALT up: just the Qty line, plus the discoverability breadcrumb.
mod.alt = false
local tip = newTip ()
Atr_ItemCount_AddToTip (tip, 100)
ok (#tip.lines == 2,                              "ALT up -> Qty line + one breadcrumb line")
ok (stripColor (tip.lines[1].l) == "Qty",         "the first line is labelled Qty")
ok (stripColor (tip.lines[1].r) == "35",          "the Qty line shows the grand total")
ok (stripColor (tip.lines[2].l):find ("ALT"),     "the breadcrumb names the ALT modifier")

-- ALT down: Qty line + one location line per holder.
mod.alt = true
tip = newTip ()
Atr_ItemCount_AddToTip (tip, 100)
ok (#tip.lines == 3,                              "ALT down -> Qty line + one line per holder")
ok (stripColor (tip.lines[2].l):find ("CharA"),   "the first location line is the current character")
ok (stripColor (tip.lines[2].r) == "20 bags, 10 bank", "bags and bank are both itemised")
ok (stripColor (tip.lines[3].r) == "5 bags",      "a bags-only holder omits the bank clause")

-- Quantity mode 'never' (4): the feature stays silent regardless of modifier.
AUCTIONATOR_QTY_TIPS = 4
tip = newTip ()
Atr_ItemCount_AddToTip (tip, 100)
ok (#tip.lines == 0,                              "quantity mode 'never' draws nothing")

-- Back to always; an item nobody owns draws nothing.
AUCTIONATOR_QTY_TIPS = 5
tip = newTip ()
Atr_ItemCount_AddToTip (tip, 12345)
ok (#tip.lines == 0,                              "an unheld item adds no lines")

-- Locations 'always' (5): breakdown shows even with no modifier held.
AUCTIONATOR_QTY_LOC_TIPS = 5
mod.alt = false
tip = newTip ()
Atr_ItemCount_AddToTip (tip, 100)
ok (#tip.lines == 3,                              "locations mode 'always' shows the breakdown with no modifier")

print ("\nALL ITEM COUNT TESTS PASSED (" .. pass .. " checks)")
