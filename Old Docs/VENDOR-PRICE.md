# Vendor price estimator — shipped behaviour

**Status: REOPENED (2026-08).** A fresh 500-sale calibration dump showed the
"closed" 4.1% figure was an in-sample backtest artifact; honest live accuracy
is ~10% (all predictions) / ~18% (novel instances), dominated by the rung-free
`est` tier at ~20%. The active plan is **not** to refit the shape (proven
marginal) but to ship a bundled table of confirmed prices so fresh installs
resolve via `learned`/`interp` instead of `est` — see
`VENDOR-SEED-PLAN.md`. This file documents what shipped and what it costs. It
is a *reference*, not a research log.

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

delta -3 .. +2  ->  m = 1.00   (the base is a SHELF, and it extends downward)

delta   -4     -5     -6     -7     -8      (down shape, refit 2026-07; flat past -8)
m      0.43   0.42   0.38   0.35   0.33
```

**Down shape refit (2026-07).** The down region was a flat `m = 0.42`; with more
confirmed down rungs it is now clearly a decline with depth, so the flat constant
became the piecewise `ATR_VP_DOWN` table above (fit to the clean down cluster
across seven items: Gloomshroud, Mantle of Thieves, Doomspike, Flintrock + the
2167/2168/4661 ladders). Down-region backtest over the confirmed rungs
(`delta <= -4`), old flat vs the slope: **all down rows n=26, median 13.7% ->
2.9%; clean cluster n=19, 10.1% -> 0.9%.** The change is isolated to the
`delta <= -4` branch of stage 4 — the shelf and up-region shape are byte-identical,
so nothing above the down region can regress. The bimodal deep rows (a
cache-polluted `bil` making true delta ~0, `m ~0.89-1.27`) remain unfittable by
any down constant and are still the weakest output, exactly as before.

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

**Two numbers, and the gap between them is the whole point.**

**(1) Offline replay (optimistic).** 205 recorded sales replayed against the
estimator using each row's own `bp`/`bil`/`brq` snapshot gave median 4.1%. This
number **leaks**: the replay runs against the *current* `.obs`, which already
contains the very sales being scored, so most rows resolve via the `learned`
tier and the score is not out-of-sample. It was historically read as "the work
is done" — it is not a live figure.

**(2) Live calibration (honest).** Every scaled sale records `smp.pp`/`smp.pt`
*before* the observation is written (see the recorder in `AuctionatorHints.lua`),
so a first sale of a tuple is genuinely out-of-sample. Replaying the 500-row
`.log` from the 2026-08 dump on those recorded predictions:

```
ALL predictions      n=498   median 10.3%   <=25%: 62%   <=50%: 75%
NOVEL instances      n=442   median 18.5%   (excludes learned-tier resales)

by tier:
  learned  n= 56   median  0.0%   ( 11% of preds — exact tuple resold)
  plateau  n= 60   median  0.0%   ( 12% — but p90 73%, bimodal)
  interp   n=  4   median  2.9%   (  0% — almost never has bracketing rungs)
  est      n=378   median 20.5%   ( 75% — the rung-free cross-item shape)
```

**The est tier is 75% of live predictions and is structurally floored at ~20%**
because it uses the polluted cached `bil` as a base proxy (trusted base covers
1 of 361 est items). Region bias exists in the tails (down −4..−7 predicts ~28%
low; ≥+11 predicts ~13% high) but correcting it does not move the median —
the shelf/rising bulk is already unbiased noise, and blanket corrections regress
the whole set (10.3% → 11.7%). Best achievable single-multiplier fit for the
worst bucket only moves it 28.8% → 23.4%. **Refitting the shape is a dead end.**

The lever with real headroom is shrinking the est *share*, not its error —
i.e. shipping confirmed prices so more predictions resolve via `learned`/`interp`
(0–3%). That is `VENDOR-SEED-PLAN.md`.

Prior regression bar (retained for the shape itself): if a change moves the
offline-replay median above ~8%, the shape regressed. But note that bar was
never the live number.

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
