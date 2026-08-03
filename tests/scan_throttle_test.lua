-- Regression tests for the gentle NPC / profession scan path.
--
-- Covers the three files split out to make opening a vendor or profession
-- window less aggressive:
--   * AuctionatorFinderScanThrottle.lua  -- the session "already scanned" ledger
--   * AuctionatorFinderProfession.lua    -- trade-skill harvest (returns warmth)
--   * AuctionatorFinderMerchant.lua      -- unified, debounced merchant harvest
--
-- The point of the change is that a merchant/profession is walked ONCE per
-- session (a beat after the update storm goes quiet), then skipped.  So the
-- tests assert both the harvest results AND that a second open of the same
-- merchant does not re-walk the list.
--
-- Run:  lua5.1 tests/scan_throttle_test.lua   (from the repo root)

local pass = 0
local function ok (cond, msg)
  assert (cond, "FAIL: " .. msg)
  pass = pass + 1
  print (string.format ("PASS %d  %s", pass, msg))
end

-- ---- mock WoW surface ------------------------------------------------------

tinsert = table.insert

-- Every CreateFrame'd frame is collected so the test can drive its OnEvent /
-- OnUpdate by hand (there is no game loop here).
local FRAMES = {}
function CreateFrame (_, name)
  local fr = { _scripts = {}, _events = {}, _shown = false, _name = name }
  function fr:RegisterEvent (e) self._events[e] = true end
  function fr:UnregisterEvent (e) self._events[e] = nil end
  function fr:SetScript (k, fn) self._scripts[k] = fn end
  function fr:GetScript (k) return self._scripts[k] end
  function fr:Show () self._shown = true end
  function fr:Hide () self._shown = false end
  function fr:IsShown () return self._shown end
  FRAMES[#FRAMES + 1] = fr
  return fr
end
UIParent = {}
DEFAULT_CHAT_FRAME = { AddMessage = function () end }

local function frameWithEvent (ev)
  for _, fr in ipairs (FRAMES) do if fr._events[ev] then return fr end end
end

-- itemID from a link like "item:1234"
zc = { ItemIDfromLink = function (link) return tonumber (tostring (link):match ("item:(%d+)")) end }

-- ---- mock merchant ----------------------------------------------------------

-- Each slot: { link=, price=, qty=, avail=, ext=, itype= }
local gMerchant = {}
local gMerchantInfoCalls = 0   -- counts full-walk reads, to detect a re-scan

function UnitName (unit) return unit == "npc" and "TestVendor" or nil end

function GetMerchantNumItems () return #gMerchant end
function GetMerchantItemLink (i) local s = gMerchant[i]; return s and s.link or nil end
function GetMerchantItemInfo (i)
  gMerchantInfoCalls = gMerchantInfoCalls + 1
  local s = gMerchant[i]
  if not s then return end
  -- name, texture, price, quantity, numAvailable, isUsable, extendedCost
  return "item"..i, nil, s.price, s.qty, s.avail, true, s.ext
end
-- GetItemInfo: name, link, quality, iLevel, reqLevel, itemType, ...
function GetItemInfo (link)
  for _, s in ipairs (gMerchant) do
    if s.link == link then return "item", link, 1, 1, 1, s.itype end
  end
  return nil
end

-- ---- mock trade skill -------------------------------------------------------

-- Each row: { header=bool, link=, made=, reagents={ {link=,count=}, ... } }
local gSkills = {}
local gSkillLine = "Tailoring"

function GetTradeSkillLine () return gSkillLine end
function GetNumTradeSkills () return #gSkills end
function GetTradeSkillInfo (i)
  local r = gSkills[i]; if not r then return end
  return "row"..i, r.header and "header" or "optimal"
end
function GetTradeSkillItemLink (i) local r = gSkills[i]; return r and r.link or nil end
function GetTradeSkillNumMade (i) local r = gSkills[i]; return r and r.made or 1 end
function GetTradeSkillNumReagents (i) local r = gSkills[i]; return r and r.reagents and #r.reagents or 0 end
function GetTradeSkillReagentInfo (i, j)
  local r = gSkills[i]; local g = r and r.reagents and r.reagents[j]
  if not g then return end
  return "reagent", nil, g.count
end
function GetTradeSkillReagentItemLink (i, j)
  local r = gSkills[i]; local g = r and r.reagents and r.reagents[j]
  return g and g.link or nil
end

-- ---- load the split files under one shared addon table ----------------------

local addonTable = {}
local function load_addon_file (path)
  local chunk, err = loadfile (path)
  assert (chunk, "loadfile failed: " .. path .. ": " .. tostring (err))
  local okc, lerr = pcall (chunk, "Auctionator-Finder-Ascension", addonTable)
  assert (okc, "load-time error in " .. path .. ": " .. tostring (lerr))
end

local DIR = "Auctionator-Finder-Ascension/"
load_addon_file (DIR .. "AuctionatorFinderScanThrottle.lua")
load_addon_file (DIR .. "AuctionatorFinderProfession.lua")
load_addon_file (DIR .. "AuctionatorFinderMerchant.lua")

ok (type (Fdr_ScanThrottle_Seen) == "function", "throttle exports Fdr_ScanThrottle_Seen")
ok (type (Fdr_ScanThrottle_Mark) == "function", "throttle exports Fdr_ScanThrottle_Mark")
ok (type (Atr_Craft_Harvest) == "function",     "profession exports Atr_Craft_Harvest")
ok (type (Atr_Craft_GetCraftCost) == "function","profession exports Atr_Craft_GetCraftCost")
ok (type (Atr_NPC_HarvestMerchant) == "function","merchant exports Atr_NPC_HarvestMerchant")
ok (type (Atr_GetNPCPrice) == "function",        "merchant exports Atr_GetNPCPrice")

-- ---- throttle ledger --------------------------------------------------------

Fdr_ScanThrottle_Reset ()
ok (Fdr_ScanThrottle_Seen ("v1") == false, "unseen signature reports not-seen")
Fdr_ScanThrottle_Mark ("v1")
ok (Fdr_ScanThrottle_Seen ("v1") == true,  "marked signature reports seen")
ok (Fdr_ScanThrottle_Seen ("v2") == false, "a different signature stays unseen")
ok (Fdr_ScanThrottle_Seen (nil) == false and Fdr_ScanThrottle_Seen ("") == false,
    "nil / empty signature is never seen")
Fdr_ScanThrottle_Reset ()
ok (Fdr_ScanThrottle_Seen ("v1") == false, "reset clears the ledger")

-- ---- NPC harvest: results + warmth -----------------------------------------

AUCTIONATOR_NPC_PRICES = nil
gMerchant = {
  { link = "item:111", price = 100, qty = 1, avail = -1, ext = nil, itype = "Trade Goods" }, -- learn
  { link = "item:222", price = 500, qty = 1, avail = -1, ext = nil, itype = "Weapon"      }, -- not trade goods
  { link = "item:333", price = 50,  qty = 1, avail = 5,  ext = nil, itype = "Trade Goods" }, -- limited stock
  { link = "item:444", price = 10,  qty = 5, avail = -1, ext = nil, itype = "Trade Goods" }, -- per-unit = 2
}
local stored, warm = Atr_NPC_HarvestMerchant ()
ok (stored == 2,  "NPC harvest stored exactly the two unlimited trade goods")
ok (warm == true, "NPC harvest with all links present reports warm")
ok (Atr_GetNPCPrice (111) == 100, "learned the plain unlimited trade good")
ok (Atr_GetNPCPrice (444) == 2,   "learned per-unit price from a stacked slot (10/5)")
ok (Atr_GetNPCPrice (222) == nil, "did not learn a non-trade-good")
ok (Atr_GetNPCPrice (333) == nil, "did not learn a limited-stock slot")

-- a slot whose link has not streamed in yet -> not warm (do not lock the scan)
gMerchant[2].link = nil
local _, warm2 = Atr_NPC_HarvestMerchant ()
ok (warm2 == false, "a cold (linkless) slot makes the harvest report not-warm")
gMerchant[2].link = "item:222"

-- ---- profession harvest: results + completeness ----------------------------

AUCTIONATOR_CRAFT_RECIPES = nil
gSkills = {
  { header = true },
  { link = "item:200", made = 2, reagents = { { link = "item:301", count = 4 } } },
  { link = "item:210", made = 1, reagents = { { link = "item:301", count = 1 }, { link = "item:302", count = 2 } } },
}
local cstored, complete = Atr_Craft_Harvest ()
ok (cstored == 2,     "craft harvest stored both recipe rows, skipping the header")
ok (complete == true, "craft harvest with all recipe links present reports complete")
ok (AUCTIONATOR_CRAFT_RECIPES[200] ~= nil and AUCTIONATOR_CRAFT_RECIPES[200].made == 2,
    "recipe stored by produced-item id with its yield")

-- a recipe row whose item data is still cold -> not complete (retry later)
gSkills[3].link = nil
local _, complete2 = Atr_Craft_Harvest ()
ok (complete2 == false, "a cold recipe row makes the harvest report not-complete")
gSkills[3].link = "item:210"

-- ---- craft cost via NPC reagent price --------------------------------------

-- reagent 301 is NPC-priced at 5 -> item 200 costs floor(5*4 / 2 made) = 10
AUCTIONATOR_NPC_PRICES = { [301] = 5 }
ok (Atr_Craft_GetCraftCost (200) == 10, "craft cost uses NPC reagent price and divides by yield")

-- ---- the whole point: a second open of the same vendor does NOT re-walk -----

Fdr_ScanThrottle_Reset ()
AUCTIONATOR_NPC_PRICES = nil
gMerchant = {
  { link = "item:111", price = 100, qty = 1, avail = -1, ext = nil, itype = "Trade Goods" },
  { link = "item:444", price = 10,  qty = 5, avail = -1, ext = nil, itype = "Trade Goods" },
}

local mf = frameWithEvent ("MERCHANT_SHOW")
ok (mf ~= nil, "merchant scan frame registered MERCHANT_SHOW")

-- open #1: event arms the settle timer, then the timer fires the harvest
gMerchantInfoCalls = 0
mf._scripts.OnEvent (mf, "MERCHANT_SHOW")
ok (mf:IsShown () == true, "MERCHANT_SHOW arms the settle timer (frame shown)")
mf._scripts.OnUpdate (mf, 1.0)   -- > 0.3s quiet -> DoMerchantScan
ok (gMerchantInfoCalls > 0, "first open walks the merchant list")
ok (Atr_GetNPCPrice (111) == 100, "first open learned the vendor's trade good")
ok (mf:IsShown () == false, "settle timer stops itself after the scan")

-- open #2: same vendor, same list -> the session throttle must skip the walk
gMerchantInfoCalls = 0
mf._scripts.OnEvent (mf, "MERCHANT_SHOW")
mf._scripts.OnUpdate (mf, 1.0)
ok (gMerchantInfoCalls == 0, "second open of the same vendor does NOT re-walk the list")

-- a genuinely different list (a new vendor / gossip branch) is still scanned
gMerchantInfoCalls = 0
gMerchant = {
  { link = "item:555", price = 30, qty = 1, avail = -1, ext = nil, itype = "Trade Goods" },
}
mf._scripts.OnEvent (mf, "MERCHANT_SHOW")
mf._scripts.OnUpdate (mf, 1.0)
ok (gMerchantInfoCalls > 0, "a different merchant list is walked (new fingerprint)")
ok (Atr_GetNPCPrice (555) == 30, "the new vendor's item was learned")

-- MERCHANT_CLOSED disarms the timer
mf._scripts.OnEvent (mf, "MERCHANT_CLOSED")
ok (mf:IsShown () == false, "MERCHANT_CLOSED disarms the settle timer")

print ("\nALL SCAN THROTTLE TESTS PASSED (" .. pass .. " checks)")
