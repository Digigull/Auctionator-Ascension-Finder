# Auctionator — Finder (Ascension)

A build of the classic **Auctionator** auction-house addon for the
**[Ascension](https://ascension.gg)** 3.3.5 client, extended with a new
**Finder** tab for fast, filtered searching, buying, and price scanning of
the auction house.

> Auctionator is by **Zirco**, community-maintained for Ascension by the
> [Ascension-Addons](https://github.com/Ascension-Addons) contributors.
> This build adds the Finder and Bazaar tabs, plus Sell-tab tooling, on top
> of the Ascension build. Interface version `30300`.

---

## What the Finder adds

The Finder tab sits alongside the stock Auctionator tabs and is built for
Ascension's quirks — most importantly, the server's **item-level and
required-level rescaling**, which breaks name-keyed price tools and any
UI that trusts the AH API's level values.

- **Category + stat search** — filter by item class/subclass, armor slot,
  stat (multi-select, AND semantics), and level range. Armor slot
  selections are pushed down to the server as real inventory-type queries
  (e.g. "Leather + Head" is one small scan, not all leather).
- **No page cap** — scans run until the server serves a short page (the
  real end of the result set), guarded by a runaway limit derived from the
  server's own reported total. Large categories (Trade Goods is ~37k rows
  on this realm) scan in full instead of being truncated at 2500 rows.
- **Scaled-gear aware** — rescaled items are detected and their *true*
  item level / DPS are verified per listing by reading the server tooltip,
  so grouping, sorting, and buying reflect what you'll actually receive.
- **Instance-exact buying** — a two-stage confirm flow buys the exact
  listing you clicked, with a last-instant re-verify against the live list
  so you never buy the wrong item out from under a shifting server sort.
- **Group listings window** — grouped rows expand to per-listing detail
  (cheapest-per-item first) with live verification of scaled variants.
- **Price database feed** — ordinary Finder scans feed Auctionator's own
  price/mean databases (upstream's Full Scan is blocked on Ascension), with
  safeguards so a partial scan never poisons the data. `/atrprices` reports
  feed state and DB size.
- **Full Scan replacement** — upstream's `getAll` Full Scan is disabled by
  the server; the Finder replaces it with a sequential, per-category paged
  scan (gear deliberately refused, since the DB is name-keyed).
- **Tooltip crafting help** — item tooltips (including the produced item in
  an open profession window) show the reagent **Craft cost** and a green
  **Craft profit** / red **Craft loss** line, comparing the item's auction
  price to what its reagents cost.
- **NPC-price for vendor reagents** — NPC-sold trade goods (Empty Vial,
  Crystal Vial, Wooden Stock, thread, flux, dyes, spices, …) are *learned*
  by reading vendor inventories: any Trade Goods item a merchant offers at
  unlimited stock for a plain gold price is recorded (account-wide) as an
  **NPC price**. On those items the tooltip shows the fixed **NPC price**
  instead of a misleading AH number, and the craft-cost maths above uses it
  too, so reagents you buy from a vendor are costed at what you actually pay.
  ("NPC price" = what you pay to buy, distinct from the existing "Vendor"
  line = what an NPC pays you.) No curated list — coverage grows as you
  visit vendors.
- **Random-suffix price estimate** — random-enchant gear ("Dreamdust
  Slippers") is listed on the AH only under its rolled-suffix names
  ("… of the Magus", "… of the Owl", …), so the name-keyed DB has no entry
  for the bare base item — the exact case that makes crafted base gear read
  "Auction: unknown". When the base name isn't listed directly, its auction
  price is estimated as the **median across the suffixed variants** that are,
  shown on tooltips as `~price (est) (n)`. This feeds the Sell tab and the
  crafting help above, so base gear is priced instead of blank.
- **Configurable tooltip prices** — by default every addon price line except
  **Vendor** (its predicted / estimated tiers included) is hidden until you
  hold **Alt**, keeping tooltips clean at a glance; a faint "Hold &lt;Alt&gt;
  for auction prices" breadcrumb marks what's tucked away. The best (lowest)
  price line is highlighted in a configurable colour — **blue** by default —
  and when Auction and Auction median tie, only the **Auction** line is
  highlighted. All of this lives under *Interface → Options → AddOns →
  Auctionator → Tooltips*: which lines show, whether they need Alt, and the
  highlight colour (a standard colour-picker swatch).

- **Item quantity on tooltips** — item tooltips gain a **Qty** line totalling how
  many you own across all your characters; hold **Alt** and it expands into a
  breakdown of where they sit: per character (bags vs. bank) and in the
  account-wide web-shop **Personal Bank** / **Realm Bank** (with the tab numbers
  that hold it). Counts are remembered as each character's bags update, its bank
  is opened, and each web-shop bank is opened, so the total is right even away
  from a bank. Both the quantity line and the location breakdown are
  independently configurable (always / never / Shift / Ctrl / Alt) under
  *Tooltips*; quantity defaults to **always** and locations to **hold Alt**. The
  Personal and Realm banks are told apart by their first tab's name — the way
  Ascension routes them through the guild-bank frame. *(The genuine guild bank
  reports no tabs through that API and is a separate opt-in follow-up.)*

For the full design, see the notes in [`Old Docs/`](Old%20Docs/) —
especially [`FINDER-ARCHITECTURE.md`](Old%20Docs/FINDER-ARCHITECTURE.md),
[`BAZAAR-ARCHITECTURE.md`](Old%20Docs/BAZAAR-ARCHITECTURE.md),
[`AUCTIONATOR-INTERNALS.md`](Old%20Docs/AUCTIONATOR-INTERNALS.md), and
[`ASCENSION-CLIENT-NOTES.md`](Old%20Docs/ASCENSION-CLIENT-NOTES.md).

---

## Sell tab — inventory browser

The stock Sell tab gains an inventory browser that reads your bags and sorts
every sellable item by the **best way to sell it**:

- **Best-method buckets** — each item is filed under **Auction**,
  **Disenchant**, or **Vendor**, whichever nets the most (AH price wins ties,
  then Disenchant over Vendor), so you can see at a glance what's worth listing
  versus what to vendor or DE.
- **Scan Inventory** — one button prices every distinct item in your bags
  against Auctionator's price database in a single pass; the buckets and
  margins fill in as prices arrive.
- **Profit Margin filters** — a **Profit Margin** popup adds two independent
  thresholds: **Vendor Margin** (how much the best method beats simply
  vendoring) and **Crafted Goods Margin** (auction price minus reagent cost).
  An item that fails an enabled filter drops into a **Not Profitable** bucket
  instead of cluttering the real categories. Items whose data isn't known yet
  (unpriced, or a craft cost that can't be totalled) are left alone until a
  scan or tooltip harvest fills them.
- **Ignore bucket** — an **Ignore** button parks the item in the sell slot
  into a dedicated bucket at the very bottom, skipping the method split and the
  margin filters alike; click the tile there to take it back out.

---

## Gentle merchant & profession learning

The margins above lean on two things the addon learns quietly in the
background: **NPC prices** (what vendors charge for reagents) and **crafting
recipes** (read from profession windows). Both are learned the least
aggressive way, so opening an NPC or a profession window doesn't stutter:

- **Debounced** — the client refires `MERCHANT_UPDATE` /
  `TRADE_SKILL_UPDATE` in a burst while item data streams in. Each harvest
  waits for that storm to go quiet and then runs **once**, instead of
  re-walking the whole list on every event.
- **Scanned once per session** — each vendor and profession is fingerprinted
  (who, how many items, first/last item) and skipped on re-open once it's been
  fully read. A stale re-open costs a couple of item-link reads, not a full
  walk. The ledger resets on `/reload` or relog, so a fresh login re-learns
  once in case stock or your recipes changed.
- **Cold-cache safe** — a list read before its item data finished arriving is
  left unmarked, so the next quiet update fills the gaps rather than locking in
  a partial scan.

This lives in `AuctionatorFinderMerchant.lua` (NPC + Bazaar merchant scan),
`AuctionatorFinderProfession.lua` (trade-skill scan + the profitability sort
below), and the shared `AuctionatorFinderScanThrottle.lua` session ledger.

---

## Profession window — Sort by Profit

A **Sort by Profit** checkbox sits just above the top-left corner of any
profession window (Alchemy, Tailoring, …). Tick it and the recipe list is
re-ranked so the items you can craft at the biggest profit come **first** and
the least profitable — or loss-making — come **last**; each row shows a short
green **+profit** / red **−loss** figure. Profit is the produced item's
auction price minus what its reagents cost (the same NPC → auction →
vendor-sell cascade the Crafted Goods Margin filter and the craft-cost
tooltip use).

- **Composes with the built-in controls** — the subclass / slot dropdowns, the
  *Have Materials* checkbox and the search box still narrow the list; the sort
  simply re-ranks whatever survives them. Ticking the box expands every
  collapsed category first, so nothing hides from the ranking.
- **Unpriceable recipes sink to the bottom** — a recipe with a reagent we can't
  price yet, or a produced item with no auction price, ranks below every priced
  recipe rather than guessing a wrong number. Coverage grows as you scan the AH
  and visit vendors.
- **Never breaks the window** — the reorder rewrites only the visible list
  rows, on top of Blizzard's own update, and is fully error-guarded: on any
  surprise from this custom client it turns itself off and falls straight back
  to the stock list. Off by default; the setting is remembered per account
  (`AUCTIONATOR_FINDER_SETTINGS.profSort`).

---

## Bazaar tab — token ⇄ gold converter

Ascension sells vanity and convenience goods for **Bazaar Tokens** (ordinary
item `975001`), which players get either with real money (DP on the webshop)
or with gold by buying them off the auction house. The Bazaar tab models that
whole chain — `USD → DP → Bazaar Token → gold` — with every rate
player-editable and persisted, and prices the token catalogue so each item
shows, per unit, whether it's cheaper to buy **with tokens or with gold**. The
**Margin** column already nets out the auction house's cut on a sale (5% by
default), so the comparison reflects what you'd actually clear rather than an
optimistic sticker price.

---

## Repository layout

| Path | Contents |
| --- | --- |
| `Auctionator-Finder-Ascension/` | The addon: `.toc`, Lua modules, XML frames, `Locales/`, `Images/`. |
| `Old Docs/` | Architecture, client, and testing notes. |

---

## Installation

1. Copy the addon folder into your Ascension `Interface/AddOns/` directory,
   keeping the folder structure intact. See
   [`README-SHARING.txt`](Auctionator-Finder-Ascension/README-SHARING.txt)
   for the full list of folders to package for distribution.
2. Fully restart the client. In the AddOns list, **"Allow Non-Launcher
   AddOns"** must be enabled (default for anyone already using
   non-launcher addons).
3. Open the auction house and select the **Finder** tab.

> **Note:** WowUp does not support Ascension. Distribution goes through the
> Ascension launcher's Addons tab (fed from the Ascension-Addons GitHub
> org), a GitHub release zip, or the Ascension forum/Discords. See
> `README-SHARING.txt` for details.

---

## Development & testing

The addon is plain Lua 5.1 with a mock-WoW-API test harness (no client
required to run the suite):

- Mock API and paged auction server live in the test harness; the real
  `AuctionatorQuery.lua` is loaded so duplicate-page detection is authentic.
- Workflow: patch → `luac5.1 -p <file>` (syntax check) → run all harnesses.
- See [`Old Docs/README-TESTS.md`](Old%20Docs/README-TESTS.md) for the
  harness map and coverage.

---

## Credits & license

Auctionator is by **Zirco**, community-maintained for Ascension by the
Ascension-Addons contributors. This build adds the Finder tab on top of
that lineage; contributing changes back to
[Ascension-Addons/Auctionator](https://github.com/Ascension-Addons/Auctionator)
is the cleanest way to honor it.
