# Vendor price estimator — shipped behaviour

**Status: CLOSED (2026-07).** The estimator performs well enough and the
research programme is finished. This file documents what shipped and what it
costs. It is a *reference*, not a research log.

The evidence trail — four measured ladders, five live case studies, the harvest
datasets and the harvest #4/#5 shopping protocols — is archived in
`VENDOR-PRICE-RESEARCH.md` (1,120 lines). You do not need it to work on this
code. Open it only if you are reopening the investigation, and read
"If you reopen this" at the bottom first.

---

## The problem, in one paragraph

Ascension scales item *instances* server-side without encoding it in the item
link, so every link-based API reports whichever variant the client cached (see
`ASCENSION-CLIENT-NOTES.md`). There is **no per-instance price API** — audited
2026-07, none exists. The only ground truth for what an instance sells for is
the merchant buyback list, i.e. actually selling it. Everything below exists to
answer "what is this worth" for variants that have never been sold.

The model: `price = true_base_price × m(level pair, track)` — a per-item base
times a multiplier that rises with the scale jump and saturates at a
track-specific plateau. Both simpler models (per-item constant; base-free
function of the instance) are dead, disproven by direct measurement.

## Resolution order

`Atr_VendorPredict_Get(itemID, ilvl, req)` in `AuctionatorHints.lua`, inside the
`FINDER_TAB: vendor price learning` block. First match wins, strongest first.
It returns the price **and a human-readable reason string** for every outcome.

| # | Stage | Tooltip renders | Source |
|---|---|---|---|
| 1 | Confirmed sale of this exact `(itemID:ilvl:req)` | `123c *` | `.obs` |
| 2 | Interpolation between this item's confirmed rungs | `123c` | `.obs`, log-linear; flat above the top rung only when the two highest rungs agree |
| 3 | Gated plateau rule from cache/base inputs | `Predicted 123c` | track cap + delta gate |
| 4 | Cross-item shared-shape estimate | `~123c (est)` | the shape below |

Stage 4 always answers, so `unknown (scaled)` is now an empty tier. Stage 3's
delta gates are a conservatism knob for items with zero confirmed sales — **do
not fit them further**; they are computed from cached `bil`, which sits above
the effective base on every measured item, so they systematically refuse.

## The shipped shape (stage 4)

Normalised saturation `s = ln(m) / ln(cap)` against the cached template ilvl,
so `m = cap^s`:

```
delta   +1     +2     +4     +6     +8    +11    +14
s      0.124  0.155  0.248  0.334  0.630  0.965  1.000

delta -3 .. 0   ->  m = 1.00   (the base is a SHELF, and it extends downward)
delta <= -4     ->  m = 0.42
```

Track cap, from the brq/class rules:

```
ranged slot, brq <= 15      -> 7.5
custom range (id >= 2M)     -> 2.5
melee weapon slot           -> 2.0
armor, brq <= 15            -> 7.5
otherwise                   -> 2.0
```

**The track rule is known incomplete** — 19 of 156 backtested rows with
`brq > 15` priced above 2.6×, up to 7.51×, with nothing observable separating
them. Rather than guess further, `db.trk[itemID]` holds the highest confirmed
`p/bp` ratio ever seen for that item and acts as a **floor on its cap**, so one
sale above the assigned cap corrects that item permanently. Clamped at 7.5: no
higher cap has ever been observed, so a larger ratio means the *base* was
wrong. A ratio lower than the rule track never lowers it.

## Measured accuracy

Live backtest, 205 recorded sales replayed against the shipped estimator using
each row's own sale-time `bp`/`bil`/`brq` snapshot (13 pre-`brq` rows excluded
as backtest artifacts):

```
ALL rows        n=176   median 4.1%   <=25%: 79%   <=50%: 86%
OUT-OF-SAMPLE   n=128   median 4.1%   <=25%: 76%   <=50%: 86%
  up-scale      n=147   median 2.4%
  base shelf    n= 11   median 0.0%
  down (<=-4)   n= 18   median 6.1%
```

