# Finder Module Architecture (AuctionatorFinder.lua)

Single self-contained file; all frames built in Lua inside
`Atr_Finder_Init()` (called from Auctionator's `Atr_Init` at first AH open,
after `Atr_AddMainPanel`). Globals are prefixed `Atr_Finder_*`; file-local
state is `gFdr_*` / `gFdrBuy_*`.

## Scan engine
- Spec queue: category selections compile to a list of server query specs
  `{class, subclass, autoAccept, label}` via `Fdr_BuildSpecQueue`; each spec
  is paged 0..N (50/page) with `CanSendAuctionQuery` gating, 0.25s OnUpdate
  throttle, per-page timeout, `AtrQuery` duplicate-page detection with
  consecutive-retry logic (4 retries then SKIP the page and continue —
  never abort the whole scan), and a >25-page confirmation dialog
  (`FDR_WARN_PAGES`, suppressible via persisted "No Warn"/ignore setting).
- **There is NO fixed page cap** (2026-07). `FDR_MAX_PAGES` is 0; a scan
  runs until the server serves a short page, which is the real end of the
  result set. The old value of 50 truncated every large category at exactly
  2500 rows — and because rule 3 below discards a capped scan, the sweeps
  most worth having were the ones thrown away. Trade Goods alone is 746
  pages / 37k rows on this realm.
  What replaces it is a **runaway guard**, not a quota: "run until a short
  page" does not terminate on its own here, because the duplicate-page path
  advances `gFdr_Page` after 4 failed retries, so a server that keeps
  re-serving one full page would loop forever. `Fdr_PageCeiling()` derives
  the stop from the server's OWN reported total (page 0's
  `GetNumAuctionItems`) plus `FDR_PAGE_SLACK` (25) for pages the dup path
  skips past, falling back to `FDR_RUNAWAY_PAGES` (2000) when no usable
  total is reported. Setting `FDR_MAX_PAGES > 0` restores a hard limit.
  `gFdr_CapHit` therefore now means "the server served past its own
  reported total", a genuine anomaly, not "you asked for too much".
- **Retries back off exponentially.** A "duplicate" page is usually just the
  server not having delivered the new one yet. Re-firing on the next 0.25s
  tick spent all four attempts inside a SECOND and then skipped the page —
  50 listings lost, silently. `gFdr_RetryHold` now waits 2^(n-1) ticks
  (0.25 / 0.5 / 1 / 2s, ~3.75s total). Retry 1 keeps its one-tick delay on
  purpose: it is the attempt that usually succeeds, so slowing it would tax
  every page to fix a rare case. The hold is only ever set after a duplicate
  is actually seen, so a clean scan pays nothing.
- **The status line is a heartbeat, not a page counter.**
  `Fdr_ScanProgressLabel` is rebuilt on EVERY OnUpdate tick, not only on a
  page advance — waiting on the throttle is the longest part of a big sweep
  and used to show nothing at all, making a working scan indistinguishable
  from a hung one. It carries page N / M, a live listing count, the retry
  number, a red live **skipped-page** count (a skip is 50 listings lost for
  good and must not hide until the summary), and a seconds counter derived
  from `gFdr_WaitTicks` — ticks, not `time()`, since the label is rebuilt
  every frame and the tick rate is already a fixed 0.25s. The counter resets
  on every real page advance, so a rising number means genuinely stuck.
  `FDR_PAUSED` returns "waiting for confirmation" instead: nothing but a
  click drives that state, so it must never read like work in progress.
- `autoAccept=true` marks records whose spec's server filter already
  guarantees a selected category; others are checked client-side.
- **Armor slot selections push down to the server** when a material is also
  chosen: `Fdr_SlotSpecTypes` resolves each selected slot to an inventory
  type index via `Fdr_InvTypeMap` (token lookup into
  `GetAuctionInvTypes`, memoized per class/subclass, never memoized on a
  failed probe) and emits one spec per (material x slot). "Leather + Head"
  is one small query instead of scanning all leather. Constraints, all
  driven by ASCENSION-CLIENT-NOTES:
  * `autoAccept` stays **false** - the client-side equipLoc check remains
    as a net against a wrong index, so a server that ignored the parameter
    would behave exactly as before the change;
  * if ANY selected slot has no index for that subclass (INVTYPE_CLOAK),
    the whole material falls back to one unfiltered scan - a partial
    server filter would drop rows that the client can never recover;
  * Chest stays one spec: the server folds INVTYPE_ROBE into CHEST;
  * armor-with-no-material + slots is unchanged (one armor-wide scan),
    since the inv type index is only meaningful under a subclass.
