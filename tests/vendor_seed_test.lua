-- Vendor seed regression test (VENDOR-SEED-PLAN.md, Old Docs/).
--
-- Like harness10/harness11 this test EXTRACTS the shipped code verbatim
-- rather than reimplementing it: it slices the two FINDER_TAB blocks
-- (scaling detector + vendor price learning) out of AuctionatorHints.lua and
-- loads them, so the assertions can never drift from what ships.  A mock WoW
-- API drives the two entry points the seed touches -- the PLAYER_LOGIN merge
-- and a confirmed merchant sale -- and inspects the SavedVariable directly.
--
-- Covers the plan's four verification points:
--   * idempotent seed          (merge twice -> identical; n==0, seed==1)
--   * real-wins                (a real obs is never overwritten by the seed)
--   * version refresh          (bumping meta.built refreshes a seed-only price,
--                               leaves real entries untouched)
--   * pt=="seed" classification (first real sale of a seed-only tuple logs
--                               pt=="seed" with the shipped price as smp.pp and
--                               promotes the record; a second sale logs learned)
--
-- Run:  lua5.1 tests/vendor_seed_test.lua      (path relative to repo root)

local HINTS = "Auctionator-Finder-Ascension/AuctionatorHints.lua"

local pass = 0
local function ok (cond, msg)
	assert (cond, "FAIL: " .. msg)
	pass = pass + 1
	print (string.format ("PASS %d  %s", pass, msg))
end

-- ---------------------------------------------------------------- mock WoW --
-- The captured OnEvent handler of gVendorLearnFrame and the captured
-- UseContainerItem post-hook (the sell capture) are the two levers the test
-- pulls; everything else is a stub shaped to match the real API's returns.
local captured = { onEvent = nil, sell = nil }

UIParent = {}
SlashCmdList = {}
MerchantFrame = { IsShown = function () return true end }

function GetTime () return 1000 end
function CursorHasItem () return false end
function hooksecurefunc (name, fn)
	if (name == "UseContainerItem") then captured.sell = fn; end
end

-- one scaled variant: cache says base il1/rq1, the server tooltip says il40/rq35.
local SELL_LINK = "|cff0070dd|Hitem:777:0:0:0:0:0:0:0:0|h[Test Sword]|h|r"
function GetContainerItemLink () return SELL_LINK end
function GetContainerItemInfo () return nil, 1 end               -- texture, count
-- name, link, quality, iLevel, reqLevel, class, subclass, maxStack, equipSlot, texture, vendorPrice
function GetItemInfo () return "Test Sword", SELL_LINK, 2, 1, 1, "Weapon", "Sword", 1, "INVTYPE_WEAPON", nil, 50; end

-- buyback confirmation: newest slot is the scaled sword, sold for 50c x1.
function GetNumBuybackItems () return 1 end
function GetBuybackItemInfo () return "Test Sword", nil, 50, 1; end   -- name, texture, price, qty

zc = {
	msg_atr = function () end,
	priceToMoneyString = function (c) return tostring (c) .. "c" end,
	ItemIDfromLink = function () return 777, 0, 0; end,             -- id, suffix, unique
}

-- The scan tooltips (bag + buyback) both read the same named GameTooltip; make
-- Atr_TipScaleMismatch parse il40/rq35 out of its TextLeft lines.
_G["AtrVendorScanTipTextLeft2"] = { GetText = function () return "Item Level 40" end }
_G["AtrVendorScanTipTextLeft3"] = { GetText = function () return "Requires Level 35" end }

function CreateFrame (kind, name, parent, template)
	local f = { _name = name }
	function f:GetName ()   return self._name end
	function f:NumLines ()  return 3 end
	function f:RegisterEvent () end
	function f:SetScript (which, handler)
		if (which == "OnEvent") then captured.onEvent = handler; end
	end
	-- tooltip surface (only the scan tips use these)
	function f:SetOwner () end
	function f:ClearLines () end
	function f:SetBagItem () end
	function f:SetBuybackItem () end
	function f:Hide () end
	function f:IsShown () return false end
	return f
end

