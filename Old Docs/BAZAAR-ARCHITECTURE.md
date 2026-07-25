# BAZAAR-ARCHITECTURE.md — the Bazaar tab

`AuctionatorBazaar.lua` (LF, ~3400 lines, single file) adds a **fifth**
Auctionator tab, **"Bazaar"**, for Ascension's dual-currency economy.

Ascension sells vanity and convenience goods for **Bazaar Tokens**. Tokens are
obtainable two ways — with real money via DP on the webshop, or with gold by
buying them off the auction house, where they are ordinary item **975001**.
That makes four currencies on one chain:

```
USD  --bundle-->  DP  --shop rate-->  BT  --auction house-->  gold
```

The tab prices the whole vendor catalogue along that chain and compares it
against live auction prices, so you can see whether an item is cheaper bought
with tokens or bought with gold.

Ported from a standalone HTML converter the author had already built; its
defaults ($15 = 50 DP = 1250 BT = 738g, i.e. 1 BT = 0g 59.04s) are the
shipped defaults.

---

## Why it is a standalone panel, not a Buy-tab refit

The obvious plan — copy the Buy tab and adapt it — does not work. The Buy tab
is **not a component**; it is a *mode* of the shared `Atr_Main_Panel`. Its
widgets (`Atr_Search_Box`, `Atr_Hlist`, `Atr_DropDownSL`, the four shopping
list buttons, `AuctionatorScrollFrame`, `gCurrentPane`) are globals shared
with Sell and More, shown and hidden by branching in
`Atr_AuctionFrameTab_OnClick`. Adding a fifth mode to every one of them is
where bugs breed, and the SList buttons we wanted to remove are the same
objects Buy needs.

The Finder had already proven the alternative: a standalone panel parented to
`AuctionFrame` that hides `Atr_Main_Panel` and owns its widgets. The Bazaar
tab **reproduces Buy's geometry** rather than inheriting it:

| Buy tab slot | Bazaar tab use |
|---|---|
| `Atr_DropDownSL` (Recent Searches) | category picker |
| `Atr_Hlist` (saved list) | item navigator for the category |
| the four SList buttons | the exchange-rate block |
| the results area | the currency table |

Integration is 14 edits in `Auctionator.lua`, every one tagged
`-- BAZAAR_TAB`, mirroring the `FINDER_TAB` sites exactly.

---

## Data model

`AUCTIONATOR_BAZAAR` (account-wide, declared by the main toc):

| key | contents |
|---|---|
| `rates` / `ratesVersion` | the four editable rate edges, migrated by version |
| `learned` | vendor catalogue harvested at Tiraxis, keyed by itemID |
| `extra` | hand-added webshop-only items (`Atr_Bz_AddExtra`) |
| `tokens` | token-family items discovered by the token scan |
| `prices` | our own market-price cache: `{copper, when, n}` by itemID |

### The catalogue
`Atr_Bz_GetCatalog()` merges four sources into one itemID-keyed list, later
sources winning:

1. **`ATR_BZ_SEED`** — 294 rows extracted from the Phase 0 probe harvest, so
   the tab is populated before the player ever walks to Tiraxis. Each row is
   `{id, bt, bind, cat, name, icon}`. The **icon path ships** because
   `GetItemInfo` returns nil for an uncached custom item and a fresh install
   would otherwise show 294 question marks.
2. **`ATR_BZ_TOKEN_ITEMS`** — the currency itself, cost 1 token by
   definition, so its row shows what one token is worth and its Margin shows
   how far the market has drifted from the configured rate.
3. **`learned`** — a live merchant harvest, which supersedes the seed per
   itemID and keeps working when Ascension changes the vendor.
4. **`extra`** and **`tokens`** — webshop-only items and token siblings.

The cache is invalidated by `Atr_Bz_InvalidateCatalog()`; anything that
mutates a source must call it.

### Tradeability
`ATR_BZ_UNTRADEABLE = { BOP, REALM, SOUL, QUEST }`. **`REALM` is Ascension's
custom `Binds to realm` line** — it has no `ITEM_BIND_*` global, and omitting
it silently marks all 53 heirlooms plus Mysterious Wares as flippable. Of the
294 token items, **231 are tradeable**.

Note the heirlooms are a live trade despite being bound: the *Heirloom Weapon
Token* is BoU and sells freely, but it is sold only on the webshop, so it
appears on no vendor and cannot be discovered automatically. That is what
`extra` exists for.