- Harvested record fields: name, texture, count, quality, level
  (**the per-instance truth**), minBid, minIncrement, bidAmount,
  buyoutPrice, owner, link, timeLeft, page, autoAccept; enriched later
  with equippable, ilvl, baseReq, itemType/SubType, equipLoc, stats,
  scaled, perItem, and (post-verification) trueDPS/trueIlvl.

## Enrichment & scaled detection (`Fdr_AnalyzeResults`)
- `IsEquippableItem` splits gear from goods. `GetItemInfo` supplies base
  ilvl/reqLevel/type/subtype/equipLoc; `GetItemStats` supplies stats
  (cached per rec).
- Stat dropdown vocabulary: stats present on gear, excluding
  ubiquitous-constant pseudo-stats (≥5 items, all same value — filters
  Ascension's PVE_POWER) and the DPS key (has its own auto column).
- **scaled flag**: rec.level ≠ baseReq, OR listings sharing a normalized
  link disagree on level. Scaled names feed `gFdr_ScaledNames` (session)
  for the global tooltip warning hook.

## Grouping (`Fdr_GearGroupKey`)
- Non-equippable: exact link.
- Equippable: normalized link (fields 8 uniqueId & 9 viewerLevel zeroed;
  extra fields preserved) + quality + ilvl + **required level** + sorted
  full stat fingerprint. Provably merges only true duplicates; splits
  rolls, suffixes, quality tiers, and scaled variants. Group face = the
  cheapest per-item listing; qty column shows total; name gets " xN".
- The face records `groupKey` and `members` (every raw rec in the group).
  Because the face's `count` is the group TOTAL, the face is **not a valid
  buy identity tuple** — buying is only ever done on real member recs (or
  singleton faces, whose count is untouched). Per-instance fields
  (`trueIlvl`/`trueDPS`/`fdrVerified`/`fdrGone`) are stripped from the face
  on copy and re-derived after grouping: the face shows verified values
  only when EVERY member is verified and they agree.

## Filters (all client-side, applied in `Atr_Finder_RebuildDisplay`)
- Category: OR across selections, EXCEPT armor where materials AND slots
  intersect (materials OR'd; slots OR'd; groups ANDed). Slot leaves match
  equipLoc token sets (Chest includes ROBE).
- Stats: multi-select, AND semantics; gear-only when active.
- Level range boxes: read live; enforced against rec.level (the displayed
  value) since the server's params are untrustworthy.
- "My Lvl": rec.level ≤ UnitLevel("player").
- Gear-category autofills (with manual-override memory): min level =
  charLevel−5, Usable checked, My Lvl checked.
- Rebuild recomputes the DPS-column flag (weapons present) and reflows
  columns via `Fdr_PostRebuild` → `Fdr_UpdateDPSColumn`.

## Columns / display
- Dynamic layout builder (`Fdr_BuildLayout`): name absorbs slack; optional
  DPS column; up to 3 stat columns (FDR_MAX_STAT_COLS) for selected stats.
  Row cells keyed in `row.cells`; header sort with per-key asc/desc
  defaults (prices/name asc; ilvl/dps/statN desc).
- Scaled rows: orange Lvl; ilvl/DPS/stat cells DIMMED (base values) until
  verified, then trueIlvl/trueDPS render white and drive sorting.
- 15 rows × 20px, FauxScrollFrame; scrollbar + results backdrop anchored to
  AuctionFrame's right/bottom edges (see client-notes on frame size).

## Group listings window (`Atr_Finder_GroupFrame`)
- Clicking a grouped row with `numListings > 1` opens this window instead
  of the buy dialog (the face's count is the group total, so a direct buy
  on a face could never match a real listing — the old "Listing not found"
  bug). Singleton rows and ungrouped rows go straight to the buy flow.
- The window lists each member on its own line, sorted cheapest per-item
  first (ties by buyout), 10 rows + FauxScrollFrame, lazily built,
  parented to the panel. Columns are dynamic per group
  (`FdrGrp_ApplyLayout`): gear shows Qty | Lvl | [DPS if present] | two
  stat columns | Buyout; goods show Qty | Buyout | Per Item. The stat
  columns (`FdrGrp_TopStats`) are the stats selected in the Stats
  dropdown (in selection order — how Armor can be shown deliberately),
  else the two biggest BASE stats on the item (Sta/Str/Agi/Int/Spi
  whitelist; armor, resistances and PVE/PVP_POWER never appear by
  default). The "Requires level" sub-line only appears for
  gear with level > 0. Note: within one group every listing shares the
  same required level by construction (level is part of the group key).
- **Scaled gear**: opening the window auto-runs an exact-name find on the
  buy channel (`FDRGRP_*` state machine mirroring `FDRBUY_*`: QUERY/WAIT,
  dup-page requery via `AtrQuery`, 8s page timeout, 10-page cap). Each
  page is swept once; every live index verifies at most one member
  (claimed set) matched by the same identity tuple as buying; the member's
  TRUE iLvl/DPS are harvested from its server tooltip
  (`FdrBuy_HarvestTrueData`, which also sets `fdrVerified`). Rows render
  dimmed until their listing is verified, then white — the buy dialog's
  greyed→white behavior, per listing. Verification always re-runs on open
  (stale `fdrVerified` cleared) so sold listings are caught: after an
  exhaustive find, unverified members are flagged `fdrGone` (dim, "?"
  time cell, warning in the row tooltip). Timeouts do NOT mark gone.
  Unscaled gear and goods open instantly with no query.
- **Stale pruning**: when a find is EXHAUSTED (last page seen, not a
  timeout or the page cap), unverified members are flagged `fdrGone` AND
  removed from `gFdr_Results`. These are sold listings — or one listing
  double-seen across page boundaries during the scan (the unstable
  server sort; a "x4" group that is really one listing). The window
  keeps showing pruned rows marked gone for transparency; the main list
  self-cleans on the rebuild.
- On finish a rebuild re-derives the face's verified values, so the main
  list row also turns white when all members agree.
- **Verify button** (`Atr_Finder_VerifyButton`, above the Debug
  checkbox, anchored to AuctionFrame): appears whenever the display
  contains greyed rows (scaled, unverified). Runs the same find engine
  in "sweep" mode: one exact-name query per distinct greyed name, whose
  members are ALL unverified scaled scan records with that name, so
  every variant and duplicate verifies (or is pruned) in one pass. The
  main list whitens progressively per finished name; progress shows in
  the message line ("Verifying (2/5): ..."); the button doubles as
  Cancel while running. Exclusive with scans/buys/the window.
- Clicking a window row closes the window and hands the REAL member rec to
  `Atr_Finder_RequestBuy` — a valid tuple, so exact buying just works.
- Mutual exclusion: opening the window cancels a pending buy and vice
  versa; new scans, tab changes, and AH close cancel the window; opening
  is refused while a scan runs (shared query channel).

## Buy engine (instance-exact)
- Row click → `Atr_Finder_RequestBuy(rec)` → dialog opens and the find
  auto-starts: exact-name paged query; match by identity tuple
  **name + count + buyoutPrice + level** (`FdrBuy_Matches`). Multi-listing
  group faces never reach this path (see Group listings window above).
- On found (`FdrBuy_Found` → `FdrBuy_ShowConfirmView`): reads live bid
  data; harvests TRUE DPS/ilvl by reading a hidden tooltip
  (`Atr_FinderScanTT`) fed with `SetAuctionItem("list", i)` (DPS parse is
  an enUS pattern; ITEM_LEVEL pattern is locale-derived); shows the
  server tooltip embedded in the dialog via a dedicated
  `Atr_Finder_PreviewTT` (parented to the dialog — un-stealable); prices
  render above their buttons; bid uses `MoneyInputFrameTemplate`
  prefilled with the minimum (fallback: fixed min if template missing).
- Two-stage confirm because `PlaceAuctionBid` is hardware-event protected:
  CONFIRM (choose Buyout/Bid; validation inline: money, bid floor) →
  FINAL ("really pay X?"; Confirm/Back) → purchase inside the click, with
  a last-instant tuple re-verify AND live bid-floor re-read. List updates
  arriving during CONFIRM/FINAL re-verify the tuple and abort on change.
- Success: buyout removes one matching raw rec and rebuilds; bid reports
  "Bid placed" (item not owned yet). Scans and buys are mutually
  exclusive; AH close / tab change cancels either.

## Price database feed (`FINDER_TAB: price database feed`)
Upstream's Full Scan is dead here (see below), so ordinary Finder scans feed
Auctionator's own `gAtr_ScanDB` / `gAtr_MeanDB` instead. Toggle: the
"Prices" checkbox (`AUCTIONATOR_FINDER_SETTINGS.feedPriceDB`, default on).

Four rules make this safe on a PARTIAL scan, which is the whole difference
from upstream's whole-AH pass:
1. **Never delete.** A missing name means "not scanned", not "not for sale".
2. **Skip scaled equipment.** The DB is name-keyed; one price would stand in
   for every scaled variant. Commodities never scale, so nothing is lost.
3. **Skip a capped scan.** A truncated slice's lowest price is biased high.
4. **Bid-only rows contribute nothing** (never a zero price).

`Fdr_PriceDB_Update` returns `added, updated, skipped, reason`. The reason
token exists because **silence was the original bug**: four decline paths
returned 0,0,0 with no message, which is indistinguishable from the feed
never running. `Fdr_PriceDB_WhyText` renders it and the status line now
always says why nothing was saved (`off` / `cap` / `nodb` / `scaled` /
`nobuyout` / `quality`; `empty` needs no note). The gear case matters most:
the Finder is a gear tool, so on a gear sweep rule 2 legitimately eats
everything and the feed looks broken while working perfectly.

**Partial flush on cancel.** `Atr_Finder_CancelSearch` calls
`Fdr_PriceDB_Update(nil, true)` — INSERT ONLY. A cancel never reaches
`Fdr_FinishSearch`, so a cancelled sweep used to bin minutes of scanning. A
half-finished scan's "lowest" is biased high and must not overwrite a value
a completed scan established, but for a name we have nothing on it still
beats nothing. Returns the salvage counts so the Full Scan driver can bank
them.

`/atrprices` prints feed state, DB size, mean-DB size, minutes since the
last write and the active quality floor — the direct answer to "is this
actually updating?" without a scan or a `/reload`.

## Full Scan replacement (`FINDER_TAB: full scan replacement`)
Upstream's Full Scan is blocked **twice** on Ascension: `Atr_FullScanStart`
calls `QueryAuctionItems(..., getAll=true)`, which the server disables, and
`Atr_UpdateFullScanFrame` *disables the Start button* whenever
`CanSendAuctionQuery`'s second return is false — which here it always is. So
the button is greyed out before it can even fail. Upstream's paged
alternative was abandoned mid-wiring (`Atr_FullScan_Slow` is commented out
in `Auctionator.xml`).

Three globals — `Atr_ShowFullScanFrame`, `Atr_UpdateFullScanFrame`,
`Atr_FullScanStart` — are **redefined**, not edited. The toc loads this file
after `AuctionatorScan.lua`, so the later definition wins and neither
`AuctionatorScan.lua` nor `Auctionator.xml` needs touching.

- The existing dialog is reused; only `Atr_FullScanHTML` (the explanation
  blob, 405x300 at 27,-175) is hidden and the picker built in Lua in that
  space. The DB-size readout, last-scan line, status line and Done button
  all still earn their place.
- **Gear is refused twice**: greyed and disabled in the UI, AND
  `Fdr_FS_IsSelected` returns false for classes 1/2 regardless of stored
  state, so a hand-edited SavedVariables file cannot smuggle Armor in. The
  popup spells out why (name-keyed DB vs per-instance scaling).
- `FS_MERGE_INTO` folds Projectile and Quiver into Miscellaneous — one
  checkbox, three server scans, marked `+` with a tooltip listing members.
  Keyed by class NAME, not index: Ascension's class list is not stock (it
  appends "Quest" as a 12th), and a name lookup degrades to "no merge"
  instead of merging the wrong thing.
