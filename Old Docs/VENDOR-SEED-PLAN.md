# Vendor seed plan — ship confirmed prices, measure the payoff (option C)

**Status: IN PROGRESS (2026-08).** Self-contained execution plan. You do not
need the analysis conversation or the source dump to finish this — everything
needed is in the repo. Read this top to bottom before touching code.

## Why (one paragraph)

Live calibration from a 500-sale dump showed the estimator's honest accuracy is
~10% median across all predictions and ~18% on novel instances — not the 4.1%
the docs claimed (that was an in-sample replay artifact; see the corrected
"Measured accuracy" section in `VENDOR-PRICE.md`). **75% of live predictions
come from the rung-free `est` tier at ~20% median, and that tier is structurally
floored** — it uses the polluted cached `bil` as a base proxy, and refitting the
shape is proven marginal (best-case worst-bucket fix 28.8% → 23.4%; blanket
corrections make the whole set *worse*). The only lever with real headroom is to
**reduce the est share**: ship a bundled table of confirmed prices so predictions
resolve via `learned`/`interp` (0–3% error) instead of `est`. Prices are
server-deterministic (`base × multiplier`, both server properties), so a confirmed
`(itemID:ilvl:req)` price is a global fact valid for every player, not per-character.

## What is already done

1. **`VENDOR-PRICE.md` accuracy section corrected** — reflects the ~10%/18% live
   numbers and marks the shape-refit path a dead end.
2. **`Auctionator-Finder-Ascension/AuctionatorVendorSeed.lua` generated** — the
   bundled seed, built from the dump's confirmed tables. Ships **only**
   server-deterministic facts:
   - `ATR_VENDOR_SEED.obs["itemID:ilvl:req"] = copper` — 774 confirmed sale prices.
   - `ATR_VENDOR_SEED.base[itemID] = { p, il, rq }` — 344 trusted base facts.
   - `ATR_VENDOR_SEED.meta = { built, nobs, nbase, src }`.
   It does **not** ship `.cb` or `.trk` — those are local cache-derived state and
   are meaningless (or wrong) on another client. The file parses under
   `luac5.1 -p` and is ~35 KB.

## What is left (the code integration)

Three edits in `AuctionatorHints.lua` plus one `.toc` line. All the anchors below
were accurate as of this writing; confirm line numbers before editing.

### Step 1 — load the seed file (`.toc`)

Add `AuctionatorVendorSeed.lua` to `Auctionator-Finder-Ascension.toc`. Load order
does not matter for correctness (the merge runs at `PLAYER_LOGIN`), but list it
just **before** `AuctionatorHints.lua` for readability:

```
AuctionatorVendorSeed.lua
AuctionatorHints.lua
```

### Step 2 — merge the seed at login (non-destructive, real-wins)

Add a merge function and call it from the existing `PLAYER_LOGIN` branch of
`Atr_VendorLearn_OnEvent` (currently the line that calls `Atr_SaleMsg_Init()`).

```lua
-- Seed fresh installs with the shipped confirmed-price table. Non-destructive:
-- a real observation (seed flag absent) is NEVER touched; a seed-only entry
-- (n == 0, seed == 1) may be refreshed when the shipped table's version bumps.
-- Idempotent — safe to run every login.
local function Atr_VendorSeed_Merge ()
	if (type(ATR_VENDOR_SEED) ~= "table") then return; end;
	local db  = Atr_VendorLearnedDB();
	local ver = (ATR_VENDOR_SEED.meta and ATR_VENDOR_SEED.meta.built) or "?";
	local prev = db.seedver;                     -- last applied seed version
	for k, p in pairs (ATR_VENDOR_SEED.obs or {}) do
		if (type(p) == "number" and p > 0) then
			local rec = db.obs[k];
			if (rec == nil) then
				db.obs[k] = { p = p, n = 0, seed = 1 };          -- fresh seed
			elseif (rec.seed and (rec.n or 0) == 0 and prev ~= ver) then
				rec.p = p;                                        -- refresh seed-only entry on version bump
			end
			-- rec with seed==nil or n>0 is a real observation: leave it.
		end
	end
	for id, r in pairs (ATR_VENDOR_SEED.base or {}) do
		if (type(r) == "table" and r.p and r.p > 0) then
			local b = db.base[id];
			if (b == nil or (b.seed and (b.n or 0) <= 1 and prev ~= ver)) then
				db.base[id] = { p = r.p, il = r.il or 0, rq = r.rq or 0, n = 1, seed = 1 };
			end
			-- a real base fact (seed==nil, majority-voted) is left untouched.
		end
	end
	db.seedver = ver;
end
```

Wire it in:

```lua
if (event == "PLAYER_LOGIN") then Atr_SaleMsg_Init(); Atr_VendorSeed_Merge(); return; end;
```

**Note on `Atr_VendorLearnedDB()`** (init): it does not create `.seedver`; that's
fine — a nil `prev` on first run differs from `ver`, so the first merge applies.

### Step 3 — make the seed measurable (`pt = "seed"`)

The whole point of shipping is to learn whether the shipped prices are right for
other players. The calibration recorder (`Atr_VendorRecordSale`) already stores
`smp.pp`/`smp.pt` before each write. Today a later real sale of a seeded tuple
would classify as `pt = "learned"` (the predictor found the seeded obs) and be
excluded from accuracy stats — hiding exactly the number we want. Fix the tier
classification so a first real sale of a **seed-only** tuple is tagged `seed`:

