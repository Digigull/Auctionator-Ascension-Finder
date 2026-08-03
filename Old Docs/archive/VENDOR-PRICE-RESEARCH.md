> **ARCHIVED (2026-08).** Completed research journal. The investigation is
> closed and its scaffolding removed (see `../VENDOR-RESEARCH-CLEANUP-PLAN.md`).
> The single living spec is `../VENDOR-PRICE.md`; this file is kept only as the
> evidence trail. Do not treat anything here as current behaviour.

# Vendor Price Research: Ascension per-instance scaling formula

Goal: derive the server's formula for the vendor sell price of scaled item
instances, so tooltips can PREDICT prices for variants never sold
(`Atr_VendorLearned_Get` already shows exact prices for sold variants).

## Dataset (harvest #1, 2026-07, char Falku, 12 unique tuples)

| itemID  | bil | il | bp    | p     | ratio   | note              |
|---------|-----|----|-------|-------|---------|-------------------|
| 14745   | 20  | 42 | 555   | 1111  | 2.000   | exact             |
| 1460    | 20  | 42 | 2211  | 4421  | 2.000   | exact             |
| 15248   | 20  | 42 | 2240  | 4480  | 2.000   | exact             |
| 2035    | 24  | 46 | 2876  | 5752  | 2.000   | exact             |
| (belt)  | ?   | 42 | 662   | 1324  | 2.000   | from screenshots  |
| 14580   | 27  | 42 | 1024  | 1685  | 1.6455  | sold x2, same p   |
| 2074563 | 24  | 42 | 1122  | 2758  | 2.4581  | CUSTOM id (>=2M)  |
| 3314    | 15  | 42 | 57    | 428   | 7.5     | exact given bp rounding |
| 9756    | 14  | 42 | 98    | 736   | 7.5     | exact given bp rounding |
| 15925   | 10  | 42 | 117   | 879   | 7.5     | exact given bp rounding |
| 5612    | 13  | 39 | 24    | 182   | 7.5     | exact given bp rounding |
| 15397   | 14  | 39 | 244   | 1413  | 5.791   | conflicts w/ 5612! |
| 7758    | 39  | 32 | 9421  | 3512  | 0.3728  | DOWN-scaled (notes' example item) |

## Dataset (harvest #2, 2026-07, 35 log rows / 33 obs tuples)

22 rows carry the full field set (brq/qual/cls/sub/slot). Coverage:
cloth+leather+mail across 8 slots, 4 weapon subclasses, 4 custom-range
items, one quality-1 item, two down-scaled sales. NO itemID was sold at
more than one ilvl (the gold experiment is still outstanding); 14580 was
sold twice at the SAME tuple -> identical price both times.

| itemID  | cls/sub          | slot     | q | bil->il | brq->rq | bp    | p    | ratio  |
|---------|------------------|----------|---|---------|---------|-------|------|--------|
| 3074    | Armor/Cloth      | HAND     | 2 | 24->43  | 19->39  | 595   | 1191 | 2.0017 |
| 2067629 | Armor/Cloth      | LEGS     | 2 | 21->43  | 16->39  | 749   | 1873 | 2.5007 CUSTOM |
| 14158   | Armor/Cloth      | CHEST    | 2 | 26->43  | 21->39  | 412   | 1312 | 3.1845 |
| 14176   | Armor/Cloth      | FEET     | 2 | 26->43  | 21->39  | 307   | 1312 | 4.2736 |
| 7738    | Armor/Cloth      | HAND     | 2 | 18->40  | 10->36  | 71    | 530  | 7.4648 |
| 6512    | Armor/Cloth      | ROBE     | 2 | 13->44  |  8->40  | 64    | 478  | 7.4688 |
| 5610    | Armor/Cloth      | CLOAK    | 2 | 15->40  | 12->36  | 69    | 520  | 7.5362 |
| 15401   | Armor/Cloth      | HAND     | 1 | 14->40  | 13->36  | 24    | 183  | 7.6250 |
| 14668   | Armor/Leather    | LEGS     | 2 | 52->47  | 47->43  | 16996 | 7120 | 0.4189 DOWN |
| 4737    | Armor/Leather    | SHOULDER | 2 | 44->48  | 39->44  | 7179  | 9120 | 1.2704 |
| 14574   | Armor/Leather    | LEGS     | 2 | 26->44  | 21->40  | 1960  | 3920 | 2.0000 |
| 5629    | Armor/Leather    | HAND     | 2 | 20->39  | 15->35  | 116   | 869  | 7.4914 |
| 15305   | Armor/Leather    | FEET     | 2 | 18->44  | 13->40  | 137   | 1031 | 7.5255 |
| 15399   | Armor/Leather    | WAIST    | 2 | 14->39  | 11->35  | 50    | 378  | 7.5600 |
| 9763    | Armor/Mail       | LEGS     | 2 | 14->43  |  9->39  | 112   | 841  | 7.5089 |
| 1616007 | Armor/Misc       | TRINKET  | 2 | 35->48  | 30->44  | 2500  | 4783 | 1.9132 CUSTOM |
| 2074552 | Armor/Misc       | HOLDABLE | 2 | 15->43  | 10->39  | 192   | 480  | 2.5000 CUSTOM |
| 5627    | Weapon/Daggers   | WEAPON   | 2 | 20->40  | 15->36  | 460   | 1663 | 3.6152 |
| 1938    | Weapon/1H Maces  | WEAPON   | 2 | 22->44  | 17->40  | 2453  | 4905 | 1.9996 |
| 2075    | Weapon/1H Maces  | MAINHAND | 2 | 12->43  |  7->39  | 483   | 967  | 2.0021 |
| 2074558 | Weapon/Staves    | 2HWEAPON | 2 | 18->43  | 13->39  | 691   | 1728 | 2.5007 CUSTOM |
| 1458    | Weapon/2H Maces  | 2HWEAPON | 2 | 23->43  | 18->39  | 3279  | 6559 | 2.0003 |

All p buyback-confirmed; il/rq from server tooltip at sale time; bil/brq/bp
from cached GetItemInfo (SEE THE MEASUREMENT PROBLEM BELOW).

## Established findings (updated after harvest #4c)

Harvest #3: 106 log rows / 104 unique `(itemID, il, rq)` tuples (from 35
rows).  62 of 104 land EXACTLY on a quantized multiplier (within the
float-base rounding below): x2.0 (29), x7.5 (15), x2.5 (9), x1.0 (9).