---

## The rate engine

Everything reduces to **copper per unit** — one multiplication table, so every
conversion is a single ratio with no per-pair special cases:

```lua
copperPerBT   = <user input, default 5904>
copperPerDP   = copperPerBT * (btUnits / dpUnits)
copperPerUSD  = copperPerDP * (dpBundle / usdBundle)

Atr_Bz_Convert (amount, from, to)   -- units: USD, DP, BT, COPPER
```

Copper is the base rather than USD because copper is the only exact integer
axis available (the AH hands us copper) and gold is what players compare
against. **USD is deliberately the loosest end**: DP is sold in
volume-discounted bundles, so there is no single true USD/DP rate — the
player enters the bundle they actually buy.

Consequence worth remembering: **DP and USD do not move when the gold rate
changes.** `dp = bt / btPerDP`, so the `copperPerBT` term cancels. Only
gold-denominated figures follow it. Asserted in `harness17`.

**Rates apply atomically** (`Atr_Bz_ApplyRates`). Every field is validated
before any is written, because a half-applied chain would silently misprice
all 294 items with nothing visibly wrong. `ahCutPct` may legitimately be
zero, so it goes through a separate allow-zero list rather than the
strictly-positive validator the exchange rates use.

---

## Market price and margin

```
margin = (market price - ahCutPct) - (token cost in gold)
```

The auction house cut is included because ignoring it overstates every row,
worst on the expensive items where the decision matters most.

`Atr_Bz_MarketPrice` prefers **our own itemID-keyed cache**, falling back to
Auctionator's name-keyed `gAtr_ScanDB` (which every ordinary Buy/Sell search
already writes). itemID matters: a name key cannot tell `Bazaar Token` from
`100 Bazaar Tokens`.

### The price database bridge (`FINDER_TAB: price database bridge`, 2026-07)
The itemID store above is the Bazaar's own truth and stays that way — but
Auctionator's **tooltips** read the name-keyed `gAtr_ScanDB`, so a bazaar
item priced here showed nothing on its tooltip anywhere else in the game.
`Atr_Bz_FeedPriceDB` mirrors each recorded price across, and is hooked
inside `Atr_Bz_RecordPrice` rather than at the call sites so that every
pricing path — single-item drill-in, `Price these`, and the token scan — is
covered at once. Unit convention already matches: the recorder is handed the
cheapest PER-ITEM buyout, which is exactly what `gAtr_ScanDB` stores.

Bridging is safe for most of the catalogue but **not all of it**, and the
exception is the reason the itemID store exists in the first place. A name
is written only when it maps to **exactly one itemID** in the catalogue;
`Atr_Bz_BridgeMap` marks any colliding name `false` and drops it. Ambiguous
names stay itemID-only and lose nothing — the Bazaar tab still prices them.

The map is built from `Atr_Bz_GetCatalog()`, **not** `ATR_BZ_SEED`: the seed
rows are positional (`{id, bt, bind, cat, name, icon}`) and the seed omits
the hand-maintained `extra` list. It is memoized and invalidated alongside
the catalogue cache via `Atr_Bz_InvalidateBridge`, called from
`Atr_Bz_InvalidateCatalog`.

Toggle: `AUCTIONATOR_BAZAAR.feedPriceDB` (default on). Turning it off still
records to the itemID store; only the mirror stops.

**Margin colour reads as a buying signal, not a flipping one** — negative
(the AH undercuts the vendor) is green, positive is red. This is the reverse
of the usual profit-is-green convention and is deliberate; the header hint is
a two-line legend in the same two colours, and both are driven from
`ATR_BZ_MARGIN_RED` / `ATR_BZ_MARGIN_GREEN` so the legend cannot drift from
the cells it explains.

---

## UI

Two views share one set of seven row cells:

| cell | catalogue | drill-down |
|---|---|---|
| name | Item | Auctions (`10 stacks of 1`) |
| gold | Per Item (market price) | Per Item (listing price) |
| ah | *hidden* | Stack Price |
| bt | BT (vendor cost) | BT val. (listing in tokens) |
| dp / usd | vendor cost converted | listing converted |
| margin | Margin | Margin |

`gold` deliberately means the same thing in both views — a per-item gold
price — which is why both can carry the label `Per Item` honestly. `bt` does
not, hence `BT val.` in the drill-down.

