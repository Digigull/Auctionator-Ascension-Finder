# Finder / Bazaar Test Harness

Mock-WoW regression suite for `AuctionatorFinder.lua` and
`AuctionatorBazaar.lua`. Runs under plain **Lua 5.1**
(`apt install lua5.1`), no WoW client needed.

## Layout
- `harness_env.lua` — the mock WoW API: frames, fontstrings, checkbuttons,
  tooltips, a fake paged auction server (globals `TOTAL`, `curPage`,
  `queryCount`), `CreateFrame`, `FauxScrollFrame_*`, `time()`, etc.
  Individual harnesses override `QueryAuctionItems` / `GetAuctionItemInfo`
  / `GetAuctionItemLink` / `GetItemInfo` / `GetItemStats` /
  `IsEquippableItem` / `UnitLevel` / `PlaceAuctionBid` to shape scenarios.

### Finder
- `harness.lua`  — full scan, cancel/restart, AH-close safety
- `harness2.lua` — one stale/duplicate page: requeried, no double-count
- `harness3.lua` — permanently stale page: skipped with note, scan survives
- `harness4.lua` — grouping, stat filter AND semantics, stat hygiene
  (constant pseudo-stats excluded), DPS auto-column flag
- `harness5.lua` — gear group key: seed-insensitive, roll/suffix/scale-
  sensitive; debug dump written
- `harness6.lua` — category multi-spec scans + armor slot client filter
- `harness7.lua` — armor materials-AND-slots, ClearFilters, gear autofills
  (min level −5, Usable, My Lvl with override memory), live level filters
- `harness8.lua` — large-search warning: cancel, continue, ignore setting
  synced across both checkboxes
- `harness9.lua` — buy engine: auto-find, two-stage confirm, bid path,
  Back/Cancel stages, tamper guard (price change aborts)
- `harness10.lua` — per-instance scaling detector: tooltip il/req vs cached
  `GetItemInfo`, Vendor line suppressed on mismatch
- `harness11.lua` — vendor price learning, buyback tuple-exact confirmation,
  same-name sale sprees, sale announcements + toggle, and the stage-2
  predictor (`Atr_VendorPredict_Get`: rung interpolation, plateau
  extension, reason strings)
- `harness12.lua` — group listings window
- `harness13.lua` — server-side inventory-type filtering. Its pump exits on
  the FINISH line; it used to break on a bare `rows`, which the live progress
  label later also contained, ending the loop on tick 1 and seeing 1 spec
  instead of 4. Match finish text specifically, never a substring that
  progress text might share.
- `harness24.lua` — vendor-price research target ledger: absorbs only
  equippable+scaled rows, keys variants by the list API's real required
  level, unit-prices stacks, never reads a bid-only listing as free,
  retires levels confirmed in `.obs`, and ranks with each scoring weight
  proven load-bearing (paired probes whose id tie-break favours the wrong
  item, so a dead weight flips the order); the bid-cost fallback and its
  ranking penalty; ammo/bag/quiver exclusion; and the price-DB feed's four
  partial-scan rules, with the capped-scan rule driven for real through the
  mock paged server rather than by poking a flag; plus the feed's REASON
  tokens (every decline path names itself, so a silent zero can be told from
  a feed that never ran), the partial insert-only flush, and the removal of
  the 50-page cap — a 60-page scan must now visit all 60 pages where the old
  cap stopped at 50 and discarded everything
- `harness25.lua` — the Full Scan replacement and the Bazaar price bridge:
  the class list (12 on this client — Ascension appends `Quest`) with
  Projectile/Quiver merged into Miscellaneous; gear refused in the MODEL as
  well as the UI, including a hand-edited SavedVariables smuggling attempt;
  group expansion so the readout, queue and `(n/m)` all count the same
  thing; the Start button never re-gated on `canQueryAll`; sequential runs
  with accumulating counters; cancel releasing the ENGINE and not just the
  queue; the picker's disabled Armor row and its explanation; the live
  heartbeat including the throttled-before-first-page case; a 40-page
  category completing instead of parking in `FDR_PAUSED` behind the
  toplevel dialog; retry backoff measured as queries-per-tick; and the
  bridge writing only unambiguous names into `gAtr_ScanDB`

### Bazaar
- `harness14.lua` — rate engine: the default chain reproduces the converter
  page exactly, ratio-consistent conversions, round trips, atomic validation
  (nil/0/negative/NaN/inf/text all rejected leaving stored rates untouched),
  gold+silver entry with fractional silver (59.04s → 5904c, not 5903),
  SavedVariable repair and version migration, manual vs auction provenance
- `harness15.lua` — panel lifecycle: init is idempotent and leaves the panel
  HIDDEN (the tab handler is what shows it), `OnTabClick` is safe before the
  tab constants exist and when handed a foreign or nil index
- `harness16.lua` — catalogue merge and merchant harvester: the seed matches
  the Phase 0 harvest (294 items, 231 tradeable, every heirloom bound), a
  live harvest supersedes the seed per itemID, the cost test rejects
  gold-priced vendor stock and foreign currencies, gossip labels are
  stripped of texture escapes, the Bazaar Tokens category and sibling
  learning
- `harness17.lua` — display layer: **§0 runs immediately after `Init` with
  no interaction** (the fresh-`/reload` state — see Conventions), row counts
  measured from frame height, long names chopped not wrapped, per-view
  column geometry, the filter including pattern-safety and its widening
  fallback, sorting with blanks pinned last in both directions
- `harness18.lua` — rate editor: atomic application, load round-trips
  without drift, gold/silver split, dialog geometry and colours
