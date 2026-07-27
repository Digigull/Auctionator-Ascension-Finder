-- Focused regression test for the level-band relevance change in the research
-- ledger.  Loads the REAL AuctionatorFinder.lua in a minimal mock env and calls
-- the real Fdr_Research_Targets / the real /atrtarget handler.

-- ---- minimal WoW-ish stubs the ledger path touches ----
tinsert = table.insert
tremove = table.remove
function wipe (t) for k in pairs (t) do t[k] = nil end return t end

local out_lines = {}
DEFAULT_CHAT_FRAME = { AddMessage = function (self, s) out_lines[#out_lines+1] = s end }

local TESTLEVEL = 52
function UnitLevel (unit) return TESTLEVEL end

SlashCmdList = {}          -- so the real slash block registers its handler
zc = false                 -- keep it falsy so messages fall through to DEFAULT_CHAT_FRAME

-- A chainable dummy for the frame/UI APIs the addon calls at load (CreateFrame,
-- widget methods, etc.).  It is callable and indexable and always returns
-- itself, so any construction/chaining at file scope succeeds harmlessly.
local DUMMY
DUMMY = setmetatable ({}, {
  __index = function () return DUMMY end,
  __call  = function () return DUMMY end,
})
-- Any global the file references but we did not set resolves to DUMMY.  The
-- ledger path we actually test reads only real globals (UnitLevel, the tables
-- below, tinsert, string/math/table) plus zc, which we pinned falsy above.
setmetatable (_G, { __index = function (_, k) return DUMMY end })

-- ---- load the addon file ----
local path = arg[1] or "Auctionator-Finder-Ascension/AuctionatorFinder.lua"
local chunk, err = loadfile (path)
assert (chunk, "loadfile failed: "..tostring (err))
local ok, lerr = pcall (chunk)
assert (ok, "load-time error: "..tostring (lerr))

-- ---- build a synthetic ledger ----
-- item A: cheap LOW-level complete ladder (like 4661) - dominates the old score
-- item B: a mid-cost IN-BAND item near the player's level 52
-- item C: an expensive far-above item
AUCTIONATOR_VENDOR_LEARNED = { obs = {} }   -- no confirmed rungs anywhere
AUCTIONATOR_FINDER_RESEARCH = {
  scans = 5,
  items = {
    [4661] = { n = "Cheap Low Ladder", brq = 21, sc = 3, seen = 9,
               v = { [17]={b=200,il=19}, [22]={b=300,il=22}, [30]={b=400,il=27},
                     [36]={b=500,il=36}, [41]={b=600,il=41} } },
    [9001] = { n = "In-Band Chest",   brq = 50, sc = 3, seen = 6,
               v = { [50]={b=90000,il=54}, [52]={b=95000,il=56} } },
    [9002] = { n = "Far-Above Relic", brq = 73, sc = 2, seen = 4,
               v = { [75]={b=500000,il=79}, [77]={b=520000,il=81} } },
  },
}

local function rank (anchor)
  return Fdr_Research_Targets (10, anchor)
end
local function posOf (t, id)
  for i=1,#t do if t[i].id == id then return i end end
  return nil
end

-- 1) WITHOUT an anchor (offline dump semantics) the cheap low ladder wins - old behaviour intact
local t0 = rank (nil)
assert (posOf (t0, 4661) == 1, "no-anchor: cheap low ladder should rank #1, got "..tostring(posOf(t0,4661)))
for i=1,#t0 do assert (t0[i].relevance == 1, "no-anchor: relevance must be 1") end
print ("PASS 1  no-anchor ranking unchanged (cheap low ladder #1)")

-- 2) WITH anchor=52 the in-band chest is pulled ABOVE the cheap low ladder
local t1 = rank (52)
local pB, pA = posOf (t1, 9001), posOf (t1, 4661)
assert (pB < pA, "anchor52: in-band chest ("..pB..") should outrank low ladder ("..pA..")")
print (string.format ("PASS 2  anchor 52: in-band chest #%d now above low ladder #%d", pB, pA))

-- 3) relevance values behave: in-band == 1.0, far-above at the floor, low ladder demoted
local byId = {}; for i=1,#t1 do byId[t1[i].id] = t1[i] end
assert (math.abs (byId[9001].relevance - 1.0) < 1e-9, "in-band relevance should be 1.0, got "..byId[9001].relevance)
assert (byId[9002].relevance <= 0.25 + 1e-9, "far-above should be at floor, got "..byId[9002].relevance)
assert (byId[4661].relevance < 1.0, "low ladder should be demoted, got "..byId[4661].relevance)
print (string.format ("PASS 3  relevance in-band=%.2f  lowLadder=%.2f  farAbove=%.2f",
        byId[9001].relevance, byId[4661].relevance, byId[9002].relevance))

-- 4) a max-level anchor still prefers high gear; the far-above (70+) comes in-band
local t2 = rank (72)
assert (posOf (t2, 9002) < posOf (t2, 4661), "anchor72: far-above should now outrank low ladder")
print ("PASS 4  max-level anchor pulls high gear in-band")

-- 5) the REAL /atrtarget handler: default uses UnitLevel (52) => in-band chest beats low ladder in output
out_lines = {}
SlashCmdList["ATRRESEARCHTARGET"]("")
local joined = table.concat (out_lines, "\n")
assert (joined:find ("prioritising gear near level 52"), "default handler should anchor on UnitLevel 52")
local iChest = joined:find ("In%-Band Chest")
local iLow   = joined:find ("Cheap Low Ladder")
assert (iChest and iLow, "both items should be listed in output")
assert (iChest < iLow, "default handler: in-band chest should print before low ladder")
print ("PASS 5  /atrtarget default anchors on character level")

-- 6) the REAL /atrtarget handler with an override band: "/atrtarget 10 20"
out_lines = {}
SlashCmdList["ATRRESEARCHTARGET"]("10 20")
joined = table.concat (out_lines, "\n")
assert (joined:find ("prioritising gear near level 20"), "override handler should anchor on 20")
local jLow   = joined:find ("Cheap Low Ladder")
local jChest = joined:find ("In%-Band Chest")
assert (jLow < jChest, "override 20: low ladder should now print before in-band chest")
print ("PASS 6  /atrtarget <n> <level> override retargets the band")

print ("\nALL LEDGER RELEVANCE TESTS PASSED")