`BZ_COLSETS` carries geometry only (`headerTop`, `top`, `nameRight`, and each
column's width and distance from the row's **right** edge); labels live in
`BZ_HEAD_LIST` / `BZ_HEAD_ITEM`. `Atr_Bz_ApplyColumns()` repositions headers
and cells on every view change and hides cells the active view does not use.

### Layout rules, learned the hard way
- **Nothing that must reach an edge gets a hardcoded size.** Row counts are
  computed from `AuctionFrame`'s real height in `Atr_Bz_Relayout()`; the
  numeric columns anchor to the row's right edge so `Margin` cannot be pushed
  off a frame that is not the stock 758×447.
- **3.3.5 FontStrings wrap once a width is set and nothing clips them.** Long
  names must be measured with `GetStringWidth` and chopped (`Bz_FitText`),
  never merely bounded. Hovering gives the real item tooltip.
- **`FauxScrollFrameTemplate` parks its scrollbar outside the frame's right
  edge**, which put the navigator's bar inside the results pane.
  `Bz_ContainScrollBar` pulls both in.
- The **Back** button's height is measured off `Atr_Buy1_Button`, which
  already sits on the frame's bottom bar, rather than guessing an offset.

---

## Scanning

Three scans share one event frame; each ignores `AUCTION_ITEM_LIST_UPDATE`
unless it is the one running, so Auctionator's own scanning passes through
untouched. `getAll` is disabled on this server, so all of them are paged and
gated on `CanSendAuctionQuery`.

1. **Token price** (`From AH`) — cheapest per-token buyout, written into the
   rate chain with provenance. Filters by **itemID 975001, never by name**:
   `100 Bazaar Tokens` is a different item at a worse per-token price and
   would silently corrupt the rate. Bid-only listings (`buyoutPrice == 0`)
   are skipped, not read as free. Non-975001 results are filed into the
   Bazaar Tokens category, with their token value read from a leading number
   in the name.
2. **One item's listings** (drill-down) — condensed by (price per item, stack
   size) into `10 stacks of 1` lines. Bid-only listings are kept and shown as
   such; they are real competition.
3. **Category queue** (`Price these`) — walks whatever is on screen, so the
   filter narrows it, skipping bound items. One paged scan per item,
   sequential because the throttle serialises us anyway. Cancellable from
   four directions: the button, drilling in, leaving the tab, closing the AH.

Every listing scan records the cheapest per-item buyout into `prices`, so
drilling into an item teaches the catalogue permanently.

---

## Buying

**The tab does not buy.** Clicking a listing hands the item to Auctionator's
Buy tab — `Atr_SelectPane(BUY_TAB)`, then `Atr_Search_Box:SetText('"name"')`
and `Atr_Search_Onclick()` — and shows a **Back to Bazaar** button there.

The name is **quoted**, or Auctionator substring-matches and a name that is a
prefix of another's drags in the wrong auctions.

This is deliberate. Buying is not one call: `GetAuctionItemInfo` indices are
valid only for the page currently loaded, and our listings are condensed
across up to eight pages, so a row here corresponds to no single live
auction. Auctionator already re-queries, rebuilds a match list, handles
partial fills and confirms — in code tested by people spending real gold.
Reimplementing that would put the project's only irreversible failure mode in
its newest code.

---

## Testing

`harness14`–`harness23`, plain Lua 5.1, no client. See README-TESTS.md.

Bugs these caught, or failed to:

- **The tests all passed while the headers were blank.** Every harness called
  `SelectCategory` or `OpenItem` before looking at a header, so none observed
  the fresh-init state a `/reload` produces. `harness17` §0 now runs
  immediately after `Init` with no interaction, and was verified to fail
  against the broken code before being kept.
- **A mock that lied.** The harness `SetPoint` understood only the five-arg
  form; WoW also accepts `SetPoint(point, x, y)`, and short-form calls were
  silently recorded as `(0, 0)`. Assertions about those anchors passed or
  failed for reasons unconnected to the code.
- **A duplicated edit.** A slice-based edit whose end index preceded its
  start index duplicated a block instead of replacing it; the file compiled
  and the harness stayed green because the assertions were reading the stale
  widgets. Exact-string replacement with a uniqueness assertion is the
  convention for a reason.
- `RebuildDisplay` clears the status line, so a completion message set before
  it is wiped instantly.