-- ---------------------------------------------------------- load the code --
local function extract_finder_blocks ()
	local fh = assert (io.open (HINTS, "r"))
	local src = fh:read ("*a"); fh:close ()
	local b = src:find ("%-%- FINDER_TAB begin: Ascension per%-instance scaling detector")
	local e = src:find ("%-%- FINDER_TAB end: vendor price learning")
	assert (b and e, "FINDER_TAB markers not found in " .. HINTS)
	local eol = src:find ("\n", e) or (#src + 1)
	return src:sub (b, eol)
end

local chunk, err = loadstring (extract_finder_blocks (), "finderblocks")
assert (chunk, "load failed: " .. tostring (err))
chunk ()
ok (type (captured.onEvent) == "function", "vendor block wired an OnEvent handler")
ok (type (captured.sell) == "function",    "vendor block hooked UseContainerItem")

local function login () captured.onEvent ({}, "PLAYER_LOGIN") end
local function sell ()  captured.sell (0, 1, nil); captured.onEvent ({}, "MERCHANT_UPDATE"); end

-- ------------------------------------------------------------- test: merge --
AUCTIONATOR_VENDOR_LEARNED = nil
ATR_VENDOR_SEED = {
	meta = { built = "2026-08-03", nobs = 1, nbase = 0, src = "test" },
	obs  = { ["777:40:35"] = 44 },
	base = {},
}

login ()
local db = AUCTIONATOR_VENDOR_LEARNED
local seeded = db.obs["777:40:35"]
ok (seeded and seeded.p == 44 and seeded.n == 0 and seeded.seed == 1,
	"fresh seed installs as { p=44, n=0, seed=1 }")
ok (db.seedver == "2026-08-03", "seed version stamped onto the DB")

-- idempotent: a second login changes nothing
login ()
seeded = db.obs["777:40:35"]
ok (seeded.p == 44 and seeded.n == 0 and seeded.seed == 1,
	"idempotent: second login leaves the seed-only entry identical")

-- ---------------------------------------------------------- test: real-wins --
-- A real observation (seed flag absent) with the SAME key at a DIFFERENT price
-- must survive the merge untouched.
db.obs["888:10:5"] = { p = 999, n = 3 }             -- a real, player-observed sale
ATR_VENDOR_SEED.obs["888:10:5"] = 111               -- seed disagrees
login ()
local real = db.obs["888:10:5"]
ok (real.p == 999 and real.n == 3 and real.seed == nil,
	"real-wins: a real obs is never overwritten or flagged by the merge")

-- ------------------------------------------------------ test: version refresh --
-- Bump the shipped price AND the version: the seed-only entry refreshes, the
-- real entry stays put.
ATR_VENDOR_SEED.obs["777:40:35"] = 48
ATR_VENDOR_SEED.meta.built = "2026-09-01"
login ()
seeded = db.obs["777:40:35"]
ok (seeded.p == 48 and seeded.n == 0 and seeded.seed == 1,
	"version bump refreshes the seed-only price to 48")
ok (db.obs["888:10:5"].p == 999,
	"version bump leaves the real entry untouched")
ok (db.seedver == "2026-09-01", "seed version advanced after refresh")

-- Same version again must NOT refresh (guards against re-writes every login).
ATR_VENDOR_SEED.obs["777:40:35"] = 60               -- would change it IF version-gating were broken
login ()
ok (db.obs["777:40:35"].p == 48,
	"no refresh without a version bump (prev == ver short-circuits)")

-- ---------------------------------------------------- test: pt=="seed" sale --
-- Sell the seed-only tuple (777:40:35, seeded at 48) for a real 50c.
AUCTIONATOR_SALE_MSG = 0                             -- silence the chat announce
sell ()
local s1 = db.log[#db.log]
ok (s1 and s1.pt == "seed",  "first sale of a seed-only tuple classifies pt==seed")
ok (s1.pp == 48,             "smp.pp holds the shipped seed price (48) -> field accuracy is |p-pp|/p")
ok (s1.p == 50,              "smp.p holds the real sale price (50)")

local promoted = db.obs["777:40:35"]
ok (promoted.p == 50 and promoted.n == 1 and promoted.seed == nil,
	"the sale promotes the record: seed flag cleared, n==1, price is the real one")

-- A second sale of the SAME tuple is now a repeat of a real obs -> "learned",
-- so it is excluded from the seed-accuracy stats (not double-counted).
sell ()
local s2 = db.log[#db.log]
ok (s2 and s2.pt == "learned",
	"second sale of the now-promoted tuple classifies pt==learned")
ok (db.obs["777:40:35"].n == 2, "second sale bumps the observation count to 2")

print (string.format ("\nvendor_seed_test: ALL %d ASSERTIONS PASSED", pass))