- `Fdr_FS_SelectedClasses` returns **one entry per server scan**, expanding
  groups, so the readout, the queue and the `(n/m)` counter all measure the
  same thing. The dialog's dead 15-minute getAll countdown is repurposed to
  "Scans to run".
- **Categories run one at a time** via `Atr_Finder_StartQueueScan(specs,
  onFinish)` — the ordinary engine, fed an explicit queue instead of the
  tab's widgets — and the price feed flushes after each. Holding several
  large categories in `gFdr_Results` at once would be a real memory problem;
  sequential also means a cancel keeps everything already priced.
- **A queued run pre-marks every spec `warned = true`.** The large-scan
  prompt is a Finder-panel child and `Atr_FullScanFrame` is `toplevel` at
  DIALOG strata, so the prompt renders BEHIND it: the scan parked in
  `FDR_PAUSED` — a state nothing in OnUpdate drives — waiting for a click
  the user could not make, forever. Choosing categories and pressing the
  button IS the confirmation. The Finder tab still warns normally.
- `Fdr_FS_Cancel` and `Atr_Finder_CancelSearch` call each other and guard
  with `gFS_Cancelling`. Clearing the queue is not enough on its own: the
  engine owns an in-flight category and would keep paging, and hold the
  engine so the next run could not start.
