# Auctionator Internals (Ascension community build)

Based on reading the shipped source (Auctionator 2.6.x lineage with
Ascension-specific modifications: scan watchdogs, sell-tab inventory
browser, mean-price DB, texture-based name disambiguation hack).

## Addon layout / SavedVariables pattern
- Main folder `Auctionator/` plus **stub addons** that exist only to route
  SavedVariables into their own files on disk:
  `Auctionator_Price_Database/`, `Auctionator_Pricing_History/` (originals).
  A stub is just a one-line `.toc` with a `## SavedVariables:` line; each
  variable must be declared by exactly ONE addon. Files land in
  `WTF/Account/<acct>/SavedVariables/`. (Our `Auctionator_Finder_Debug/` stub
  followed this pattern but was removed with the vendor-price research
  scaffolding — see `VENDOR-RESEARCH-CLEANUP-PLAN.md`.)
- Main toc SavedVariables include the price DB, shopping lists, etc., and
  (our addition) `AUCTIONATOR_FINDER_SETTINGS`.

## Tab system (how the Finder plugs in)
- Auctionator injects its own bottom tabs into the stock AuctionFrame via
  `Atr_AddSellTab(text, whichTab)` (generic despite the name). Constants:
  `SELL_TAB=1, MORE_TAB=2, BUY_TAB=3`; the Finder added `FINDER_TAB=4`
  (exported as global `ATR_FINDER_TAB`).
- `Atr_FindTabIndex(whichTab)` maps constants → real tab indices (cached).
- `Atr_AuctionFrameTab_OnClick` replaces Blizzard's
  `AuctionFrameTab_OnClick` (assigned in `Atr_SetupHookFunctions` during
  `Atr_Init`, which runs on first AH open). It shows/hides Auctionator's
  textures, panels and per-tab panes. All Finder integration patches in
  `Auctionator.lua` are tagged with `FINDER_TAB` comments/idents.
- `hooksecurefunc("Atr_AuctionFrameTab_OnClick", ...)` works IF installed
  before `Atr_SetupHookFunctions` reads the global (our `Atr_Finder_Init`
  is called from `Atr_Init` before that — ordering matters).
- `Atr_SelectPane(whichTab)` programmatically switches tabs (numeric
  constants are stable: 3 = Buy).

## Scan/search machinery
- `AtrSearch` (AuctionatorScan.lua): paged query state machine
  (KM_PREQUERY/POSTQUERY), driven by `Atr_OnAuctionUpdate` on
  `AUCTION_ITEM_LIST_UPDATE` plus an OnUpdate idle loop.
- `AtrQuery` (AuctionatorQuery.lua): **duplicate-page detector** —
  compares a page's item tuples against the previous page; global
  `Atr_NewQuery()` constructs one. Reused by the Finder. Its
  `numDupPages > 10` abort is too aggressive for long scans on this
  server (unstable sort); the Finder uses consecutive-retry logic instead.
- **The price database updates on every ordinary Buy/Sell search**
  (`AtrSearch:Finish` writes `gAtr_ScanDB[itemName]`), not just full scans.
- Compound search syntax exists in the Buy search box
  (`Atr_ParseCompoundSearch`): "name/minLvl/maxLvl" style with class terms.

## Buy tab model and its structural limitation
- The Buy tab condenses scans **by item NAME** (grouped by stack+price).
  It keeps essentially one item link per name. Therefore it cannot
  represent Ascension's scaled variants or distinct rolls sharing a name:
  its icon/tooltip shows one cached version for all of them, and a
  purchase can deliver a different variant than the tooltip displayed.
  A real fix requires reworking AuctionatorShop.lua's data model (source
  not yet examined in this project).
- Mitigation shipped: the Finder appends an orange "Scaled item: multiple
  versions exist" warning to any AH tooltip (via a `hooksecurefunc` on
  `GameTooltip.SetHyperlink`) for item names the Finder has seen with
  multiple scale levels this session (`gFdr_ScaledNames`).
- Auctionator's own purchase flow ends in a user-clicked confirm because
  `PlaceAuctionBid` demands a hardware event; any buying feature must be
  structured the same way.

## Misc integration notes
- `Atr_Search_Box` + `Atr_Search_Onclick()` run a Buy-tab search
  programmatically (quote the name for exact match).
