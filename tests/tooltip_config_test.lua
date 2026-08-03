-- Tests for the configurable tooltip behaviour added to AuctionatorHints.lua:
--   * Atr_TipsHighlightCode  - the configurable best-price highlight colour
--   * Atr_TipLabel           - wraps a label in that colour only when it wins
--   * Atr_TipBestPrice       - which figure (if any) is the best, tie handling
--   * the Auction / Auction-median tie rule (only Auction keeps the highlight)
--
-- These are the pure building blocks the in-game tooltip draws with, so a
-- regression in the colour config or the tie logic fails here instead of only
-- being visible in the client.
--
-- Run:  lua5.1 tests/tooltip_config_test.lua
-- (path relative to the repo root, like the other tests here.)

-- A chainable dummy so the load-time UI/hook calls in AuctionatorHints succeed.
local DUMMY
DUMMY = setmetatable ({}, {
  __index = function () return DUMMY end,
  __call  = function () return DUMMY end,
})
setmetatable (_G, { __index = function (_, k) return DUMMY end })

-- Minimal zc surface the file captures from the addon table at load.
local addonTable = { zc = {
  priceToMoneyString = function (v) return tostring (v) .. "c" end,
  StringStartsWith   = function () return false end,
  md                 = function () end,
} }

local chunk, err = loadfile ("Auctionator-Finder-Ascension/AuctionatorHints.lua")
assert (chunk, "loadfile failed: " .. tostring (err))
assert (pcall (chunk, "Auctionator-Finder-Ascension", addonTable))

local pass = 0
local function ok (cond, msg)
  assert (cond, "FAIL: " .. msg)
  pass = pass + 1
  print (string.format ("PASS %d  %s", pass, msg))
end

-- ---- Atr_TipsHighlightCode: configurable colour, safe fallbacks ----

AUCTIONATOR_TIPS_HL_COLOR = nil
ok (Atr_TipsHighlightCode () == "|cFF3399FF", "highlight colour defaults to blue when unset")

AUCTIONATOR_TIPS_HL_COLOR = "not a colour"
ok (Atr_TipsHighlightCode () == "|cFF3399FF", "malformed hex falls back to blue")

AUCTIONATOR_TIPS_HL_COLOR = "FF0000"
ok (Atr_TipsHighlightCode () == "|cFFFF0000", "a valid hex is honoured")

AUCTIONATOR_TIPS_HL_COLOR = "00ff00"
ok (Atr_TipsHighlightCode () == "|cFF00ff00", "lower-case hex is accepted")

-- ---- Atr_TipLabel: wraps only the winner, in the configured colour ----

AUCTIONATOR_TIPS_HL_COLOR = "3399FF"
ok (Atr_TipLabel ("Auction", 100, 100) == "|cFF3399FFAuction|r", "the best line is wrapped in the highlight colour")
ok (Atr_TipLabel ("Auction", 80, 100)  == "Auction",             "a non-best line is left untouched")
ok (Atr_TipLabel ("Auction", 100, nil) == "Auction",             "nothing to compare (best==nil) leaves the label plain")

AUCTIONATOR_TIPS_HL_COLOR = "FF8800"
ok (Atr_TipLabel ("Vendor", 5, 5) == "|cFFFF8800Vendor|r", "the winner uses whatever colour is configured")

-- ---- Atr_TipBestPrice: best figure, tie handling, too-few rule ----

ok (Atr_TipBestPrice (10, 20, 30, 40) == 40, "returns the largest competitor")
ok (Atr_TipBestPrice (nil, 20, 20, nil) == 20, "a tie still reports the shared top figure")
ok (Atr_TipBestPrice (50, nil, nil, nil) == nil, "a lone figure has nothing to beat -> nil")
ok (Atr_TipBestPrice (0, 0, 0, 0) == nil, "zeros do not count as competitors -> nil")
ok (Atr_TipBestPrice (nil, 0, 15, 0) == nil, "one real figure among zeros still has no rival -> nil")

-- ---- Auction / Auction-median tie rule ----
-- The draw code computes medianBest = bestPrice, then blanks it when the median
-- ties the auction line so only Auction keeps the highlight.  Reproduce that
-- rule and assert Atr_TipLabel paints exactly one of the two lines.

local function tie_labels (auctionShown, medianShown)
  local best = Atr_TipBestPrice (nil, auctionShown, medianShown, nil)
  local medianBest = best
  if (medianShown and auctionShown and medianShown == auctionShown) then
    medianBest = nil
  end
  local a = Atr_TipLabel ("Auction",        auctionShown, best)
  local m = Atr_TipLabel ("Auction median", medianShown,  medianBest)
  return a, m
end

local hl = "|cFF3399FF"
AUCTIONATOR_TIPS_HL_COLOR = "3399FF"

local a, m = tie_labels (100, 100)
ok (a == hl .. "Auction|r", "on an Auction==median tie, Auction keeps the highlight")
ok (m == "Auction median",  "on an Auction==median tie, the median line is NOT highlighted")

a, m = tie_labels (100, 150)
ok (a == "Auction",              "when the median is strictly higher, Auction is not the best")
ok (m == hl .. "Auction median|r", "when the median is strictly higher, only the median is highlighted")

a, m = tie_labels (150, 100)
ok (a == hl .. "Auction|r", "when Auction is strictly higher, only Auction is highlighted")
ok (m == "Auction median",  "when Auction is strictly higher, the median is not highlighted")

print ("\nALL TOOLTIP CONFIG TESTS PASSED (" .. pass .. " checks)")