- Optional tail phase: `Also price the Bazaar catalogue` hands off to
  `Atr_Bz_StartCategoryScan` (see BAZAAR-ARCHITECTURE.md).

## Settings & saved data
- `AUCTIONATOR_FINDER_SETTINGS` (main toc): ignoreLargeWarn, autoCompare,
  dressHover, reqOnly, feedPriceDB, fullScanCats (class index → bool, as
  string keys). Checkboxes mirror it; Debug is deliberately session-only.
- `AUCTIONATOR_FINDER_DEBUG` (stub addon): opt-in last-scan dump
  (names/links/quality/ilvl/level/count/buyout/stats), cap 3000 — the tool
  that produced most Ascension findings.

## Hover extras
- Compare (autoCompare): `GameTooltip_ShowCompareItem` on gear hover.
- Dress (dressHover): `DressUpItemLink` on gear hover; row tooltip then
  anchors mid-panel instead of ANCHOR_RIGHT so it doesn't cover the
  dressing room.
- Tooltip warning hook: see AUCTIONATOR-INTERNALS.md (Buy tab mitigation).

## Testing
- `harness_env.lua`: mock WoW API (frames, fontstrings, checkbuttons,
  tooltips, paged QueryAuctionItems server). Real `AuctionatorQuery.lua`
  is loaded for authentic dup detection. lua5.1 runs everything.