**STATUS OF THESE FINDINGS AFTER THE LADDERS (#4 / #4b / #4c).**  Read
the numbered list below as the harvest-3 state of knowledge, then apply:

- Findings 1, 6, 7, 8 STAND, and 6 (float bases) and 7 (band-uniform
  pricing) are strengthened - see harvest #4c.
- Finding 2 ("m is a function of the level pair") is DEAD as a universal
  claim: harvest #4b showed two items rising at different rates from
  equal effective delta, and harvest #4c showed one item whose rise is
  not even smooth in il.  m is per-item; only the CAPS generalise.
- Finding 3 (plateaus) STANDS and is now proven flat by direct
  measurement on two tracks (x7.5: 2167 il33 = il42; x2.0: 2168
  il33 = il38).  The *onsets* quoted there are upper bounds only, and
  both have been beaten badly - see the gate note below.
- Findings 4, 5 (brq boundary, track rules) still hold as TRACK-CAP
  selectors.  They were never the pricing model, and after #4b they are
  only used to pick which cap a cache-only item saturates at.
- Finding 9 (down-scaling unquantized) STANDS and is the single largest
  remaining hole in the map.

1. **The model fork is RESOLVED: both pure models are dead.**
   - Gold experiment landed: 1616007 sold at il48/rq44 -> 4783c and at
     il50/rq46 -> 5004c.  Price moves with the instance level, so Model A
     (instance-independent per-item multiplier) is dead.
   - 1955 vs 2991: both Armor/Mail/FEET/q2 sold at identical il45/rq41,
     prices 3934c vs 1764c, each exactly 2.000x its own bp.  Same instance
     properties, different prices: Model B (bp-free F(instance)) is dead.
   - The live model: **p = true_base_price x m(level pair, track)** - a
     per-item base price times a multiplier that depends on the scale
     jump and saturates at a track-specific plateau.
2. **m is a function of the level pair, not the item (within a track).**
   2064869 and 2071840 (both bil41 -> il48) share m = 1.42349 to five
   decimals with different base prices.  The small-jump region traces a
   rising curve: m ~ 1.0 at delta <= 4 (nine exact x1.0 rows), 1.21-1.50
   at delta 6-9 (monotone in level: 1.387@il46, 1.414@47, 1.424@48,
   1.432@49, 1.500@52), 1.85 at delta 14 (6417), then plateau.  The
   1616007 pair sits exactly on the knee: 1.9132 at delta 13, 2.0016 at
   delta 15.
3. **Plateaus are the old quantized multipliers.**  Stock plateaus at
   x2.0 by delta ~15; custom (id >= 2M) plateaus at x2.5 slightly later
   (1616208 still climbing at delta 17: 2.178); the cheap track plateaus
   at x7.5 (observed only at delta >= 19 so far).
4. **The armor brq boundary is pinned exactly at 15/16.**  Every clean
   x7.5 armor row has brq <= 15; every clean x2.0 armor row has brq >= 16
   (2991 at brq16 closes harvest #2's 16-18 gap).  Perfect in-sample
   split.
5. **Track rules across classes** (new, and not what harvest #2 guessed):
   - MELEE weapons are 2.0-track even at very low brq (mace brq7, sword
     brq11, staff brq13 -> all exactly 2.0), so brq does NOT discriminate
     for melee.
   - RANGED weapons (INVTYPE_RANGED/RANGEDRIGHT) follow the armor rule:
     wand brq7 -> 7.5, crossbow brq13 -> 7.5, gun brq26 -> 2.0.
   - The crossbow (3595664) is CUSTOM-range yet got x7.5, not x2.5: the
     ranged/brq rule overrides the custom track (n=1, needs confirmation).
6. **Multipliers are exact; server base prices carry sub-copper
   precision.**  Many "x2" prices are odd (967 = 2x483+1, 6559 =
   2x3279+1), impossible for 2 x integer - so true bases are floats and
   the quantized multipliers are exact.
7. **NEW PHENOMENON - convergence bands**: different items at the same
   (il, rq) selling for IDENTICAL prices: five different il50/rq46 armor
   pieces (7468/7469/7488/7534/9910, recorded bps 1029-2254) all ->
   3487c; 14158/14176/6757 at il43/rq39 -> 1312c; 6596/15556/15582 at
   il46/rq42 -> 3026c; pairs at 284c (il22), 3179c (il47), 3333c (il48).
   Under the multiplier model these items must share the same TRUE base
   price (band-uniform Ascension repricing) and their recorded bp is
   cache junk.  The 1616xxx accessory family PROVES Ascension does
   band-uniform base pricing: four different items, all base 2500c.
8. Determinism reconfirmed: 2067553 sold twice at the same tuple ->
   identical price (as 14580 in harvest #1).
9. Down-scaling: still unquantized, but see harvest #5b - four points
   on three items now, and it is item-dependent and NOT the mirror of
   the rise.  Original note:  4 samples, m 0.373-0.426, no clean
   value; the x1.0 rows show SMALL down-jumps (delta -2..-5) can also
   leave the price untouched, muddying the boundary.
10. The 5627 dagger (3.6152) remains the one clean-input row no rule
    explains.  15207 (shield, 3.84) is a lone outlier against three other
    shields at exactly 2.0 - presumed dirty bp.

## THE MEASUREMENT PROBLEM: bp/bil/brq are not trustworthy

(Unchanged from harvest #2, and STRENGTHENED: the convergence bands in
finding 7 are only explainable if recorded bp is cache junk for those
rows.  Every one of the 42 non-clean ratios is *explainable* as
cache-polluted bp, but that is unfalsifiable until trusted base facts
overlap the resale items - see Base facts status below.)

The learning hook reads baseIlvl/baseReq/basePrice from link-based
`GetItemInfo` at sale time - the cached-first API that
ASCENSION-CLIENT-NOTES documents as lying for scaled items.

Cross-check against the stock 3.3.5 DB (Wowhead WotLK):
- 14580 Dokebi Bracers: stock il 27 / req 22 / sell 818c. Log recorded
  bil 27 (matches) but bp **1024** (does not).
- 14158 Pagan Vest: stock il 26 / req 21 / sell 1236c. Log recorded
  bil 26 / brq 21 (match) but bp **412**.

Since bil/brq match stock while bp does not, this looks less like cache
pollution and more like **Ascension having repriced base items** - which
also means Wowhead CANNOT serve as bp ground truth.  Band-uniform pricing
(finding 7) is consistent with a wholesale repricing pass.

## RESOLVED: the 14158 vs 14176 model fork (harvest #2's open anomaly)

Both fetched 1312c despite recorded bps of 412 vs 307.  Now understood as
a convergence band (finding 7): they share a TRUE (repriced) base price
and both recorded bps are cache junk.  The A-vs-B fork itself is settled
by finding 1: the truth is the hybrid p = true_bp x m(level pair, track).

## Shipped prediction rule (gated) - 2026-07

> **DEMOTED as of harvest #4c.**  This gated rule set is no longer the
> primary predictor - it is the LAST-RESORT fallback, below trusted base
> facts, learned rungs, and rung interpolation (see "SHIPPED:
> confirmed-rung interpolation" below).  The delta gates are now known
> to be far too conservative on BOTH measured tracks:
>
>     track  gate needs  really capped by  but the GATE sees (cached bil)
>     x7.5   delta >= 19  +19 (2167, eff. base il14)   +13  -> REFUSES
>     x2.0   delta >= 15  <= +14 (2168, eff. base il19) +12  -> REFUSES
>
> The gate is computed from the cached `bil`, which sits ABOVE the
> effective base on both measured items (+6 gloves, +2 boots), so the
> gate's delta is systematically SMALLER than the real one.
>
> So an instance that is already sitting AT its cap can fail the gate and
> render "unknown (scaled)".  This is harmless (the interpolator now
> answers first for any item with rungs) but it means the gate numbers
> must not be quoted as findings.  They are a conservatism knob for
> items with zero confirmed sales, nothing more.  Do not "fit" them
> further; fit rungs instead.

`Atr_VendorPredict_Get (itemID, ilvl, req)` in AuctionatorHints.lua
(inside the "vendor price learning" FINDER_TAB block; harness11 cases
12).  Feeds the tooltip: a scaled variant with no learned price shows
**"Predicted vendor: <price>"** when the gate passes, and keeps
"unknown (scaled)" otherwise.  Learned prices keep the '*' line and
always win over prediction.

Rule set (first match; inputs prefer trusted `.base` facts with x == 0,
else cached GetItemInfo):

    exact il match (delta == 0)        -> m = 1.0, no gate
    ranged slot and brq <= 15          -> m = 7.5, gate delta >= 19
    custom range (id >= 2,000,000)     -> m = 2.5, gate delta >= 20
    melee weapon slot                  -> m = 2.0, gate delta >= 15
    armor, brq <= 15                   -> m = 7.5, gate delta >= 19
    otherwise (armor brq >= 16 etc.)   -> m = 2.0, gate delta >= 15
    prediction = floor(bp x m + 0.5); below gate / down-scale -> nil

In-sample accuracy (harvest #3, recorded inputs): 52/104 tuples pass the
gate; 45/52 within 2% of the confirmed price (87%); 45/49 (~92%)
excluding the three convergence-band rows whose bp is presumed polluted.
Remaining misses: 5627 (the dagger anomaly), 15207 (lone shield
outlier), 15336 (5.17, dirty bp).  1616208 (custom caught mid-rise at
delta 17) is handled by the later custom gate.

CAVEATS: live accuracy will be LOWER than in-sample - the predictor's
inputs are exactly the untrusted cached fields, and in-sample "clean"
rows are the ones where the cache happened to be right.  The rising
curve (delta below gate), down-scales, and convergence-band items
produce no prediction by design.

### Live-input hardening: the .cb base-candidate registry (2026-07)

First live use exposed a failure mode: buying a predicted item made the
prediction disappear after /reload ("unknown (scaled)", permanently).
Cause: owning an item rewrites the on-disk item cache to THAT instance's
values (see ASCENSION-CLIENT-NOTES), so GetItemInfo then reports
bil ~ tipIlvl, delta collapses to ~0, and the gate suppresses the
prediction.  This hits every owned item - bag tooltips were mostly
"unknown (scaled)" - while un-owned Finder listings kept predicting
from their stale (useful) cache.

Fix v1 (superseded): a single lowest-il sighting per itemID.  Live use
immediately found its failure mode - see below.

### .cb v2: the per-variant sighting MAP (2026-07)

Live case study #2 (Foreman's Gloves, three owned variants): the
single-slot registry locked onto a previously-owned SCALED copy
(113c @ il17/rq15).  From that candidate the il52 hyperlink tooltip
predicted 848c = 113 x 7.5 (consistent, and correct for il52), but the
owned il33 copy sat at delta +16 (below the 7.5-track gate of 19) and
the owned il13 copy - the TRUE base - at delta -4: both permanently
"unknown (scaled)".  One slot cannot survive owning several variants
that leapfrog each other through the item cache.

Fix: `cb[itemID] = { v = { [il] = { p, rq, ag } } }` - EVERY distinct
ilvl GetItemInfo has ever served, with that sighting's price.  The
cache's churn becomes the data source: each time the WDB record flips
to another variant, that variant's (il, price) is harvested.  Cap 12
per item, evicting the highest il (low sightings are the irreplaceable
base evidence; high ones are recomputable via the plateau).  Agreed
sightings (server tooltip matched the cache, ag=1) refresh and pin a
tuple; unagreed refreshes never displace an agreed price.  v1 flat
records migrate in place on first touch.

Predictor resolution order:
1. trusted `.base` (x == 0) with base il == instance il -> x1.0, done;
2. exact instance il in the sighting map -> x1.0 with that price, done;
3. plateau math with inputs `.base` > lowest map sighting > live cache.

Consequences for the case study: the il33 copy predicts the moment the
cache serves (or has served) il33; the il52 phantom still predicts 848
from the lowest sighting; the il13 copy stays honestly unknown until
il13 is sighted with a price - or simply SOLD once, which records the
exact tuple in `.obs` (shown with '*') and, if the cache agrees at
sale time, seeds `.base`.  Covered by harness11 cases 13-14.

Limits: sightings inherit cache trustworthiness; a polluted mixed
record poisons only its own il entry, and a sale-confirmed `.base` or
`.obs` record always outranks it.

### No API shortcut exists (audited 2026-07)

The shipped APIDocumentation was audited for any per-instance price
source: GetItemInfo's vendorPrice is the same cached field, and
GetItemInfoInstant, container, and tooltip APIs expose nothing.  A
variant that has never been priced by a sale or a cache sighting is
UNPREDICTABLE by design - "unknown (scaled)" is the correct output,
and the designed resolution is one confirmed sale (obs) per tuple.
Untested possibility: whether the at-merchant bag tooltip's Sell Price
money line is server-rendered per-instance on this client (stock 3.3.5
computes it client-side from the cache).  If a live test shows the
merchant tooltip matching the buyback-confirmed price while differing
from the cache, a merchant-window bag sweep could harvest real prices
WITHOUT selling - worth one screenshot experiment before building.

### Diagnostics + verified-listing vendor line (2026-07)

Live iteration kept stalling on "which build is actually deployed";
a stale-build theory was even (wrongly) concluded from screenshot
elimination.  /atrvp settled it in one line - case study #3 resolved:

**Foreman's Gloves = itemID 2167; TRUE base = il20 / rq15 / 113c**,
served by numeric-ID GetItemInfo (the item template) and corroborated
by an (ag) server-agreed sighting.  Every owned copy was a scaled
variant: il13/17/18 are DOWN-scales (delta -7/-3/-2), il26/31/33 sit
at delta +6/+11/+13 - the entire population lives inside the unmapped
rising-curve/down-scale region, so every build correctly predicted
nothing except the far il52 listing (delta +32 -> x7.5 -> 848c).  The
earlier candidate reconstruction "(113, il17)" was off by one rung
(il20), which made all three builds behave identically and the
elimination logic unsound.  Lesson recorded: screenshot-elimination
cannot distinguish builds; diagnostics can.  Countermeasures, so this
never needs deducing again:

- `Atr_VendorPredict_Get` returns a second value: a human-readable
  reason string for every outcome (rule fired, gate distance, missing
  inputs).  Covered by harness11 case 15.
- **`/atrvp`** (in AuctionatorHints.lua): alone, prints the BUILD TAG
  and db counts - "unknown command" means a stale file is deployed.
  With `<itemID|shift-clicked link> [il rq]` it dumps the GetItemInfo
  view, base facts, sighting map (flagging leftover v1 records), all
  learned tuples, and the prediction with its reason.
- The Finder row tooltip's scaled note now appends, once Verify has
  pinned a listing's true item level: "Verified: item level N.
  Vendor: X" - the learned price ('*') or the gated prediction for the
  EXACT listing.  The dimmed tooltip body above it always renders
  whichever variant the client cache holds (verified il 31 vs rendered
  il 52 in the case study - expected client behavior, not fixable by
  an addon: only appended lines are ours).

### The x1.0 exact-il rule + first live case study (2026-07)

Live screenshots (Foreman's Gloves) confirmed the whole pipeline on one
item: an il52/rq48 listing predicted 848c = 113c x 7.5 (cheap track,
base sighting 113c @ il13/brq11), while two OWNED copies at il13/rq11
and il17/rq15 showed "unknown (scaled)" - correctly gated, since delta
vs the registry base is 0 and 4.

Delta 0 is predictable though: 8117 (bil47=il47, rq 42->43) and 4108
(bil40=il40, rq 28->33) both sold for EXACTLY their base price - an
instance at the base ilvl is x1.0 even when its required level is
shifted.  Shipped: delta == 0 -> return the candidate price, no gate
(harness11 case 14).  The lone counterexample, 14728 (il22=bil22 ->
x1.75), has a convergence-band price and a therefore-suspect bp.

Delta 1..gate-1 stays unpredicted: the samples conflict (x1.0 at +1/+3/
+4: 2271, 5249, 5029; but x1.21 at +3: 2074625; x2.04 at +2: 9770 with
suspect bp).  Only ladder data can settle this region.

NOTE ON LINK-RENDERED TOOLTIPS (hyperlink/mail/etc.): those tooltips
describe whichever variant the client cache serves, and the prediction
is computed for the TUPLE THE TOOLTIP DISPLAYS (tipIlvl from its own
lines) - so the line is always self-consistent with the stats above it.
On the Finder this is additionally covered by the dimmed-stats warning
and the per-listing "actually requires level N" note.

## Live case study #5: the crossed ladder + the confirmation race (2026-07)

The first same-item ladder (item 2167, five variants sold in one spree)
exposed a LEARNING-HOOK BUG: confirmation matched the newest buyback
entry by name+count only, and with five same-name count-1 items the
confirms lagged one sale behind - each pending got the PREVIOUS item's
price.  Log rows 107-112 show it: (26,23) recorded 101c (= the il13
sale before it), and a sixth confirm put 848c on (13,11), n=2.
Determinism (same tuple = same price) rules out the recorded values.

De-shifted (each recorded price belongs to the previous pending), and
confirmed by monotonicity, the TRUE ladder for 2167 (template base
113c @ il20/rq15, sighting-agreed):

    il13 -> 101c   (x0.894 of template base)
    il17 -> 184c   (x1.628)
    il18 -> 208c   (x1.841)
    il26 -> 493c   (x4.363)
    il33 -> 848c   (x7.504 - the x7.5 plateau, reached by delta+13!)

TWO PUZZLES this opens:
1. il17/il18 sit BELOW the template's il20 yet price ABOVE the 113c
   base.  Either the template tuple is not Ascension's true base (a
   log-linear fit through the five rungs puts F(base)=113c near il14,
   not il20), or down-scaling does not reduce price symmetrically.
   More rungs decide it - especially an il20 instance, and an il14-16.
2. The x7.5 plateau arrived by delta 13 for this item, versus the
   harvest-3 gate of 19 (lowest previously OBSERVED plateau member).
   The rising curve is steeper than the gate assumed; after one clean
   re-run the gates should be replaced with the fitted curve.

FIX SHIPPED: buyback confirmation is now TUPLE-EXACT - pending sales
go into a FIFO queue (pruned 3s), and every confirm event sweeps the
newest ~8 buyback slots, reading each entry's own server tooltip via
GameTooltip:SetBuybackItem to match name + count + il + rq.  Lagging
and batch arrivals both attach to the right tuple; unreadable tooltips
fall back to FIFO name+count.  Harness11 case 16 replays the exact
crossed-spree scenario.  NOTE: obs for 2167 currently holds the
crossed values (13:11=848 etc.); one clean re-sale per copy with the
fixed build overwrites them (rec.p is refreshed on every confirm).

MERCHANT-TOOLTIP EXPERIMENT CONCLUDED: at the merchant, scaled bag
items show NO Sell Price money line at all (screenshot-verified) - the
read-without-selling channel does not exist.  Buyback confirmation
remains the only price ground truth, now tuple-exact.

## HARVEST #4: the first clean same-item ladder (2026-07)

Re-run with the tuple-exact build, item 2167, seven distinct rungs +
one repeat (fresh SavedVariables; the harvest #1-3 dataset lives in
the user's backup of the previous file):

    il13 -> 101c   (x2, identical - determinism reconfirmed, n=2)
    il17 -> 184c
    il18 -> 208c
    il26 -> 493c
    il31 -> 737c
    il33 -> 848c   }
    il42 -> 848c   }  IDENTICAL

Findings (all against the template tuple 113c @ il20/rq15):
1. The case-study-#5 lag reconstruction is VERIFIED rung-for-rung.
2. **The plateau is FLAT**: il33 and il42 both 848c = 113 x 7.5.  Past
   saturation, price is constant in il.  (Explains why plateau rows in
   harvests 1-3 fit "one multiplier" so cleanly.)
3. **The template tuple is NOT the pricing base.**  The curve passes
   smoothly through il20 at ~x2.3 with no kink at x1.0; the x1.0
   crossing interpolates to ~il14.  Measured from that EFFECTIVE base,
   plateau onset is delta ~19 - matching the harvest-3 gate exactly.
   Consequence: delta gates computed from template/cached bil are
   biased for items whose template il differs from the pricing base;
   rung interpolation (below) sidesteps this entirely.
4. Rising curve (log-slope per il declines smoothly ~0.15 -> 0.07
   approaching the cap); with effective-base deltas: -1 -> 0.894,
   +3 -> 1.628, +4 -> 1.841, +12 -> 4.363, +17 -> 6.522, >=19 -> 7.5.
   Speculative cross-track note: normalized saturation s = ln(m)/ln(cap)
   is roughly comparable to the 2.0-track's lone rising sample
   (s ~ 0.89 @ delta14 vs glove 0.84) - one shared shape scaled to the
   track cap is plausible but unproven.

### Harvest #4b: the second ladder (2168) + a custom down-scale

Item 2168 (Foreman's Boots, template 587c @ il21/rq16, x2.0-track by
the brq boundary): il15 -> 224c, il19 -> 587c, il25 -> 697c,
il26 -> 786c.  Item 2071492 (custom wrist, cached bil31): il29 sold
for exactly its cached price (x1.0).

1. **Effective base confirmed on a second item**: il19 sells for
   EXACTLY the template price - effective base il19 vs template il21
   (gloves: il14 vs il20).  Per-item offsets differ (-2 vs -6); no
   pattern yet.  RETROACTIVE RESOLUTION: every harvest 1-3 "x1.0 at
   small delta" row was an instance AT its effective base (template
   offset illusion), not a down-scale quirk.  True down-scales always
   price BELOW base: delta -1 -> x0.894 (gloves), -4 -> x0.382
   (boots, squarely inside the old 0.37-0.43 down cluster - which now
   reads as one steep down-curve).  The wrist's "x1.0 at bil31->il29"
   is its effective base being ~il29.
2. **Normalized-saturation hypothesis REJECTED as tested**: the boots
   rise far shallower than the gloves at equal effective delta
   (+6 -> 1.187 vs ~2.4; +7 -> 1.339), and rescaling by ln(cap) does
   not reconcile them.  Rising shapes are track- and possibly
   item/level-dependent.  There is no universal m(delta) curve;
   CONFIRMED-RUNG INTERPOLATION is the correct architecture, not a
   stopgap.
3. Open for 2168: no plateau rung yet (all four sales are low-delta).
   Two high rungs (il >= ~35) at an identical price ~1174c would prove
   cap x2.0 and flatness on a second track and pin the 2.0-track
   onset.

### SHIPPED: confirmed-rung interpolation (predictor stage 3)

Learned rungs now outrank every cache-derived input in
`Atr_VendorPredict_Get`: same-il rq-variants return the learned price
directly; targets between two rungs interpolate log-linearly; targets
above the top rung extend FLAT only when the two highest rungs agree
(plateau proven); below the bottom rung stays nil (down region
unmapped).  For 2167 this makes every AH listing predictable today:
il16 -> ~158c, anything il33+ -> 848c.  Harness11 case 17.

## HARVEST #4c: the x2.0 cap proven flat (2026-07)

Item 2168 (Foreman's Boots, Armor/Cloth/FEET, q2, template 587c @
il21/rq16, x2.0 track by the brq boundary).  Extra AH copies bought,
vendored, bought back and re-vendored: **8 new sales, 6 tuples, every
tuple now n=2 with identical prices**.

| il | rq | price | n | m vs 587 | log-slope per il |
|----|----|-------|---|----------|------------------|
| 15 | 13 | 224   | 2 | 0.3816   | (down region)    |
| 19 | 17 | 587   | 2 | 1.0000   | -                |
| 25 | 22 | 697   | 2 | 1.1874   | 0.0286           |
| 26 | 23 | 786   | 2 | 1.3390   | **0.1202**       |
| 33 | 30 | 1175  | 2 | 2.0017   | 0.0574           |
| 38 | 34 | 1175  | 2 | 2.0017   | 0.0000           |

### Findings

1. **The x2.0 cap is FLAT.**  il33 and il38 both return 1175c, each
   confirmed twice.  Plateau flatness is now measured directly on a
   SECOND track, not inferred - the x7.5 track showed it first (2167,
   il33 = il42 = 848c).  Treat flat-above-cap as established for all
   tracks.
2. **The cap value pins 2168's true base at ~587.4c.**  (Harvest #5b
   settles the mechanism as `round`, not `floor` - see there.)  1175 = 2 x 587.5
   exactly, and the il19 rung returns 587 = floor(587.5).  This is the
   cleanest confirmation of finding 6 yet: the cached `bp` is the
   FLOORED value of a float server base, which is why "x2" prices keep
   coming out odd (967 = 2x483+1, 6559 = 2x3279+1, and now
   1175 = 2x587+1).
   - Consequence for the predictor: `floor(bp x m + 0.5)` returns 1174
     here, 1c low.  NOT worth changing - the fractional part is
     per-item, not a constant 0.5 (2167's true base is ~113.07-113.2,
     since 7.5 x 113 = 847.5 but the cap is 848).  A confirmed `obs`
     value outranks the arithmetic anyway.
3. **Plateau onset bracketed to (+7, +14] effective delta.**  Still
   rising at il26 (m 1.339), capped by il33; effective base il19.  In
   *cached* terms (bil21) the cap is reached by delta +12, versus the
   shipped 2.0-track gate of >= 15 - see the gate demotion above.  The
   x2.0 track therefore saturates EARLIER in delta than the x7.5 track,
   which is what a lower cap on a similar rising shape would do.
4. **NEW - the rising curve is not smooth.**  Per-il log slope goes
   0.0286 (il19->25), **0.1202** (il25->26), 0.0574 (il26->33): a step
   between il25 and il26.  Compare 2167, whose slope declined
   monotonically and smoothly (0.150 -> 0.123 -> 0.108 -> 0.080 ->
   0.070 -> flat).  Both 2168 rungs are confirmed twice in two
   independent sessions, so this is not noise and not cross-attribution
   (a swap would make the ladder non-monotone, which it is not).
   - Working hypothesis: the server prices from the instance's actual
     rolled stat allocation, which is integer-quantized, so a single
     item level can tip a stat over a whole point and step the price.
     Unfalsifiable from the addon side - stat allocation per instance is
     not readable - so record it and move on.
   - Practical consequence: log-linear interpolation is an
     APPROXIMATION in the rising region, exact only at rungs and above
     the cap.
5. **Leave-one-out accuracy of the shipped interpolator** on this
   ladder (each rung predicted from the others):

       il15   actual  224   -- no prediction (below bottom rung)
       il19   actual  587   pred  353   -39.9%   [interp 15-25]
       il25   actual  697   pred  754    +8.2%   [interp 19-26]
       il26   actual  786   pred  744    -5.3%   [interp 25-33]
       il33   actual 1175   pred  994   -15.4%   [interp 26-38]
       il38   actual 1175   -- no prediction

   The two big misses are artifacts of deleting the rung that defines a
   knee (il19 is the effective base; il33 is the cap).  With the full
   ladder in hand neither gap exists.  The honest error bar for
   interpolation ACROSS A SMOOTH SPAN is the il25/il26 pair: **~5-8%**.
   Above the cap it is exact.
6. **Determinism reconfirmed at scale**: 6 tuples x 2 sales, across two
   sessions, zero disagreement.
7. **The tuple-exact confirmation fix is VALIDATED LIVE.**  This was an
   8-sale same-name spree spanning 6 distinct tuples - precisely the
   scenario that crossed in case study #5 - and every price landed
   monotone in il and matched its re-sale twin.  Previously this was
   only harness-verified (harness11 case 16).

### Coverage delivered for 2168

Every AH listing of this item is now priced, exactly or by
interpolation:

    il15        224c  (confirmed)
    il16-18     285 / 363 / 461c  (interpolated)
    il19        587c  (confirmed)
    il20-24     604 / 622 / 640 / 658 / 677c  (interpolated)
    il25        697c  (confirmed)
    il26        786c  (confirmed)
    il27-32     832 / 882 / 934 / 989 / 1047 / 1109c  (interpolated)
    il33        1175c (confirmed)
    il34-37     1175c (interpolated across the flat top)
    il38        1175c (confirmed)
    il39+       1175c (flat plateau)
    il14 and below: unknown by design (down region unmapped)

### Convergence bands strengthened (incidental)

Same file, unrelated sales:

| il/rq  | price | items |
|--------|-------|-------|
| 48/44  | 3333c | 14214, 15151, 7423, 7476, 9852 (**five**) |
| 50/46  | 3487c | 14225, 15595 |
| 45/41  | 2872c | 6790, 6794 |
| 44/40  | 1359c | 9698, 15690 |

The il48 band spans cloth, leather AND mail across four slots
(FEET/LEGS/ROBE/WAIST), and the il44 band pairs a NECK with a HAND.
3333/2 = 1666.5 matches none of the five recorded bps, so under the
multiplier model all five share a true base of ~1666.5c and every one of
those recorded bps is cache junk.  **Convergence bands cross armor
subclass and slot** - band-uniform repricing is a level-band property,
not a slot property.  Counterexamples in the same file (1659 cloth HAND
il48 -> 3962c; 2065746 custom WAIST il48 -> 4780c) show the bands are
clusters, not a universal level->price function.

### HARVEST #5a: item 14573 - the x2.0 cap flat on a second item (2026-07)

Four AH variants of 14573 Bristlebark Amice (Armor/Leather/SHOULDER, q2,
cached template il27/rq22, bp 1611) bought and vendored in one session,
joining the pre-existing il52 rung:

| il | rq | price | m vs base | effective delta |
|----|----|-------|-----------|-----------------|
| 26 | 23 | 1611  | 1.0000    | +0  (THE BASE)  |
| 32 | 29 | 1683  | 1.0447    | +6              |
| 47 | 43 | 3223  | 2.0006    | +21             |
| 52 | 48 | 3223  | 2.0006    | +26             |

1. **The x2.0 cap is FLAT on a second item.**  il47 = il52 = 3223.
   Previously only 2168 proved 2.0-flatness; with 2167 on the 7.5 track
   that is three flat plateaus across two tracks.  Treat flat-above-cap
   as settled.
2. **The float-base signature repeats exactly.**  3223 = 2 x 1611.5
   against a cached bp of 1611; 1175 = 2 x 587.5 against 587.  Cached bp
   is the FLOOR of a fractional server base on two independent items.
3. **Effective base pinned at il26 - one below the template il27.**
   Offsets now measured on three items: -1 (amice), -2 (boots),
   -6 (gloves).  No pattern yet, but every offset is NEGATIVE and small-
   to-moderate, which is what makes the template a usable down-scale
   floor (see the ranker fix below).
4. **THE UNIVERSAL CURVE IS DEAD WITHIN A SINGLE TRACK.**  Harvest #4b
   killed it by comparing across tracks; this kills it inside one:

       delta +6 :  14573 -> x1.0447      2168 -> x1.1874
       cap by   :  14573 delta <= +21    2168 delta <= +14

   Both are x2.0-track quality-2 armor.  They rise at different rates and
   saturate at different deltas.  Confirmed-rung interpolation is not a
   stopgap; it is the only architecture that can work.
5. Also recorded: 14157 Pagan Mantle il17/rq15 -> 184c against cached
   bil24/bp145, i.e. m = 1.269 ABOVE the cached base despite il17 being
   seven BELOW the template.  Same effective-base illusion as 2167's
   il17/il18 rows.  One rung so far.

**NEGATIVE RESULT - no down-scale data was gained.**  All three purchases
were chosen because they sat below the item's only confirmed rung
(il52/rq48).  They landed at (il26) or above (il32, il47) the effective
base.  The down region still holds four points.  This mis-targeting is
what motivated the floor fix below.

### FIXED: the down-scale floor (2026-07)

The ranker flagged a level as down-region when it sat below the lowest
CONFIRMED RUNG.  That is wrong whenever the only rung is a high one, and
it cost real gold on 14573.

The cached template (`brq`) is the better floor: every measured effective
base sits just BELOW its template (-1, -2, -6), never above.  The floor is
now `min(lowest confirmed rung, cached template req)`, with either input
sufficient on its own - an item with NO rungs can still expose a
below-template listing, which is exactly the data the down region wants.
The ledger records `brq`/`bil` at absorb time from the scan record.
Harness24 section 8, including the 14573 scenario as a regression.

**Consequence for shopping**: to buy down-region data, look for listings
whose required level is below the item's cached template - the Finder's
iLvl/Lvl columns show both, so it is visible while browsing.

### HARVEST #5b: item 4661 - the eight-rung ladder (2026-07)

4661 Bright Mantle (Armor/Cloth/SHOULDER, q2, cached template il26/rq21,
bp 1162), eight AH variants bought and vendored in ONE session.  The
purchase set was chosen deliberately: two ADJACENT PAIRS (il27/il28 and
il52/il53) to test the 2168 kink, plus the lowest listing available.

| il | rq | price | m | slope/il |
|----|----|-------|--------|----------|
| 19 | 17 |  405  | 0.3485 | -        |
| 22 | 20 |  495  | 0.4260 | 0.0669   |
| 27 | 24 | 1162  | 1.0000 | 0.1707   |
| 28 | 25 | 1162  | 1.0000 | **0.0000** |
| 36 | 32 | 1798  | 1.5473 | 0.0546   |
| 41 | 37 | 2126  | 1.8296 | 0.0335   |
| 52 | 48 | 2323  | 1.9991 | 0.0081   |
| 53 | 49 | 2323  | 1.9991 | **0.0000** |

1. **THE PRICE IS A STAIRCASE IN il, NOT A CURVE.**  Both adjacent pairs
   are FLAT - one item level with no price change at all - while 2168
   jumped 12.8% across the single step il25 -> il26.  Treads and risers
   in the same function.  This retires the "smooth rising curve" model
   entirely and explains harvest #4c's unexplained 2168 kink: it was a
   riser, not an anomaly.  Log-linear interpolation between rungs remains
   the right ARCHITECTURE but is explicitly an approximation over steps.
2. **TWO GENUINE DOWN-SCALE POINTS - the first since harvest #4b.**
   il22 -> x0.4260 (delta -5) and il19 -> x0.3485 (delta -8), monotone
   within the item.  The whole down dataset is now:

       2167  delta -1  x0.8938
       2168  delta -4  x0.3816
       4661  delta -5  x0.4260
       4661  delta -8  x0.3485

   Note boots at -4 (0.3816) price BELOW mantle at -5 (0.4260): a deeper
   cut with a higher multiplier.  Down-scaling is item-dependent too, and
   is NOT the mirror of the rise (up +9 -> 1.547 vs down -8 -> 0.349).
3. **The base is a SHELF, not a point.**  il27 and il28 both return
   exactly the cached bp (1162), and the cache's own il26 sighting is
   1162 as well - m = 1.0 across at least three item levels.  This
   retroactively explains every harvest 1-3 "x1.0 at small delta" row.
4. **The x2.0 cap is flat on a THIRD item** (il52 = il53 = 2323), the
   fourth flat plateau overall across two tracks.
5. **THE ROUNDING MODEL IS SETTLED: p = round(base x m), cached bp =
   round(base).**  Harvests #4c/#5a proposed floor(); 4661 rules it out
   (floor(1161.5) = 1161, but the cache holds 1162).  Rounding fits all
   three items:

       2168   bp  587  cap 1175  -> true base in [587.25, 587.50)
       14573  bp 1611  cap 3223  -> true base in [1611.25, 1611.50)
       4661   bp 1162  cap 2323  -> true base in [1161.50, 1161.75)

6. **Cap onset varies by more than 10 deltas on one track** (all brq >= 16,
   all x2.0): 2168 capped by +14, 14573 by +21, 4661 by +25 and still
   rising at +14 where 2168 had already saturated.  There is no track-wide
   onset; the harvest-3 gates remain a last-resort fallback only.

### SHIPPED: stage-4 cross-item shape estimate (2026-07)

Every earlier stage needs the item's OWN data (a confirmed rung, a trusted
base fact, a cache sighting).  With none of those, the tooltip used to say
"unknown (scaled)".  Stage 4 answers instead, using the shape the four
measured ladders share.

Model: normalised saturation `s = ln(m) / ln(cap)` against the cached
template il, so `m = cap^s`, with the track cap from the existing brq/class
rules.  Shipped shape (median s within +/-3 of each knot, all four ladders):

    delta   +1     +2     +4     +6     +8    +11    +14
    s      0.124  0.155  0.248  0.334  0.630  0.965  1.000

    delta 0..+2   -> m = 1.0   (the base is a SHELF - 4661 il26/27/28)
    delta <= -4   -> m = 0.40  (n=3: x0.3485 / 0.3816 / 0.4260)
    delta -1..-3  -> nil, genuinely unmapped (one point, x0.894 at -1)

**MEASURED ACCURACY.**  Leave-one-ITEM-out over 17 confirmed rungs - each
ladder predicted from only the other three, using the same untrusted cached
inputs the live addon has:

    median error   8.3%
    within 25%     15/17
    within 50%     17/17
    worst          41.8%  (2167, whose cached template is known polluted)

    excluding 2167:  median 9.0%, worst 28.2%, 12/13 within 25%

For comparison, on the same held-out points: "assume capped" scores median
12.2% but worst 360%; "geometric mid" 29.3%; "assume base" 50.0%.

**TIERING IN THE TOOLTIP** - four levels, visually distinct, strongest first:

    123c *          confirmed sale of this exact variant
    123c            interpolated between this item's confirmed rungs
    Predicted 123c  gated plateau rule from cache/base inputs
    ~123c (est)     stage-4 shared shape - THIS TIER

Only the -1..-3 down band still renders "unknown (scaled)".

CAVEATS: n = 4 ladders; the shape will move as more are measured.  The
inputs remain the untrustworthy cached bp/bil, and 2167 shows what cache
pollution costs.  The x0.40 down constant rests on three points.

### LIVE BACKTEST + calibration recorder (2026-07)

205 recorded sales replayed against the shipped stage-4 estimator, using each
log row's own sale-time `bp`/`bil`/`brq` snapshot - a faithful replay of what
the estimator would have seen.  13 pre-`brq` rows excluded (they fall back to
the wrong track and measure a backtest artifact, not shipped behaviour).

    ALL rows            n=176  median 4.1%   <=25%: 79%   <=50%: 86%
    OUT-OF-SAMPLE       n=128  median 4.1%   <=25%: 76%   <=50%: 86%
      up-scale          n=147  median 2.4%   <=25%: 81%
      base shelf        n= 11  median 0.0%   <=25%: 82%
      down (<= -4)      n= 18  median 6.1%   <=25%: 61%

Better than the n=17 leave-one-out predicted (8.3%), and the out-of-sample
rows score IDENTICALLY to the fitted ones - the shape is not overfitted.

**FAULT 1 - the track rule is incomplete.**  Every worst miss was off by
almost exactly 7.5/2.0 = 3.75.  **19 of 156 rows with brq > 15 priced above
2.6x, up to 7.51x** (id2221 at 7.51 with brq 23; id6790 at 6.99 with brq 30).
Nothing observable separates them: all Armor, spread across cloth/leather/
mail/shields and every slot, almost all quality 2.  The harvest-3 brq 15/16
boundary is real but does not capture everything.

FIX - stop guessing the rule, remember the evidence.  `db.trk[itemID]` holds
the highest `p/bp` ratio ever confirmed for an item and becomes a FLOOR on its
cap, so ONE sale above the assigned cap corrects that item permanently.
Clamped at 7.5: no higher cap has ever been observed, so a larger ratio means
the BASE was wrong, not the cap.  (That clamp exists because harness11's
contested-base case caught the flaw - a ratio of 18.75 recorded against one
bp, then applied to a different one, over-predicted by 2.5x.)  A ratio LOWER
than the rule track never lowers it.

**FAULT 2 - negative delta is not the same as below base.**  7 of 19 rows at
delta <= -4 from the CACHED bil had multipliers above 0.7 (id14157 at 1.269
while 7 levels "below" its cache).  Refitting the negative bands on live data:

    delta -3..-1   x1.00   16 rows, median error 0.0%   <- the shelf extends DOWN
    delta <= -4    x0.42    9 rows, median error 1.4%

So the "-1..-3 unmapped band" was never unmapped - it is the base shelf, and
it was the only case still rendering "unknown (scaled)".  That tier is now
empty.  Below about -7 the cached bil is too far from the effective base for
any constant (the band is bimodal: ~0.35-0.41 where the cache sits near the
template, ~0.89-1.27 where it sits well above); estimates are still offered
there and are the weakest thing the predictor returns.

**CALIBRATION RECORDER.**  Every scaled sale now stores what the predictor
would have said BEFORE the observation is written, plus which tier answered:

    smp.pp  predicted price      smp.pt  "learned" | "interp" | "plateau" | "est" | "none"

Taken pre-write, so on a first sale of a tuple stage 1 cannot see it and the
answer is genuinely out-of-sample; `pt` lets repeat sales be excluded from
accuracy stats.  Every vendor trip is now a free calibration point, and the
next backtest can be run per-tier instead of in aggregate.

## Base facts status (after harvest #4c)

Current DB (the post-harvest-#4 file; the harvest #1-3 dataset lives in
the user's backup of the previous SavedVariables):

    .obs   35 tuples      .log   42 rows
    .base  11 records     .cb   146 items sighted
    log rows carrying `tb`:  0 of 42

The `.base` table still has **zero overlap** with any scaled-sale
itemID, so not a single log row carries `tb`.  The bootstrap-first step
of the harvest #3 protocol has now failed to happen three harvests
running; the measurement problem stands unbroken.  (Mechanism itself
verified: capture, majority vote, and tb snapshotting all covered by
harness11 cases 7-7e.)

It matters less than it did.  Rung interpolation does not consume `tb`
at all - it needs only confirmed sales - so `.base` is now wanted for
ONE purpose: testing the band-uniform-pricing claim (finding 7) by
putting a trusted base next to a convergence-band resale.  Everything
else it used to serve is better served by selling the item once.

## Harvest #4 protocol (what makes the next dataset decisive)

1. **The same-item il LADDER** (extend the gold experiment): ONE itemID
   sold at 4-6 different ilvls maps m(delta) directly with zero
   per-item confounds.  THE DECISIVE SET IS IN HAND: item 2167 with
   trusted base (113c @ il20/rq15) and owned copies at delta -7, -3,
   -2, +6, +13 (+ cheap AH listings at +11 and more).  One vendor trip
   pins the down-scale multiplier with three points AND the rising
   curve at two - exactly the regions forcing every current
   "unknown (scaled)".  Before selling: hover each copy AT the
   merchant and screenshot the Sell Price money line once (the
   merchant-tooltip experiment above) - then sell, /reload, and upload
   the account-level SavedVariables for fitting.  STATUS: executed
   2026-07; produced the case-study-#5 ladder AND exposed the
   confirmation race.  COMPLETED as harvest #4 (see above): clean
   7-rung ladder, flat plateau proven, effective base ~il14 vs template
   il20.  Harvest #4b (boots + custom wrist) then killed the
   universal-curve hope.  Ladder experiment (a) - two HIGH rungs of
   2168 to prove the x2.0 cap flat and pin its onset - **COMPLETED as
   harvest #4c**.  Remaining: (b) a custom-range ladder (x2.5 cap - the
   1616xxx accessories are ideal: cheap, provably band-priced); (c)
   more down rungs to map the down-curve (-1 -> 0.894, -4 -> 0.382,
   -4 -> 0.382 confirmed twice so far); (d) instances AT template
   tuples across several items, to probe what sets the per-item
   effective-base offset (-6 gloves, -2 boots).  See the harvest #5
   protocol below for what is actually worth buying.
2. **Bootstrap base facts for the convergence items specifically**
   (7468/7469/7488/7534/9910; 14158/14176/6757; 6596/15556/15582): sell
   an unscaled copy first, then scaled ones - the tb columns directly
   test band-uniform base pricing.
3. Harden the track rules: a melee weapon at brq <= 15 sold scaled (rule
   says x2.0), a stock ranged at brq 16-18, and another custom ranged
   (does the crossbow exception hold?).
4. More down-scales, ideally of base-fact items, to quantize the
   down-multiplier and find the x1.0/x0.4 boundary.
5. Volume still beats selection: everything scaled that hits a merchant
   is logged automatically, and every prediction can now be scored
   against the confirmed price on sale.

## Harvest #5 protocol: what is still worth buying (and what is not)

**The expensive phase is over.**  Ladders existed to establish the SHAPE
of the pricing function.  That job is done: the shape is per-item, not
universal (#4b), not always smooth (#4c), and flat above a track cap
(#4, #4c).  No further ladder can change the architecture; the shipped
answer is confirmed-rung interpolation, and rung interpolation improves
with BREADTH (one or two rungs on many items) far faster than with
DEPTH (many rungs on one item).

### Cost model - read this before planning a shopping trip

- **Nothing here requires equipping an item.**  The learning hook fires
  on `UseContainerItem` - selling from the BAG - and reads the server
  tooltip of the bag item and of the buyback entry.  Required level,
  armour proficiency, class/skill training and character level are all
  irrelevant to every experiment in this document.  Do not train
  anything or wait for max level on account of vendor-price research.
- **The vendor loop is net-zero gold.**  A buyback costs exactly what
  the vendor paid, so sell -> buy back -> sell again is free, and it is
  how every n=2 in the dataset was produced.  Re-selling an item you
  already own costs nothing but time.
- **The only real cost is the AH price of variants you do not own yet**,
  and the useful ones are cheap low-level greens.  There is no need to
  buy expensive items: an il26 pair of boots teaches exactly as much as
  an il26 epic and costs a fraction.
- **Two hard operational limits when doing a spree:**
  - the buyback list holds **12 entries**; sell a 13th and the oldest is
    gone for good, so buy back before the list fills;
  - the confirmation sweep reads the newest **~8** buyback slots, so
    **keep batches to 8 sales or fewer** and let each confirm before
    continuing.  Both ladders were produced this way.

### Priority order for any future sale

1. **FREE, PASSIVE, ALWAYS ON - vendor your junk.**  Every scaled item
   that hits a merchant is logged automatically with its confirmed
   price.  This is the highest-value activity per unit of effort and it
   costs nothing.  Volume still beats selection.
2. **CHEAP AND OPPORTUNISTIC - buy unmapped ilvls of items already in
   `.obs`.**  Now automated: run a category scan and `/atrtarget`.  Not a campaign; just check whether a listing's verified il
   sits in a gap when one happens to be cheap.  For 2168 the open
   questions are il27-32 (an il29 or il30 splits the (26,33] onset gap),
   il21 (the `.cb` map holds a server-AGREED sighting of 587c there - a
   sale confirming 587 would prove a flat shelf il19-il21 and directly
   probe the effective-base offset), and il24 (tests the il25/il26 step
   from the other side).
3. **THE ONLY GENUINELY OPEN SCIENCE - the down region.**  Below an
   item's effective base there are four data points total across the
   whole project (-1 -> 0.894, -4 -> 0.382 twice, plus 2168's il15).
   Every instance below base currently renders "unknown (scaled)" and
   always will until this is mapped.  Any cheap item bought at an il
   BELOW its own base is worth more than any further high-il rung.
4. **A custom-range (id >= 2M) ladder** to confirm the x2.5 cap is flat
   like the other two.  The 1616xxx accessories remain ideal.  Nice to
   have; the cap is already assumed flat by analogy and nothing in the
   UI depends on it.
5. **`.base` bootstrap for a convergence-band item** (7468/7469/7488/
   7534/9910; 14158/14176/6757; or the new il48 -> 3333c five).  Sell an
   UNSCALED copy first, then a scaled one, so the `tb` column lands next
   to a band price.  This is the last outstanding test of finding 7 and
   the only remaining use for `.base`.

### SHIPPED: the research-target ledger (2026-07)

The "buy unmapped variants" advice above was unactionable in practice: AH
listings do not announce which of them are unmapped, and hunting them by
eye across scans was the real bottleneck.  It is now automated.

Every finished Finder scan absorbs its **equippable + scaled** rows into
`AUCTIONATOR_FINDER_RESEARCH` (declared in the main toc, so it persists
without the debug stub addon).  Variants are keyed by `rec.level` - the
`GetAuctionItemInfo("list")` required level, the per-instance truth that
is available on every scanned row WITHOUT running Verify.  `trueIlvl` is
stored when Verify happens to have pinned it, but nothing depends on it.

Per variant the ledger keeps: times seen, cheapest UNIT buyout (stacks
divided; `buyoutPrice == 0` is bid-only and is never recorded as free),
and the verified ilvl if known.  Per item: name, quality, equip slot,
total listings seen, and how many distinct SCANS it appeared in - the
last being the honest measure of "can I buy this again next week".

`Fdr_Research_Targets` ranks the ledger against `AUCTIONATOR_VENDOR_LEARNED.obs`,
which supplies the levels already confirmed:

    unmapped x 10   each unmapped level = one new confirmed rung
    down     x 30   below the lowest confirmed rung: the only unmapped
                    part of the model (priority 3 above)
    rungs>0    25   a second rung unlocks INTERPOLATION across the whole
                    span; a singleton prices one tuple and nothing else
    spread   <=30   how wide a ladder this item can actually supply
    scans*4  <=20   recurring availability
    score = value / (1 + cheapest unmapped buyout in gold)

The weights are crude and readable rather than fitted, and every
component is printed, so a bad ranking can be diagnosed instead of
guessed at.  An item whose only remaining unmapped levels are bid-only
drops off the list entirely - there is nothing to tell the user to buy.

Output: **`/atrtarget [n] [level]`** opens a **copy window** with the ranked
shopping list (item, id, score, unmapped-of-total, existing rungs, and the
exact required levels to buy with their cheapest seen price; `!` marks
down-region levels).  The window is a plain, pre-selected multiline EditBox -
press Ctrl+C immediately, or click **Copy to clipboard** (native
`CopyToClipboard`, present on this client).  Chat gets a one-line receipt only;
where there is no real UI (a headless client or the test harness) the full
report falls back to chat line by line.  The Finder's old dead **Debug** checkbox is
relabelled **Research** and now writes the ranked report alongside the
raw scan rows into `AUCTIONATOR_FINDER_DEBUG`, making the stub addon the
upload channel.  The ledger itself is always collected; the checkbox
only controls the upload file.  Harness24.

### SHIPPED: level-band relevance (2026-07)

The value/gold ranking above answers "most research per gold", which floats
cheap low-level ladders to the top.  That is the wrong shopping list for the
common case: a player - levelling or at max - who just wants the vendor
ESTIMATE to be right for the gear they actually see at their CURRENT level.
The live calibration data made the cost of this concrete - replayed against
the shipped estimator, out-of-sample error rises sharply with level because
the high-level population lands almost entirely in the stage-4 `est` tier
(no confirmed rungs of its own; rung interpolation fired zero times), and
`est` is weakest in exactly the rising-curve and down regions a high-level
character keeps hitting:

    by required level (proxy for character level):  rq40-49 median  6%
                                                     rq50-59 median 21%
    tier mix of recent sales:  est 74% (median ~19%),  interp 0%

So the fix is not more model - it is aiming the existing shopping list at the
band the player is in, so the items they browse gain their own rungs (`est`
-> `interp`).  `Fdr_Research_Targets (limit, anchor)` now takes an anchor
level; `/atrtarget` supplies the character level by default (`UnitLevel`), or
an explicit `/atrtarget <n> <level>` override for aiming elsewhere.  Two crude,
readable, printed additions to the ranking, applied only when an anchor is set
(the offline dump passes none, so the uploaded ledger stays a full unbiased
view):

    band window   [anchor-8, anchor+4]   gear at/just below you, plus next upgrades
    in-band first PRIMARY sort key        a target with a buyable variant in the
                                          window always outranks one without
    inBand x 12   value bonus per unmapped level inside the window
    cost          = cheapest unmapped buyout INSIDE the window (what you would
                    actually spend), falling back to overall cheapest
    relevance     score x (1 - dist/25, floored at 0.25) for the out-of-band
                    tail, so nearer targets edge out farther ones

The estimator model itself is untouched - this is ranking only, so there is no
accuracy regression risk.  Verified by a focused harness that loads the real
file and asserts: no-anchor ranking is byte-for-byte the old behaviour; an
anchor promotes in-band targets above cheap out-of-band ladders; a max-level
anchor pulls high gear in-band; and the `/atrtarget <n> <level>` override
retargets the band.  (The documented harness suite is not committed to this
repo; the check lives with the change.)

### Live finding: the wildcard-scan lesson, and bid-only listings (2026-07)

The first wildcard scan (2500 rows) produced a blunt lesson and one real
market fact.

*Lesson*: a wildcard scan is the wrong instrument.  Only **66 of 2500
rows were equippable (2.6%)** - 13 distinct itemIDs, five of them ammo
(`IsEquippableItem` is true for ammo, bags and quivers; the ledger now
excludes those slots outright).  The whole 50-page cap was spent on
fish, cloth and bandages.  Scan BY CATEGORY: Armor -> Cloth -> FEET is
about 4 pages and every row is a candidate.  Do not raise
`FDR_MAX_PAGES`; deep paging fights the unstable server sort
(ASCENSION-CLIENT-NOTES) and partitioning by class/subclass/invType is
both reliable and gentler on the server.

*Fact*: of the 8 scaled listings in that sample, **7 had no buyout at
all**, while 58 of 66 equippable rows overall did.  Sellers list scaled
gear bid-only because nobody knows what a scaled variant is worth -
which is precisely the gap this addon exists to close.  The ranker's
original "must have a buyout" rule therefore discarded nearly the whole
research population.  Fixed: the ledger now records a bid cost
(`v.mb` - the current bid plus one increment when contested, else the
opening bid), the ranker falls back to it when no buyout exists, and
such targets are flagged and scored x0.6 because a bid must be waited
out and can be lost.

**CORRECTION (first category sweep):** the bid-only rate does NOT
generalise.  Across 158 items from a category scan, **every one had a
buyout** and the fallback fired zero times.  The 7-of-8 figure came from
an n=8 wildcard sample dominated by whatever the first 50 pages happened
to hold.  The fallback is still correct to keep - bid-only listings are
real and were genuinely being discarded - but it is not load-bearing on
the gear population, and the original finding was over-generalised.

### SHIPPED: price-database feed (2026-07)

Category sweeps are long, and there is no reason for Auctionator's own
price data not to benefit - especially as upstream's Full Scan is dead
here (it calls `QueryAuctionItems` with `getAll=true`, which Ascension
disables; the paged "slow scan" alternative was scaffolded but never
written, and is additionally broken by a shadowed local and an empty
continuation block).

Each scan now feeds `gAtr_ScanDB` / `gAtr_MeanDB` directly - both are
created by `Atr_InitScanDB` at login, so no new plumbing.  Four rules
make a PARTIAL scan safe where upstream assumed a whole-AH pass:

1. **Never delete.**  Upstream prunes names below the quality floor
   because it saw everything; for us a missing name means "not
   scanned".  Insert and update only.
2. **Skip scaled equipment.**  The DB is name-keyed - one price would
   stand in for every scaled variant.  Commodities never scale, so
   nothing of value is lost.
3. **Skip a capped scan.**  A truncated slice gives the lowest of an
   arbitrary subset, biased HIGH; it would quietly inflate prices.
4. **Bid-only rows contribute nothing** (never a zero price).

Toggle: the "Prices" checkbox (default ON,
`AUCTIONATOR_FINDER_SETTINGS.feedPriceDB`).  `AUCTIONATOR_LAST_SCAN_TIME`
is refreshed, which is display-only - the real gate is
`CanSendAuctionQuery`.  Harness24 sections 7.

### First category sweep: the yield, and the shopping list it produced (2026-07)

The wildcard-vs-category comparison is decisive and should settle how every
future sweep is run:

| | wildcard (blank search) | 3 categories selected |
|---|---|---|
| rows harvested | 2500 (cap hit) | 1008 (no cap) |
| equipment share | **2.6%** | ~100% |
| items in the ledger | 6 | **158** |
| items with 2+ required levels | 1 | **111** |
| price DB | untouched | 667 names (5 new, 202 updated) |

**Scan by category. Never wildcard.**  The cap is not the problem - the
composition is: a blank search spends the entire 50-page budget on fish,
cloth and bandages.

The ledger's first real ranking then produced three baskets, all trivially
cheap because the research population is low-level greens:

1. **THE DOWN REGION - 4.88 gold for 8 data points.**  (SUPERSEDED by
   harvest #5a: these were selected with the OLD down heuristic and were
   not below base at all.  Re-derive with the fixed floor.)  The down curve is
   the only unmapped part of the model and the whole project holds four
   points at two deltas (-1, -4).  Available now:
   - 14573 Bristlebark Amice (rung il52/rq48): rq22, 23, 29, 43
   - 9850 Conjurer's Mantle (rung il47/rq43): rq35, 39, 42
   - 4737 Imperial Leather Spaulders (rung il48/rq44): rq39

   Spanning deltas about -1, -4, -5, -5, -8, -19, -25, -26 - shallow
   through deep in one trip.
2. **CHEAPEST SECOND RUNGS - 4.40 gold for 10 newly interpolable items.**
   14157 Pagan Mantle is the extreme case: rq15 and rq19 both at 2s17c, so
   roughly 4 SILVER buys a 2-rung item.
3. **A COMPLETE LADDER FOR 3.47 GOLD**: 4661 Bright Mantle, **9 distinct
   levels rq17-rq49**.  Comparable in span to the 2167 and 2168 ladders,
   which took the whole project to assemble.  Backup: 4718 Nightsky Mantle,
   9 levels, 6.22g.

CAVEAT ON THE `!` (down) FLAG: it marks levels below the item's lowest
CONFIRMED RUNG, which is a proxy, not proof.  The pricing base is the
item's EFFECTIVE base, which sits below its template (-6 gloves, -2
boots).  Deep candidates (Bristlebark rq22 against a rq48 rung) are almost
certainly true down-scales; shallow ones (Conjurer's rq42 against rq43)
may land at or just above the effective base - which is itself worth
knowing, because it pins the offset (protocol item 4d).

Also observed: only 3 of 158 ledger items overlapped the 139 confirmed
tuples, so nearly every target reported "0 confirmed rungs".  Expected -
the vendor DB was built by vendoring bag junk while the ledger is built by
scanning shoulders.  The two populations converge only as scanned items
get sold.

### What NOT to do

- Do not build another 6-rung ladder on a stock armor item.  Two exist;
  they disagree in shape; a third cannot reconcile them.
- Do not spend gold on high-value items to get "better" data.  Price
  magnitude carries no information the multiplier does not.
- Do not try to fit the delta gates more finely.  They are a fallback
  for items with zero sales; the fix for a wrong prediction is one
  confirmed sale, not a better gate.

## Infrastructure notes

- Learning/announce/predict pipeline: AuctionatorHints.lua, FINDER_TAB
  block "vendor price learning".  Data: SavedVariables
  AUCTIONATOR_VENDOR_LEARNED (.obs = lookup shown in tooltips with '*',
  .log = raw samples, cap 500, .base = trusted base facts from unscaled
  sales).  Prediction: Atr_VendorPredict_Get (same block), shown as
  "Predicted vendor" - only for scaled variants with no learned price.
- Log fields since harvest #2: id, il, rq, bil, brq, bp, qual, cls, sub,
  slot, p, q.  Since harvest #3: + tb, tbi, tbr, tbn when base facts
  exist.
- Upload for analysis: ACCOUNT-level WTF/Account/<acct>/SavedVariables/
  Auctionator-Finder-Ascension.lua (not the realm/char file of the same name),
  or just the AUCTIONATOR_VENDOR_LEARNED block from it.