In `Atr_VendorRecordSale`, the pre-write block already computes `pp, pwhy, pest`
and reads `local rec = db.obs[key]` a few lines later. Capture the seed state
*before* the write and branch the tier:

```lua
local pp, pwhy, pest = Atr_VendorPredict_Get (ps.itemID, ps.ilvl, ps.req);
local key    = ps.itemID..":"..ps.ilvl..":"..ps.req;
local prior  = db.obs[key];
local wasSeed = prior and prior.seed and (prior.n or 0) == 0;    -- seed-only, never really sold here
local pt;
if     (pp == nil) then                          pt = "none";
elseif (pest) then                               pt = "est";
elseif (wasSeed) then                            pt = "seed";    -- out-of-sample vs the shipped table
elseif (Atr_VendorLearned_Get and Atr_VendorLearned_Get (ps.itemID, ps.ilvl, ps.req)) then pt = "learned";
elseif (pwhy and pwhy:find ("interpolated")) then pt = "interp";
else                                             pt = "plateau"; end
```

Then, where the record is written, **promote** the seed to a real observation so
it never double-counts and the price becomes ground truth:

```lua
local rec = db.obs[key];
if (rec == nil) then rec = { n = 0 }; db.obs[key] = rec; end;
rec.p = unit;
rec.n = rec.n + 1;
rec.seed = nil;                 -- promoted: a real sale outranks the shipped guess
```

`smp.pp` still holds the shipped price and `smp.p` the real one, so
`|p - pp|/p` over `pt == "seed"` rows **is** the shipped-table field accuracy.

### Step 4 (optional, honesty) — tooltip provenance

A seeded price is a shipped guess, not the user's own confirmed sale. Stage 1 of
`Atr_VendorPredict_Get` returns the obs price with reason `"learned at il..."`.
Optionally distinguish a seed-sourced hit (the obs rec has `seed == 1`) with a
different reason string and a different tooltip glyph — e.g. render `123c ~*`
(shipped) vs `123c *` (your confirmed sale) — so the marker in `VENDOR-PRICE.md`'s
resolution table stays honest. This is cosmetic; the price is authoritative either
way. Skip it if it complicates the hot path; the calibration data does not need it.

### Step 5 — surface it in `/atrvp`

The diagnostic already prints DB counts. Add: seed obs count vs promoted count,
and the running `pt == "seed"` median error from `.log`. That is the live readout
of whether shipping worked.

## Verification (do not skip — the docs' rule is "not verifiable by eye")

1. `luac5.1 -p` every edited file.
2. Extend the mock-WoW harness (`Old Docs/README-TESTS.md` describes the harness;
   `harness11` covers the predictor). Add cases asserting:
   - **Idempotent seed**: running `Atr_VendorSeed_Merge()` twice leaves `db.obs`
     identical; a seed-only entry has `n == 0, seed == 1`.
   - **Real-wins**: a pre-existing real obs (`seed == nil`) is never overwritten
     by the merge, even when `ATR_VENDOR_SEED.obs` has the same key at a different
     price.
   - **Version refresh**: bumping `meta.built` updates a seed-only price but still
     leaves real entries untouched.
   - **`pt == "seed"` classification**: selling a seed-only tuple logs `smp.pt ==
     "seed"` with `smp.pp` equal to the shipped price; the record is promoted
     (`seed == nil`, `n == 1`); a second sale of the same tuple now logs
     `learned`.
3. Re-run the full existing harness suite — no predictor regression. Because
   seeded entries only *add* obs rows, uncovered items are unchanged and the est
   shape is byte-identical.

## How success is measured (after shipping)

The original user already has all 774 tuples, so **they generate zero seed rows**
— measurement comes from other players who install the shared build (see
`README-SHARING.txt`) and return a dump. Read `pt == "seed"` from their `.log`:

- **Win**: seed-tier median error is well below est's ~20% (ideally single
  digits, i.e. the shipped prices hold cross-player), **and** a meaningful share
  of predictions that would have been `est` now resolve `seed`/`learned`.
- **Kill**: seed-tier median is near est's ~20% — meaning instance prices are
  *not* reproducible across players/characters after all. If so, stop shipping
  `obs`; the server-determinism assumption was wrong and only per-user learning
  helps. This is the one assumption the plan cannot verify offline; the `seed`
  tier exists precisely to test it.

## Regenerating the seed from a future dump

The seed is built by a throwaway generator that loads a SavedVariables dump and
emits `AuctionatorVendorSeed.lua` (sorted for stable diffs). It ships only
`.obs` (price > 0) and `.base` (n > 0, p > 0); never `.cb`/`.trk`. To rebuild
from a newer dump: load the dump as a Lua chunk, iterate
`AUCTIONATOR_VENDOR_LEARNED.obs`/`.base`, write the `ATR_VENDOR_SEED` literal,
bump `meta.built` (drives the version-refresh path in Step 2). Keep entries
sorted by `(id, il, rq)` / `id`.

## What NOT to do (learned the expensive way — see VENDOR-PRICE.md)

- **Do not refit the est shape.** Proven marginal; blanket corrections regress
  the median. The lever is share, not error.
- **Do not ship `.cb` or `.trk`.** Cache/local-derived; wrong on another client.
- **Do not let the seed overwrite a real observation.** One real sale beats any
  shipped guess — real-wins is load-bearing.
- **Do not chase a big shopping campaign.** The est population is a ~360-wide long
  tail (~1 hit/item); buying only pays inside the user's own level band.
```