- Coverage: harness (full scan/cancel/AH-close), 2 (stale page requery),
  3 (persistent stale → page skip), 4 (grouping, stat filter AND, stat
  hygiene, DPS flag), 5 (gear group key: seed/roll/suffix/scale
  sensitivity + debug dump), 6 (category multi-spec + slot filter),
  7 (armor AND semantics, clear, autofills, level filters, My Lvl),
  8 (large-search warning flow + setting sync), 9 (buy: auto-find,
  two-stage confirm, bid, back/cancel, tamper guard), 12 (group listings
  window: open-not-buy, per-listing verification, buy-from-window,
  gone detection, goods instant path, AH-close), 13 (server-side inv-type
  filtering: index resolution, the wrist/waist order trap, robe fold,
  cloak fallback, material x slot fan-out, missing-API fallback).
  `harness13` carries the real probed `GetAuctionInvTypes` tables and is
  the only harness whose mock server honours `invTypeIndex`; harnesses 6
  and 7 deliberately leave the API undefined and so still cover the
  unfiltered fallback path.
- `harness24` covers the research ledger and the price feed (four rules,
  the reason tokens, the partial flush, and the cap removal — a 60-page
  scan must now complete where the old cap stopped it at 50).
- `harness25` covers the Full Scan replacement (class list, gear refusal in
  the model, group expansion, sequential runs, cancel, the picker, the
  live heartbeat, the 40-page no-stall case, retry backoff) and the
  Bazaar → `gAtr_ScanDB` bridge.
- `harness10`/`harness11` are not listed above because they test the
  `AuctionatorHints.lua` FINDER_TAB blocks (scaling detector, vendor price
  learning + predictor), not this module — but they run in the same suite
  and need the shipped Hints file present. See README-TESTS.md.
- Pattern: patch → `luac5.1 -p` → run all harnesses → deliver. Expect the
  mock "server" to be static (sold listings aren't removed).
