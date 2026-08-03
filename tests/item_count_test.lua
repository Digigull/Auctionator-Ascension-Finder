-- Tests for AuctionatorFinderItemCount.lua -- the item-quantity / storage-
-- location tooltip feature.  Exercises the pure logic without a game client:
--   * Atr_ItemCount_ScanBags    - walking containers into the per-character cache
--   * Atr_ItemCount_ScanWebBank - walking the web-shop bank, tab classification
--   * Atr_ItemCount_Query       - totalling across characters + web banks
--   * Atr_ItemCount_AddToTip    - the tooltip lines, modifier gating, breadcrumb
--   * legacy (Phase-1 flat) saved-var migration into the nested layout
--
-- Run:  lua5.1 tests/item_count_test.lua   (from the repo root)

-- ---- Minimal WoW/client surface the module touches ----

_G.time = os.time

_G.NUM_BAG_SLOTS               = 4
_G.NUM_BANKBAGSLOTS            = 7
_G.MAX_GUILDBANK_SLOTS_PER_TAB = 98
_G.RAID_CLASS_COLORS           = {}

local mod = { shift = false, ctrl = false, alt = false }
_G.IsShiftKeyDown   = function () return mod.shift end
_G.IsControlKeyDown = function () return mod.ctrl  end
_G.IsAltKeyDown     = function () return mod.alt   end

_G.UnitName         = function () return "CharA" end
_G.GetRealmName     = function () return "Realm" end
_G.UnitClass        = function () return "Mage", "MAGE" end
_G.UnitFactionGroup = function () return "Alliance" end

_G.ZT = function (s) return s end

-- Character container stubs.
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

-- Guild-bank (web-shop) stubs.
local gbank = { tabNames = {}, tabs = {} }   -- tabs[tab] = { {id=, count=}, ... }
_G.GetNumGuildBankTabs   = function () return #gbank.tabNames end
_G.GetGuildBankTabInfo   = function (t) return gbank.tabNames[t] end
_G.GetGuildBankItemLink  = function (t, s)
  local e = gbank.tabs[t] and gbank.tabs[t][s]
  return e and ("item:" .. e.id) or nil
end
_G.GetGuildBankItemInfo  = function (t, s)
  local e = gbank.tabs[t] and gbank.tabs[t][s]
  return nil, e and e.count or nil
end

-- Capture the module's event frame so the tests can drive its scans exactly as
-- the client would (fire an event, then tick past the debounce delay).
local frame
_G.CreateFrame = function ()
  local fr = { scripts = {} }
  function fr:RegisterEvent () end
  function fr:SetScript (name, fn) self.scripts[name] = fn end
  function fr:Hide () end
  function fr:Show () end
  frame = fr
  return fr
end

local addonTable = { zc = {
  ItemIDfromLink = function (link) return link and link:match ("item:(%d+)") end,
} }

local chunk, err = loadfile ("Auctionator-Finder-Ascension/AuctionatorFinderItemCount.lua")
assert (chunk, "loadfile failed: " .. tostring (err))
assert (pcall (chunk, "Auctionator-Finder-Ascension", addonTable))
assert (frame, "the module did not create its event frame")

-- Fire an event and then run the debounced scan (0.4s DELAY -> tick 1s past it).
local function drive (event)
  frame.scripts.OnEvent (frame, event)
  frame.scripts.OnUpdate (frame, 1.0)
end

local pass = 0
local function ok (cond, msg)
  assert (cond, "FAIL: " .. msg)
  pass = pass + 1
  print (string.format ("PASS %d  %s", pass, msg))
end