Out-of-sample scores identically to fitted — the shape is not overfitted. For
comparison on held-out points: "assume capped" median 12.2% but worst 360%;
"geometric mid" 29.3%; "assume base" 50.0%.

**This is the number that says the work is done.** If a future change moves
median error above ~8%, that is a regression, not noise.

## Data

`AUCTIONATOR_VENDOR_LEARNED` (account-wide):

| Field | Contents |
|---|---|
| `.obs` | confirmed `(itemID:ilvl:req)` → price. The `*` tier. |
| `.log` | raw samples, cap 500. Fields: id, il, rq, bil, brq, bp, qual, cls, sub, slot, p, q, + tb/tbi/tbr/tbn when base facts exist |
| `.base` | trusted base facts from unscaled sales |
| `.cb` | per-variant sighting map: `cb[itemID] = { v = { [il] = { p, rq, ag } } }`, cap 12/item, evicting the **highest** il (low sightings are irreplaceable base evidence; high ones are recomputable via the plateau) |
| `.trk` | per-item cap floor, see above |

`.cb` exists because **owning an item repoints the client cache at that
instance**, so a single-slot registry gets captured by whichever variant you
bought last, and several owned variants leapfrog each other. The cache's churn
is the data source.

**Calibration recorder:** every scaled sale stores `smp.pp` (what the predictor
would have said) and `smp.pt` (`learned`/`interp`/`plateau`/`est`/`none`),
taken *before* the observation is written, so a first sale of a tuple is
genuinely out-of-sample. Every vendor trip is a free calibration point. Keep
this — it is what would tell you accuracy had drifted.

## Diagnostics

`/atrvp` alone prints the build tag and DB counts — "unknown command" means a
stale file is deployed. With `<itemID|shift-clicked link> [il rq]` it dumps the
`GetItemInfo` view, base facts, sighting map, all learned tuples, and the
prediction with its reason string.

This exists because a live session once concluded a wrong "stale build" theory
by screenshot elimination. **Screenshot elimination cannot distinguish builds;
diagnostics can.** Use `/atrvp` first, always.

## Known limits — correct behaviour, not bugs

- **Inputs are the untrusted cached `bp`/`bil`/`brq`.** This is structural. No
  API exposes anything better (audited). Cache pollution is why the worst
  leave-one-out miss (41.8%) was item 2167.
- **Below about delta −7 the cached `bil` is too far from the effective base**
  for any constant; the band is bimodal (~0.35–0.41 where the cache sits near
  the template, ~0.89–1.27 where it sits well above). Estimates are still
  offered there and are the weakest thing the predictor returns.
- **`.base` has zero overlap with any scaled-sale itemID**, three harvests
  running. This no longer matters: rung interpolation consumes only confirmed
  sales. `.base` is now wanted for exactly one thing — testing the
  band-uniform-pricing claim — which is not needed for the estimator to work.
- **The shape rests on n=4 ladders.** It will move if more are measured. That is
  a reason to leave it alone, not to remeasure it.

## Still running, now optional

The **research-target ledger** (`AUCTIONATOR_FINDER_RESEARCH`, `/atrtarget`,
`/atrresearch on|off`) absorbs and ranks candidate purchases on every scan. It
was built to feed this investigation. With the investigation closed it is doing
per-scan work and growing SavedVariables for no live purpose.

Leave it on only if you want the shopping list. Otherwise `/atrresearch off`.
The calibration recorder is separate and should stay on regardless.

## If you reopen this

Do not start by reading the archive end to end. Three rules, learned expensively:

1. **One confirmed sale beats any amount of fitting.** Selling an item once
   records the exact tuple in `.obs` and outranks every estimate. Most
   "improvements" are better spent on a vendor trip.
2. **Do not fit the stage-3 gates.** Fit rungs instead.
3. **A prediction change is not verifiable by eye.** Re-run the backtest against
   `.log` and compare against the 4.1% median above. `harness11` covers the
   predictor (cases 12–17); `harness24` covers the ledger and the down-scale
   floor, including the 14573 regression.
