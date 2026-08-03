-- Regression tests for the "Sort by Profit" ranking on the profession window.
--
-- Covers the pure maths that decides the order (AuctionatorFinderProfession.lua):
--   * Atr_ProfSort_RowProfit   -- per-item profit = sell price - reagent cost/yield
--   * Atr_ProfSort_BuildOrder  -- ranked list of real skill indices, unpriceable last
--
-- The button reorder itself is UI (a live TradeSkillFrame) and is not exercised
-- here; these tests pin the decision logic, which is where a bug would silently
-- rank the wrong recipe first.
--
-- Run:  lua5.1 tests/profit_sort_test.lua   (from the repo root)

local pass = 0
local function ok (cond, msg)
  assert (cond, "FAIL: " .. msg)
  pass = pass + 1
  print (string.format ("PASS %d  %s", pass, msg))
end

-- ---- mock WoW surface ------------------------------------------------------

-- The profession file creates frames + registers events at load; give it a
-- minimal CreateFrame so loading succeeds.  No event is ever fired here, so the
-- checkbox is never built and TradeSkillFrame can stay nil.
function CreateFrame ()
  local fr = {}
  function fr:RegisterEvent () end
  function fr:UnregisterEvent () end
  function fr:SetScript () end
  function fr:GetScript () end
  function fr:Show () end
  function fr:Hide () end
  function fr:IsShown () return false end
  return fr
end
DEFAULT_CHAT_FRAME = { AddMessage = function () end }

-- itemID from a link like "item:1234"
zc = { ItemIDfromLink = function (link) return tonumber (tostring (link):match ("item:(%d+)")) end }

-- ---- mock trade skill + prices ---------------------------------------------

-- Each row: { header=bool, name=, made=, reagents={ {name=,link=,count=}, ... } }
local gSkills = {}

function GetTradeSkillLine () return "Alchemy" end
function GetNumTradeSkills () return #gSkills end
function GetTradeSkillInfo (i)
  local r = gSkills[i]; if not r then return end
  -- name, skillType, numAvailable
  return r.name or ("row"..i), r.header and "header" or "optimal", r.avail or 0
end
function GetTradeSkillNumMade (i) local r = gSkills[i]; return r and r.made or 1 end
function GetTradeSkillNumReagents (i) local r = gSkills[i]; return r and r.reagents and #r.reagents or 0 end
function GetTradeSkillReagentInfo (i, j)
  local r = gSkills[i]; local g = r and r.reagents and r.reagents[j]
  if not g then return end
  return g.name, nil, g.count   -- reagentName, texture, count
end
function GetTradeSkillReagentItemLink (i, j)
  local r = gSkills[i]; local g = r and r.reagents and r.reagents[j]
  return g and g.link or nil
end

-- price tables keyed the way the real getters are keyed
local gAuction = {}   -- name -> copper (produced items AND reagents)
local gNPC     = {}   -- itemID -> copper
local gSell    = {}   -- id or name -> copper (vendor sell floor)

function Atr_GetAuctionPrice (name) return gAuction[name] end
function Atr_GetNPCPrice (id)       return gNPC[id] end
function Atr_GetSellValue (key)     return gSell[key] end

-- ---- load the file under test ----------------------------------------------

local addonTable = {}
local function load_addon_file (path)
  local chunk, err = loadfile (path)
  assert (chunk, "loadfile failed: " .. path .. ": " .. tostring (err))
  local okc, lerr = pcall (chunk, "Auctionator-Finder-Ascension", addonTable)
  assert (okc, "load-time error in " .. path .. ": " .. tostring (lerr))
end

load_addon_file ("Auctionator-Finder-Ascension/AuctionatorFinderProfession.lua")

ok (type (Atr_ProfSort_RowProfit) == "function",  "exports Atr_ProfSort_RowProfit")
ok (type (Atr_ProfSort_BuildOrder) == "function", "exports Atr_ProfSort_BuildOrder")

-- ---- per-recipe profit maths -----------------------------------------------

-- Recipe: 1x "Herb" (auction 100) -> 1x "Potion" that sells for 300 => profit 200
gSkills = {
  { name = "Potion", made = 1, reagents = { { name = "Herb", link = "item:10", count = 1 } } },
}
gAuction = { ["Potion"] = 300, ["Herb"] = 100 }
gNPC, gSell = {}, {}
local profit, cost, sell = Atr_ProfSort_RowProfit (1)
ok (cost == 100, "reagent cost totals the auction price of the reagent")
ok (sell == 300, "sell is the produced item's auction price")
ok (profit == 200, "profit = sell - cost")

