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
ok (w and w.realm ~= nil,          "a realm-bank window is cached (shared) under webbanks[realm].realm")
ok (w.personal == nil,             "the realm bank is not a personal bank (tab 1 name wins)")
ok (w.realm.totals[300] == 10,     "item counts are summed across the window's tabs (4 + 6)")
ok (w.realm.ntabs == 3,            "the tab count is recorded")

local qt, _, wl = Atr_ItemCount_Query (300)
ok (qt == 10,                      "Query totals the realm-bank holding")
ok (#wl == 1 and wl[1].kind == "realm", "the holding is attributed to the realm bank")
ok (wl[1].tabs[1] == 1 and wl[1].tabs[2] == 3, "the tabs holding it are listed (1 and 3, not empty 2)")

-- A personal-bank window (only "Personal Bank" tabs) belongs to the CURRENT
-- character -- stored on the character entry, not the shared realm vault.
gbank.tabNames = { "Personal Bank", "Personal Bank" }
gbank.tabs = { [1] = { { id = 300, count = 1 } }, [2] = { { id = 500, count = 9 } } }
drive ("GUILDBANKFRAME_OPENED")
local ch = AUCTIONATOR_ITEM_LOCATIONS.chars["Realm-CharA"]
ok (ch.personal ~= nil and ch.personal.totals[500] == 9, "a personal-bank window caches on the character")
ok (w.personal == nil,             "the personal bank is NOT stored in the shared realm vault")
ok (w.realm.totals[300] == 10,     "opening the personal bank did not clobber the realm cache")

-- A fresh open where a tab has not streamed in yet (reads empty) must NOT wipe
-- that tab's previously-cached contents -- the reported bug where the count
-- vanished on open and came back on clicking the tab.  Tab 2 (holding item 500)
-- now reads empty; tab 1 is still loaded.
gbank.tabNames = { "Personal Bank", "Personal Bank" }
gbank.tabs = { [1] = { { id = 300, count = 1 } }, [2] = {} }
drive ("GUILDBANKFRAME_OPENED")
ok (ch.personal.totals[500] == 9, "an unloaded tab keeps its cached count (no wipe on open)")
ok (ch.personal.totals[300] == 1, "the loaded tab still refreshes normally")

-- When that tab finally streams in, its real contents refresh the cache.
gbank.tabs = { [1] = { { id = 300, count = 1 } }, [2] = { { id = 500, count = 12 } } }
drive ("GUILDBANKBAGSLOTS_CHANGED")
ok (ch.personal.totals[500] == 12, "once the tab loads, its count refreshes to the live value")

-- The genuine guild bank reports zero tabs and must be ignored.
gbank.tabNames = {}
gbank.tabs = {}
local beforePersonal = ch.personal.totals[500]
drive ("GUILDBANKFRAME_OPENED")
ok (ch.personal.totals[500] == beforePersonal, "a 0-tab (real guild) bank leaves the cache untouched")

-- Legacy shared-personal data from the earlier build is dropped on load.
AUCTIONATOR_ITEM_LOCATIONS.webbanks["Realm"].personal = { ntabs = 1, totals = { [123] = 5 }, tabs = {} }
Atr_ItemCount_Query (1)   -- forces EnsureDB migration
ok (AUCTIONATOR_ITEM_LOCATIONS.webbanks["Realm"].personal == nil, "legacy shared personal-bank data is migrated out")

-- ---- Query across characters AND web banks together ----

AUCTIONATOR_ITEM_LOCATIONS = {
  chars = {
    ["Realm-CharA"] = { name = "CharA", realm = "Realm", bags = { [100] = 20 }, bank = { [100] = 10 },
                        personal = { ntabs = 1, totals = { [100] = 8 }, tabs = { [1] = { [100] = 8 } } } },
    ["Realm-CharB"] = { name = "CharB", realm = "Realm", bags = { [100] = 5  }, bank = {} },
  },
  webbanks = {
    ["Realm"] = { realm = { ntabs = 1, totals = { [100] = 2 }, tabs = { [1] = { [100] = 2 } } } },
  },
}
local total, list, web = Atr_ItemCount_Query (100)
ok (total == 45,             "Query sums bags/bank/personal (20+10+8+5) and the realm bank (2)")
ok (#list == 2,              "both holding characters are listed")
ok (list[1].name == "CharA", "the current character sorts first")
ok (list[1].personal == 8,   "the current character's personal-bank count is attributed to them")
ok (list[2].personal == 0,   "a character with no personal bank shows zero, not another's count")
ok (#web == 1 and web[1].kind == "realm", "only the shared realm bank appears as a web line")
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

-- ALT down: Qty + 2 character lines + 1 shared realm-bank line.
mod.alt = true
tip = newTip ()
Atr_ItemCount_AddToTip (tip, 100)
ok (#tip.lines == 4,                              "ALT down -> Qty + 2 character lines + 1 realm-bank line")
ok (stripColor (tip.lines[2].l):find ("CharA"),   "the first location line is the current character")
ok (stripColor (tip.lines[2].r):find ("20 bags, 10 bank, 8 Personal Bank %(tab 1%)"),
                                                  "the current character's line itemises bags, bank AND their personal bank (with tab)")
ok (not stripColor (tip.lines[3].r):find ("Personal"), "the other character's line has no personal bank")
ok (stripColor (tip.lines[4].l):find ("Realm Bank"),   "the shared Realm Bank appears as its own line")
ok (stripColor (tip.lines[4].r) == "2",           "the Realm Bank line shows its count")

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