- Blizzard Browse can be driven via `AuctionFrameTab_OnClick
  (AuctionFrameTab1, 1)`, `BrowseName:SetText(...)`,
  `AuctionFrameBrowse_Search()`.
- `ZT()` is Auctionator's localization lookup (guard availability).
- `zc.UTF8_Truncate(str, 63)` protects against disconnects from over-long
  query strings.
- Auctionator's frames/xml use CRLF line endings.

## Bazaar tab integration points
Established 2026-07. Complements the `FINDER_TAB` notes above; the Bazaar tab
hooks the same machinery at the same places, tagged `-- BAZAAR_TAB`.

### The 14 sites in `Auctionator.lua`
Ten add a sibling line beside the existing `FINDER_TAB` line; four widen an
existing line. All are greppable with `grep -c BAZAAR_TAB` (returns 15 — the
14 markers plus the constant).

Widened rather than duplicated:
- `Atr_IsTabSelected(...)` and `Atr_IsAuctionatorTab(...)` — the two
  tab-membership predicates
- the shared-`Atr_Hlist` suppression (`index ~= Atr_FindTabIndex(FINDER_TAB)`
  became an `and` chain)
- the panel-show branch, now an `elseif` chain

### Programmatic Buy-tab search
Confirmed working; used by the Bazaar tab's purchase hand-off and already
present in `auctionator_ChatEdit_InsertLink`:

```lua
Atr_SelectPane (BUY_TAB);            -- select FIRST; the search box belongs
Atr_Search_Box:SetText ('"'..name..'"');  -- to the shared main panel and is
Atr_Search_Onclick ();                    -- hidden until Buy is up
```

**Quote the name.** Unquoted, Auctionator substring-matches, so `Bazaar Token`
also returns `100 Bazaar Tokens`.

`Atr_SelectPane(whichTab)` takes the *auctionatorTab id*, not the frame index;
it resolves the index itself and calls `Atr_AuctionFrameTab_OnClick`.
`BUY_TAB` is file-local to `Auctionator.lua` and its value is 3 —
`AuctionatorFinder.lua` hardcodes the same 3 at its tab-membership check.

### `Atr_Buy1_Button`
Sits on the frame's bottom bar. Useful for two things beyond buying:
- the Finder anchors its "Back to Finder" button to it (`RIGHT`, `LEFT`, −45),
  and the Bazaar tab anchors "Back to Bazaar" left of that;
- its `GetBottom()` relative to `AuctionFrame:GetBottom()` is a reliable way to
  *measure* where the bottom bar is, instead of guessing a pixel offset.

### The Finder's jump is dead code
`gFdr_JumpPending` is declared, read and reset in `AuctionatorFinder.lua` but
**never set to `true` anywhere in the fork**. `gFdr_BackEnabled` therefore never
becomes true and `Atr_Finder_BackButton` is unreachable. Worth knowing before
debugging why it never appears, and before assuming a second back button would
collide with it.

### The price database
`gAtr_ScanDB[itemName] = <copper>` — a plain number, the lowest per-item price
seen. Written by **every ordinary Buy/Sell search** (`AtrSearch:Finish`), not
only by full scans, so any item the player has ever looked up already has a
price on disk. `gAtr_MeanDB[itemName]` holds up to 15 historical samples.

Both are **name-keyed**, which cannot distinguish items whose names overlap
(`Bazaar Token` vs `100 Bazaar Tokens`). The Bazaar tab therefore keeps its own
itemID-keyed cache in `AUCTIONATOR_BAZAAR.prices` and treats `gAtr_ScanDB` as a
fallback.

Name-keying is nonetheless safe for Bazaar goods specifically: vanity and
convenience items are unscaled with unique names. It is the *gear* case that
breaks, which is why the Finder exists.

### Buying is not one call
`Atr_Buy1_Onclick` reads `Atr_GetCurrentPane().activeScan.sortedData[currIndex]`
— shared Buy-tab pane state — then opens a confirmation frame, re-queries
pages, builds a match list and calls `PlaceAuctionBid("list", i, buyout)` per
match, handling partial fills and multi-stack purchases.

The reason it is that elaborate: `GetAuctionItemInfo("list", i)` indices are
valid only for the page currently loaded on the client. Any addon that pages
through results and then wants to buy one must re-query and re-locate the exact
auction. This is why the Bazaar tab hands off rather than reimplementing.