- `harness19.lua` — live token pricing: itemID filtering (the
  `100 Bazaar Tokens` trap), bid-only listings skipped not zeroed, per-stack
  arithmetic, paging, an empty market leaving the rate alone
- `harness20.lua` — market price and margin: `gAtr_ScanDB` lookup, margin net
  of the AH cut, a zero cut accepted, bound items never claiming a margin,
  the header legend's colours matching the cells'
- `harness21.lua` — the drill-down: condensing, itemID filtering against a
  decoy, bid-only listings kept, per-view column meanings and header strip
  position, the icon and vendor subtitle, sorting the auction list
  independently of the catalogue
- `harness22.lua` — remembered prices and bulk pricing: the itemID-keyed
  cache taking precedence over the name-keyed database, drill-downs writing
  back, the queue honouring the filter and skipping bound items,
  cancellation from four directions
- `harness23.lua` — the jump to the Buy tab: quoted exact-match search, the
  Back to Bazaar button appearing only on Buy and only after a jump,
  returning with listings intact, degraded environments reported not crashed

**`harness10` and `harness11` are different from the rest.** They do not test
`AuctionatorFinder.lua`; they extract the `FINDER_TAB begin:`/`end:` blocks
**verbatim from the shipped `AuctionatorHints.lua`** and load them, so the
tests can never drift from shipped code. Both therefore need the patched
`AuctionatorHints.lua` sitting in the same directory.

## Running
Place these next to `AuctionatorFinder.lua`, `AuctionatorBazaar.lua` and
`AuctionatorQuery.lua` (the real Auctionator file — harnesses load it for
authentic duplicate-page detection), then:

    for h in harness harness2 harness3 harness4 harness5 harness6 harness7 \
             harness8 harness9 harness10 harness11 harness12 harness13 \
             harness14 harness15 harness16 harness17 harness18 harness19 \
             harness20 harness21 harness22 harness23 harness24 harness25; do
        lua5.1 $h.lua > /tmp/$h.out 2>&1 && echo "$h: PASS" || { echo "$h: FAIL"; tail -4 /tmp/$h.out; }
    done

Note some harnesses print their own `PASS` banner rather than a failure
count, so grep for `^FAIL`, `lua5.1:` and `[1-9][0-9]* failures` when
scripting the sweep — a naive `grep "0 failures"` reports false alarms.

Also validate syntax after any edit: `luac5.1 -p AuctionatorFinder.lua`
and `luac5.1 -p AuctionatorBazaar.lua`

## Conventions
- The mock "server" is static: sold listings are not removed, so
  live-index assertions reflect the full listing set.
- When adding features, extend the nearest harness rather than starting a
  new one, unless the feature has its own state machine (then a new file,
  like harness9 for the buy engine or harness19 for token pricing).
- A `harness10`/`harness11` failure of the form *"attempt to call global
  `Atr_...` (a nil value)"* almost always means the `AuctionatorHints.lua`
  in the working directory is **older than the shipped addon**, not that the
  test is wrong. Refresh the file before touching the harness — this is the
  extract-verbatim design doing its job. (Happened 2026-07: a stale copy
  predating the stage-2 predictor silently blocked 31 assertions. All 111
  passed once the current file was restored.)
- Harnesses that leave an API undefined are testing the fallback path on
  purpose. `harness6`/`harness7` deliberately do not define
  `GetAuctionInvTypes`, so they still cover unfiltered armor-slot scans;
  only `harness13` exercises the server-side filter.
- **Test the first frame, not just the steady state.** Every Bazaar harness
  used to call `SelectCategory` or `OpenItem` before examining a widget, so
  all ten stayed green while the column headers rendered blank on a fresh
  `/reload` — a bug the user hit immediately. `harness17` §0 now asserts the
  post-`Init` state with no interaction at all.
- **Verify a new regression test by breaking the code.** The §0 headers test
  above was confirmed to fail against the pre-fix file before being kept. A
  regression test that has never been seen to fail is not evidence. This
  earned its keep again in 2026-07: breaking the full-scan cancel path
  changed nothing, which exposed that `Fdr_FS_Cancel` was clearing its own
  queue while leaving the engine paging — a real bug the passing test had
  been blind to.
- **A test can pass for the wrong reason.** The first live-progress test
  asserted the dialog showed `(1/1)`, which the *initial* "Scanning..."
  message already satisfied; it proved nothing about page counts. Assert the
  specific thing (`page %d`, `%d listings`), not a prefix that something
  else supplies.
- **Some state is file-local and cannot be poked.** `gFdr_CapHit` is a
  `local`, so assigning the global does nothing; harness24 drives the cap
  through the mock paged server instead. When a "break the code" run does
  not fail, suspect the reach of the test before the correctness of the code.
- **New status strings can collide with harness pump conditions.** See the
  `harness13` note above. Progress text and finish text now use different
  words on purpose: raw pre-grouping records are *listings*, grouped rows
  are *rows*.
- **Mocks must match the real API's shapes, including optional arguments.**
  WoW accepts both `SetPoint(point, x, y)` and
  `SetPoint(point, relFrame, relPoint, x, y)`; a mock that understood only
  the long form silently recorded short-form anchors as `(0, 0)`, so
  assertions about them passed or failed for unrelated reasons. Same class of
  defect as the `zc.ItemIDfromLink` arity trap below.
- **Harness mocks must match real zcUtils return arity.** `zc.ItemIDfromLink`
  returns THREE values (id, suffix, unique — strings); a single-return mock
  hid a live crash.
