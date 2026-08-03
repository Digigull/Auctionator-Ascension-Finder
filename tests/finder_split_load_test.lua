-- Load-order regression test for the AuctionatorFinder.lua file split.
--
-- WoW addons share NOTHING between files except globals and the addon table
-- (the second vararg).  When a chunk of Finder is peeled off into its own
-- .lua, the pieces talk through addonTable.Finder, and the .toc must load the
-- publisher (AuctionatorFinder.lua) BEFORE the consumers.  This test mimics
-- that load order with one shared addon table and asserts the wiring holds,
-- so a bad split or a wrong .toc order fails here instead of in-game.
--
-- Run:  lua5.1 tests/finder_split_load_test.lua
-- (paths are relative to the repo root, like the other tests here.)

tinsert = table.insert
tremove = table.remove
function wipe (t) for k in pairs (t) do t[k] = nil end return t end

SlashCmdList = {}
DEFAULT_CHAT_FRAME = { AddMessage = function () end }
zc = false
function UnitLevel () return 40 end

-- A chainable dummy so the UI/frame calls the files make at load succeed.
-- It only backstops genuinely-unrelated globals; the cross-file symbols this
-- test cares about are asserted to be real functions below.
local DUMMY
DUMMY = setmetatable ({}, {
  __index = function () return DUMMY end,
  __call  = function () return DUMMY end,
})
setmetatable (_G, { __index = function (_, k) return DUMMY end })

-- The one shared addon table both files receive as their second vararg,
-- exactly as the WoW client passes it.
local addonTable = {}

local function load_addon_file (path)
  local chunk, err = loadfile (path)
  assert (chunk, "loadfile failed: " .. path .. ": " .. tostring (err))
  local ok, lerr = pcall (chunk, "Auctionator-Finder-Ascension", addonTable)
  assert (ok, "load-time error in " .. path .. ": " .. tostring (lerr))
end

local pass = 0
local function ok (cond, msg)
  assert (cond, "FAIL: " .. msg)
  pass = pass + 1
  print (string.format ("PASS %d  %s", pass, msg))
end

-- ---- load in .toc order: publisher first, then the split-out consumer ----
load_addon_file ("Auctionator-Finder-Ascension/AuctionatorFinder.lua")

ok (type (addonTable.Finder) == "table",           "main file publishes addonTable.Finder")
ok (type (addonTable.Finder.MoneyString) == "function", "Finder surface exports MoneyString")
ok (type (addonTable.Finder.GetResults) == "function",  "Finder surface exports GetResults")
ok (type (addonTable.Finder.GetCapHit) == "function",   "Finder surface exports GetCapHit")

load_addon_file ("Auctionator-Finder-Ascension/AuctionatorFinderPriceDB.lua")

ok (type (Fdr_PriceDB_Enabled) == "function", "split file defines Fdr_PriceDB_Enabled")
ok (type (Fdr_PriceDB_Update)  == "function", "split file defines Fdr_PriceDB_Update")
ok (type (Fdr_PriceDB_Inspect) == "function", "split file defines Fdr_PriceDB_Inspect")

-- Cross-file call: the split file's MoneyString capture must reach the main
-- file's real formatter and return a formatted string.
local money = addonTable.Finder.MoneyString (12345)
ok (type (money) == "string" and #money > 0, "cross-file MoneyString formats copper")

-- Default-on behaviour reads a SavedVariable through the split file.
AUCTIONATOR_FINDER_SETTINGS = nil
ok (Fdr_PriceDB_Enabled () == true, "Fdr_PriceDB_Enabled defaults on via split file")

-- The /atrprices inspector must register from the split file.
ok (type (SlashCmdList["ATRPRICEFEED"]) == "function", "/atrprices registers from split file")

-- ---- full scan replacement split ----
load_addon_file ("Auctionator-Finder-Ascension/AuctionatorFinderFullScan.lua")

ok (type (Fdr_FS_Running) == "function", "full-scan split defines Fdr_FS_Running")
ok (type (Atr_FullScanStart) == "function", "full-scan split defines Atr_FullScanStart")

print ("\nALL FINDER SPLIT LOAD TESTS PASSED (" .. pass .. " checks)")
