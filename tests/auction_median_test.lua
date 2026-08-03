-- Regression tests for the "Auction median" tooltip sample.
--
-- The median line reads from gAtr_MeanDB, a rolling set of up-to-15 per-scan
-- samples.  Each scan used to contribute only its single LOWEST per-unit price
-- -- the same figure the "Auction" line shows -- so for a commodity whose low
-- barely moves, every sample was that one low value and the median sat ON the
-- lowest price, never reflecting the rest of the book.
--
-- The fix feeds the quantity-weighted median of the scan's CURRENT listings as
-- the sample instead.  These tests cover the two functions that produce it:
--   * Atr_WeightedMedianPrice  -- weighted median over {price, weight} entries
--   * Atr_ScanListingsMedian   -- builds those entries from an AtrScan, skipping
--                                 synthetic seed rows
--
-- Run:  lua5.1 tests/auction_median_test.lua   (from the repo root)

local pass = 0
local function ok (cond, msg)
  assert (cond, "FAIL: " .. msg)
  pass = pass + 1
  print (string.format ("PASS %d  %s", pass, msg))
end
local function eq (got, want, msg)
  ok (got == want, string.format ("%s  (got %s, want %s)", msg, tostring (got), tostring (want)))
end

-- ---- minimal WoW surface AuctionatorScan.lua needs at load time ------------

tinsert = table.insert
tremove = table.remove

local chunk = assert (loadfile ("Auctionator-Finder-Ascension/AuctionatorScan.lua"))
assert (pcall (chunk, "Auctionator-Finder-Ascension", {}))

ok (type (Atr_WeightedMedianPrice) == "function", "scan exports Atr_WeightedMedianPrice")
ok (type (Atr_ScanListingsMedian)  == "function", "scan exports Atr_ScanListingsMedian")

-- ---- Atr_WeightedMedianPrice ------------------------------------------------

eq (Atr_WeightedMedianPrice (nil),  0, "nil entries -> 0")
eq (Atr_WeightedMedianPrice ({}),   0, "empty entries -> 0")
eq (Atr_WeightedMedianPrice ({ { price = 42, weight = 1 } }), 42, "single listing -> its price")

-- classic odd-count median, all weights 1
eq (Atr_WeightedMedianPrice ({
      { price = 30, weight = 1 }, { price = 10, weight = 1 }, { price = 20, weight = 1 },
    }), 20, "odd count, equal weights -> middle value (order independent)")

-- classic even-count median averages the two straddling values
eq (Atr_WeightedMedianPrice ({
      { price = 10, weight = 1 }, { price = 20, weight = 1 },
    }), 15, "even count, equal weights -> average of the two middles")

-- the point of the change: a wall of stock outvotes a lone lowball stack.
-- lowest unit price is 10, but ~190 items sit at 16 -> median tracks the wall.
eq (Atr_WeightedMedianPrice ({
      { price = 10, weight = 3 },   -- one cheap stack of 3
      { price = 15, weight = 1 },   -- one lone unit
      { price = 16, weight = 190 }, -- 19 stacks of 10
    }), 16, "quantity weighting lifts the median off the lowest price")

-- one-vote-per-row would have returned 15 here; weighting is what makes it 16
ok (Atr_WeightedMedianPrice ({
      { price = 10, weight = 3 }, { price = 15, weight = 1 }, { price = 16, weight = 190 },
    }) ~= 15, "weighted result differs from the unweighted (per-row) median")

-- fractional per-unit prices are floored, like the rest of the price DB
eq (Atr_WeightedMedianPrice ({ { price = 10.5, weight = 1 } }), 10, "fractional price is floored")

-- ---- Atr_ScanListingsMedian -------------------------------------------------

eq (Atr_ScanListingsMedian (nil), nil, "nil scan -> nil")
eq (Atr_ScanListingsMedian ({}),  nil, "scan without scanData -> nil")

-- a book shaped like the Forestwood Log screenshot: a couple of cheap singles
-- and a wall of stock a bit higher.  buyoutPrice is for the whole stack, so the
-- per-unit price is buyoutPrice/stackSize.
local scn = { scanData = {} }
tinsert (scn.scanData, { stackSize = 3,  buyoutPrice = 30,  owner = "Alice" })   -- unit 10, w3
tinsert (scn.scanData, { stackSize = 1,  buyoutPrice = 15,  owner = "Bob"   })   -- unit 15, w1
local k
for k = 1, 19 do
  tinsert (scn.scanData, { stackSize = 10, buyoutPrice = 160, owner = "Carol" }) -- unit 16, w10
end
eq (Atr_ScanListingsMedian (scn), 16, "listings median tracks the wall of stock, not the 10 low")

-- synthetic seed rows (__wowEcon*/__wowHead/__allakhazam/__atrLast) are skipped
-- so the median rests on the live market, matching the Auction line's basis.
local seeded = { scanData = {
  { stackSize = 1, buyoutPrice = 20, owner = "Alice" },
  { stackSize = 1, buyoutPrice = 22, owner = "Bob"   },
  { stackSize = 1, buyoutPrice = 24, owner = "Carol" },
  { stackSize = 1, buyoutPrice = 1,  owner = "__wowEconG" },  -- cheap seed, must be ignored
  { stackSize = 1, buyoutPrice = 2,  owner = "__wowHead"  },  -- cheap seed, must be ignored
} }
eq (Atr_ScanListingsMedian (seeded), 22,
    "synthetic seed rows are excluded (else the cheap seeds would drag it to 20)")

-- a book that is nothing but synthetic seeds yields no usable sample
local allseed = { scanData = {
  { stackSize = 1, buyoutPrice = 5, owner = "__wowEconS" },
  { stackSize = 1, buyoutPrice = 7, owner = "__allakhazam" },
} }
eq (Atr_ScanListingsMedian (allseed), nil, "all-synthetic book -> nil (caller falls back to lowest)")

-- listings with no buyout (auction-only) contribute nothing
local nobuyout = { scanData = {
  { stackSize = 1, buyoutPrice = 0,   owner = "Alice" },
  { stackSize = 2, buyoutPrice = 100, owner = "Bob"  },   -- unit 50
} }
eq (Atr_ScanListingsMedian (nobuyout), 50, "zero-buyout listings are ignored")

print ("\nALL AUCTION MEDIAN TESTS PASSED (" .. pass .. " checks)")