local function newTip ()
  local t = { lines = {}, shown = 0 }
  function t:AddDoubleLine (l, r) self.lines[#self.lines + 1] = { l = l, r = r } end
  function t:AddLine (l)          self.lines[#self.lines + 1] = { l = l } end
  function t:Show ()              self.shown = self.shown + 1 end
  return t
end

local function stripColor (s) return (s or ""):gsub ("|c%x%x%x%x%x%x%x%x", ""):gsub ("|r", "") end

-- ---- Legacy (Phase-1 flat) migration ----

AUCTIONATOR_ITEM_LOCATIONS = {
  ["Realm-Old"] = { name = "Old", realm = "Realm", bags = { [100] = 7 }, bank = {} },
}
local mt = Atr_ItemCount_Query (100)   -- any query forces EnsureDB -> migration
ok (AUCTIONATOR_ITEM_LOCATIONS.chars ~= nil,                 "migration creates a .chars table")
ok (AUCTIONATOR_ITEM_LOCATIONS.chars["Realm-Old"] ~= nil,    "the legacy character is lifted into .chars")
ok (AUCTIONATOR_ITEM_LOCATIONS["Realm-Old"] == nil,          "the legacy top-level entry is removed")
ok (mt == 7,                                                 "the migrated character's items still total correctly")

-- ---- Atr_ItemCount_ScanBags: containers -> current character's bag cache ----

AUCTIONATOR_ITEM_LOCATIONS = {}
bagData = {
  [0] = { { id = 100, count = 3 } },
  [1] = { { id = 100, count = 2 }, { id = 200, count = 1 } },
}
Atr_ItemCount_ScanBags ()
local me = AUCTIONATOR_ITEM_LOCATIONS.chars["Realm-CharA"]
ok (me ~= nil,               "scanning creates the current-character entry under .chars")
ok (me.bags[100] == 5,       "counts of one item across bags are summed (3 + 2)")
ok (me.bags[200] == 1,       "a second item is tracked independently")
ok (me.class == "MAGE",      "the character's class is recorded for colouring")

-- ---- Atr_ItemCount_ScanWebBank via the event frame ----

-- The realm bank: tab 1 is honestly "Realm Bank"; later tabs are misnamed
-- "Personal Bank" but hold realm storage, so the whole window buckets as 'realm'
-- (confirmed in-game: the two windows' same-named tabs held different items).
gbank.tabNames = { "Realm Bank", "Personal Bank", "Personal Bank" }
gbank.tabs = {
  [1] = { { id = 300, count = 4 } },
  [2] = {},
  [3] = { { id = 300, count = 6 }, { id = 400, count = 1 } },
}
drive ("GUILDBANKFRAME_OPENED")

local w = AUCTIONATOR_ITEM_LOCATIONS.webbanks["Realm"]
ok (w and w.realm ~= nil,          "a realm-bank window is cached under webbanks[realm].realm")
ok (w.personal == nil,             "it is NOT recorded as a personal bank (tab 1 name wins)")
ok (w.realm.totals[300] == 10,     "item counts are summed across the window's tabs (4 + 6)")
ok (w.realm.ntabs == 3,            "the tab count is recorded")

local qt, _, wl = Atr_ItemCount_Query (300)
ok (qt == 10,                      "Query totals the web-bank holding")
ok (#wl == 1 and wl[1].kind == "realm", "the holding is attributed to the realm bank")
ok (wl[1].tabs[1] == 1 and wl[1].tabs[2] == 3, "the tabs holding it are listed (1 and 3, not empty 2)")

-- A personal-bank window (only "Personal Bank" tabs) buckets as 'personal', and
-- leaves the realm-bank cache untouched.
gbank.tabNames = { "Personal Bank", "Personal Bank" }
gbank.tabs = { [1] = { { id = 300, count = 1 } }, [2] = { { id = 500, count = 9 } } }
drive ("GUILDBANKFRAME_OPENED")
ok (w.personal ~= nil and w.personal.totals[500] == 9, "a personal-bank window caches under .personal")
ok (w.realm.totals[300] == 10,     "opening the personal bank did not clobber the realm cache")

-- The genuine guild bank reports zero tabs and must be ignored.
gbank.tabNames = {}
gbank.tabs = {}
local beforePersonal = w.personal.totals[500]
drive ("GUILDBANKFRAME_OPENED")
ok (w.personal.totals[500] == beforePersonal, "a 0-tab (real guild) bank leaves the cache untouched")

-- ---- Query across characters AND web banks together ----

AUCTIONATOR_ITEM_LOCATIONS = {
  chars = {
    ["Realm-CharA"] = { name = "CharA", realm = "Realm", bags = { [100] = 20 }, bank = { [100] = 10 } },
    ["Realm-CharB"] = { name = "CharB", realm = "Realm", bags = { [100] = 5  }, bank = {}            },
  },
  webbanks = {
    ["Realm"] = {
      personal = { ntabs = 1, totals = { [100] = 8 }, tabs = { [1] = { [100] = 8 } } },
      realm    = { ntabs = 1, totals = { [100] = 2 }, tabs = { [1] = { [100] = 2 } } },
    },
  },
}
local total, list, web = Atr_ItemCount_Query (100)
ok (total == 45,             "Query sums characters (20+10+5) and web banks (8+2)")
ok (#list == 2,              "both holding characters are listed")
ok (list[1].name == "CharA", "the current character sorts first")
ok (#web == 2,               "both web banks that hold the item are listed")
ok (web[1].kind == "personal" and web[2].kind == "realm", "web banks list personal before realm")
ok (Atr_ItemCount_Query (777) == 0, "an item held nowhere totals zero")

-- ---- Atr_ItemCount_AddToTip: the rendered lines ----

AUCTIONATOR_QTY_TIPS     = 5   -- quantity always
AUCTIONATOR_QTY_LOC_TIPS = 3   -- locations on ALT

-- ALT up: Qty line + breadcrumb only.
mod.alt = false
local tip = newTip ()
Atr_ItemCount_AddToTip (tip, 100)
ok (#tip.lines == 2,                              "ALT up -> Qty line + one breadcrumb line")
ok (stripColor (tip.lines[1].l) == "Qty",         "the first line is labelled Qty")
ok (stripColor (tip.lines[1].r) == "45",          "the Qty line shows the grand total")
ok (stripColor (tip.lines[2].l):find ("ALT"),     "the breadcrumb names the ALT modifier")

-- ALT down: Qty + 2 character lines + 2 web-bank lines.
mod.alt = true
tip = newTip ()
Atr_ItemCount_AddToTip (tip, 100)
ok (#tip.lines == 5,                              "ALT down -> Qty + per-character + per-web-bank lines")
ok (stripColor (tip.lines[2].l):find ("CharA"),   "the first location line is the current character")
ok (stripColor (tip.lines[2].r) == "20 bags, 10 bank", "bags and bank are both itemised")
ok (stripColor (tip.lines[4].l):find ("Personal Bank"), "a Personal Bank line appears")
ok (stripColor (tip.lines[4].r) == "8",           "the Personal Bank line shows its count")
ok (stripColor (tip.lines[5].l):find ("Realm Bank"),    "a Realm Bank line appears")

-- Quantity mode 'never' stays silent.
AUCTIONATOR_QTY_TIPS = 4
tip = newTip ()
Atr_ItemCount_AddToTip (tip, 100)
ok (#tip.lines == 0,                              "quantity mode 'never' draws nothing")

-- Unheld item draws nothing.
AUCTIONATOR_QTY_TIPS = 5
tip = newTip ()
Atr_ItemCount_AddToTip (tip, 12345)
ok (#tip.lines == 0,                              "an unheld item adds no lines")

print ("\nALL ITEM COUNT TESTS PASSED (" .. pass .. " checks)")