-- Yield divides the cost: 4x "Herb" (100 each = 400) making 2 => cost 200/item,
-- sell 300 => profit 100.
gSkills = {
  { name = "Potion", made = 2, reagents = { { name = "Herb", link = "item:10", count = 4 } } },
}
profit, cost = Atr_ProfSort_RowProfit (1)
ok (cost == 200 and profit == 100, "yield divides reagent cost per item")

-- Reagent price cascade: NPC price wins over auction; vendor-sell is the floor.
gSkills = {
  { name = "Potion", made = 1, reagents = {
      { name = "Vial",  link = "item:20", count = 1 },   -- NPC-priced
      { name = "Root",  link = "item:21", count = 1 },   -- auction-priced
      { name = "Scrap", link = "item:22", count = 1 },   -- vendor-sell floor only
  } },
}
gAuction = { ["Potion"] = 1000, ["Vial"] = 999, ["Root"] = 50 }  -- Vial auction is a trap; NPC must win
gNPC     = { [20] = 5 }
gSell    = { [22] = 8 }
profit, cost = Atr_ProfSort_RowProfit (1)
ok (cost == 5 + 50 + 8, "cascade: NPC over auction, then auction, then vendor-sell floor")
ok (profit == 1000 - 63, "profit uses the cascaded reagent cost")

-- Unpriceable cases return nil (never a wrong number).
gSkills = { { name = "Potion", made = 1, reagents = { { name = "Herb", link = "item:10", count = 1 } } } }
gAuction, gNPC, gSell = { ["Potion"] = 300 }, {}, {}   -- reagent has no price anywhere
ok (Atr_ProfSort_RowProfit (1) == nil, "an unpriceable reagent makes profit nil")

gAuction, gNPC, gSell = { ["Herb"] = 100 }, {}, {}     -- produced item has no auction price
ok (Atr_ProfSort_RowProfit (1) == nil, "an unpriced produced item makes profit nil")

-- A header row is never a recipe.
gSkills = { { header = true, name = "Elixir" } }
ok (Atr_ProfSort_RowProfit (1) == nil, "a header row has no profit")

-- ---- ranked order ----------------------------------------------------------

-- A header + four recipes with mixed profitability, plus one unpriceable.
gSkills = {
  { header = true, name = "Elixir" },
  { name = "Cheap",  made = 1, reagents = { { name = "H", link = "item:1", count = 1 } } }, -- 120-100 = 20
  { name = "Rich",   made = 1, reagents = { { name = "H", link = "item:1", count = 1 } } }, -- 500-100 = 400
  { name = "Loss",   made = 1, reagents = { { name = "H", link = "item:1", count = 1 } } }, -- 40-100  = -60
  { name = "Blind",  made = 1, reagents = { { name = "X", link = "item:9", count = 1 } } }, -- reagent X unpriceable
}
gAuction = { ["Cheap"] = 120, ["Rich"] = 500, ["Loss"] = 40, ["Blind"] = 999, ["H"] = 100 }
gNPC, gSell = {}, {}

local order, profByIdx = Atr_ProfSort_BuildOrder ()
ok (#order == 4, "header is dropped; four recipe rows ranked")
ok (order[1] == 3, "most profitable recipe (Rich) ranks first")
ok (order[2] == 2, "next (Cheap) second")
ok (order[3] == 4, "loss-making (Loss) ranks below break-even but above unpriceable")
ok (order[4] == 5, "unpriceable recipe (Blind) sinks to the very bottom")
ok (profByIdx[3] == 400 and profByIdx[4] == -60, "profit map carries the per-recipe figures")
ok (profByIdx[5] == nil, "unpriceable recipe has no profit in the map")

-- Stable order among equal / unpriceable rows: two unpriceable rows keep list order.
gSkills = {
  { name = "A", made = 1, reagents = { { name = "X", link = "item:9", count = 1 } } },
  { name = "B", made = 1, reagents = { { name = "Y", link = "item:8", count = 1 } } },
}
gAuction = { ["A"] = 100, ["B"] = 100 }   -- both produced items priced, but reagents X/Y are not
order = Atr_ProfSort_BuildOrder ()
ok (order[1] == 1 and order[2] == 2, "two unpriceable rows keep their original order (stable)")

print ("\nALL PROFIT SORT TESTS PASSED (" .. pass .. " checks)")
