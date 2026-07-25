# Ascension Client & Server Findings

Everything here was established empirically (screenshots, debug dumps of real
scan data, purchase attempts) during development. These facts drive most
design decisions in the Finder.

## Client baseline
- WotLK **3.3.5** client with Ascension modifications. Stock 3.3.5 addons
  generally work.
- **Awesome WotLK** binary patches are present (confirmed via the shipped
  APIDocumentation addon). Extra API available includes:
  `GetItemInfoInstant(link)`, `GetItemStats(itemLink)`,
  `GetItemStatDelta(link1, link2)`, `CopyToClipboard(text)`,
  `FlashWindow()`, C_NamePlate, TTS.
- **No per-instance price API exists** (APIDocumentation audited 2026-07):
  `GetItemInfo.vendorPrice` is the same cached field that lies for scaled
  items; `GetItemInfoInstant` returns no price; container and tooltip
  APIs are stock. The merchant **buyback list remains the only ground
  truth for an instance's sell price** - no read-only shortcut exists.
  Confirmed live 2026-07: at a merchant, scaled bag items render NO
  Sell Price money line at all.  `GameTooltip:SetBuybackItem(slot)` DOES
  render the buyback entry's per-instance server tooltip (real il/req) -
  the learning hook uses it to tell same-name variants apart.
- The **APIDocumentation** addon (backported retail-style docs) is installed
  at `Interface/AddOns/APIDocumentation/Documentation/*.lua` — the Lua files
  ARE the docs (systems incl. `AuctionDocumentation.lua`,
  `Awesome_WotLKDocumentation.lua`, `ItemDocumentation.lua`). The retail
  `/api` slash command is not wired up. `/devconsole` opens Ascension's dev
  console (Ascension UI Development Tools addon).
- Auction system API surface is **stock 3.3.5** (no custom AH functions):
  `QueryAuctionItems(name, minLevel, maxLevel, invTypeIndex, classIndex,
  subClassIndex, page, isUsable, qualityIndex[, getAll])`, 50 results/page,
  `CanSendAuctionQuery`, `GetAuctionItemInfo` (12-13 returns),
  `GetAuctionItemLink`, `GetAuctionItemTimeLeft`,
  `GetAuctionItemClasses/SubClasses/InvTypes`, sort API present.

## Server policy / behavior
- **getAll (full scan) is disabled.** All scanning must be paged queries.
- **Server-side sorting is unreliable** for the custom item population;
  page order can shift between fetches of the same query (causes duplicate/
  near-duplicate pages during paged scans; occasionally items are missed or
  double-seen across page boundaries — inherent to paging an unstable sort).
- The **minLevel/maxLevel query parameters cannot be trusted** to filter
  (observed returning items far outside the range). Level filtering must be
  enforced client-side. Sending the params anyway is harmless.
- The **isUsable filter barely filters on this classless server** (all
  proficiencies known to everyone; it does NOT gate by required level).
- **The invTypeIndex parameter DOES work** (verified 2026-07) - the first
  server-side filter on this list that can be trusted. Querying
  `(class=2 Armor, subclass=3 Leather, invTypeIndex=1)` returned 305 items,
  all `INVTYPE_HEAD`, versus the full leather population unfiltered. Three
  traps, all verified in-game:
  1. The index is a 1-based ordinal into `GetAuctionInvTypes(class, subclass)`,
     which returns **alternating token/display pairs** - the index for entry
     `i` is `(i+1)/2`.
  2. **The order is NOT the natural paperdoll order** and does not match the
     Finder's own `FDR_ARMOR_SLOTS`. Server order for Cloth/Leather is
     HEAD 1, NECK 2, SHOULDER 3, BODY 4, CHEST 5, WAIST 6, LEGS 7, FEET 8,
     WRIST 9, HAND 10, FINGER 11. Indexing by position rather than by token
     gets HEAD/NECK/SHOULDER right and then silently queries the wrong slot
     (wrist->waist). **Always resolve by token.**
  3. **The list varies by subclass.** Cloth (2) and Leather (3) return an
     identical 11 entries; Miscellaneous (1) returns 14 - the same first 11
     in the same order, plus TRINKET 12, CLOAK 13, HOLDABLE 14. Build the
     token->index map per (class, subclass); do not share it.
- **There is no `INVTYPE_ROBE` index anywhere; the server folds robes into
  CHEST.** Verified: a cloth chest query (invTypeIndex 5) returned 26 robes
  + 24 chests. So a Chest selection needs only one query, not two.
- `GetAuctionInvTypes`' second (display) return marks which slots Blizzard's
  own Browse tab offers for that subclass - e.g. NECK/BODY/FINGER are `nil`
  under Cloth and Leather. It is a **static client table, not derived from
  the live AH population**, so on a server that mints custom items it must
  NOT be used to skip a query: a custom leather neck would be dropped
  silently. `INVTYPE_CLOAK` is flagged `nil` under every armor subclass,
  which is why the Finder keeps cloaks on the client-side path.
- **`PlaceAuctionBid` is hardware-event protected**: calling it from an
  event handler or OnUpdate is blocked ("AddOn ... prevented the call of
  the secure function"). It must be called inside a real click handler.
  (This is why Auctionator's own buy flow ends in a confirm-button click.)
- Query pacing: ~1 page per throttle tick; `CanSendAuctionQuery()` gates.

## THE BIG ONE: per-instance item scaling
Ascension scales item *instances* server-side **without encoding it in the
item link**. Verified case: four listings of one item, byte-identical links
(`item:7758:0:0:0:0:0:0:0:<lvl>`), but four different real required levels
(56/39/42/43) and different real damage/DPS/ilvl per the server tooltips.

Consequences:
- Every **link-based API lies** for scaled instances: `GetItemStats`,
  `GetItemInfo` (ilvl, reqLevel), `GameTooltip:SetHyperlink` all resolve to
  whichever version of that itemID the client cached first.
- The **only per-instance truths available**:
  1. `GetAuctionItemInfo("list", i)` → the `level` return is the listing's
     REAL required level (matches Blizzard Browse display). This is the
     cornerstone: it distinguishes scaled variants.
  2. `GameTooltip:SetAuctionItem("list", i)` → the SERVER-rendered tooltip
     for that exact listing (real damage/DPS/ilvl/req/procs) — but only
     while that listing's page is currently loaded in the "list" results.
- Tooltip "Item Level"/"Requires Level" routinely differ from
  `GetItemInfo` values (e.g. tooltip il 41 vs API 34) — same root cause.
- **Owning an item repoints the cache at that instance** (inferred from a
  reproduced failure, 2026-07): buying a scaled AH item wrote ITS values
  into the on-disk item cache. Within the session `GetItemInfo` kept
  returning the first-cached (pre-purchase) variant; after `/reload` it
  returned the purchased instance's values instead. So the in-session
  cache is first-write-wins, the on-disk cache is last-write-wins, and a
  reload flips link/ID-based APIs to the latest-seen variant. Practical
  consequence: for any item you own, `GetItemInfo`'s "base" ilvl/req/price
  converge on the owned instance — cached values are at their least
  trustworthy exactly for bag items. (This is why the vendor-price
  predictor keeps its own persisted lowest-il sighting registry; see
  VENDOR-PRICE-RESEARCH.md.)
- An identity tuple of **name + stackCount + buyoutPrice + requiredLevel**
  reliably pins a specific purchasable listing (used for exact buying).

## Item identity / rolls (from real scan-dump analysis)
- Custom Ascension items occupy an **itemID range ≥ ~2,000,000**; stock IDs
  coexist.
- Links are the stock 9-field format. `uniqueId` (field 8) is **always 0**;
  field 9 is the viewer's level.
- **Stat rolls are encoded as distinct suffixIDs**: same base item + same
  suffix *name* with different rolls = different suffix IDs (e.g. 9041 vs
  9141). Same (itemID, suffixID) ⇒ identical stats (0 mismatches observed).
  So a link (minus fields 8-9) fully determines the item — EXCEPT for the
  scaling system above, which is invisible in links entirely.
- Same-name items can differ by roll, by quality tier, by ilvl, and by
  scale level. Name-based grouping/identification is never safe.
- `GetItemStats` DOES include suffix-roll stats (works on links), and also
  returns Ascension custom stat keys: **`PVE_POWER`** (observed constant 48
  across all items for a given character — an account/character attribute,
  not an item stat; useless for sorting/filtering) and **`PVP_POWER`**.
  `ITEM_MOD_DAMAGE_PER_SECOND_SHORT` is present on weapons as a float.
- Mystic enchants: item-link enchant field observed 0 on all scanned AH
  gear so far; enchant *effects* are tooltip spell-text, not stat lines,
  and would require tooltip scanning to read.

## Auction house UI facts
- Blizzard's **Browse tab is per-listing accurate** (uses SetAuctionItem);
  it is the reference UI for verifying scaled items.
- Auctionator's Buy tab is name-keyed and shows one cached version for all
  variants of a name (see AUCTIONATOR-INTERNALS.md).
- AuctionFrame's real rendered size on this client does NOT match the stock
  758×447 assumption (right edge sits farther out). Anchor right/bottom UI
  to AuctionFrame's own corners rather than computing offsets.

## Bazaar / Tiraxis vendor system
Established 2026-07 by the Phase 0 probe (`Atr_BazaarProbe`, throwaway) run
against Tiraxis, the Reliquary Weapons Vendor. 321 merchant entries captured
across all six gossip branches.

### The merchant API is stock and complete
- Tiraxis is a **stock MerchantFrame** (`MERCHANT_ITEMS_PER_PAGE` 10, real
  `MerchantFrame.page`); Ascension only skins it and adds Buy Limited /
  List Limited / Sell Grey.
- **`GetMerchantNumItems()` returns the WHOLE list, not the visible page**
  (75 and 107 observed against a 10-per-page display). One `MERCHANT_SHOW`
  per gossip branch harvests everything; no page walking needed.
- `MERCHANT_SHOW` fires normally from every gossip sub-menu.

### Return arities (do not assume — these differ from stock 3.3.5a)
- **`GetMerchantItemCostInfo(i)` returns THREE values**
  `(honorPoints, arenaPoints, itemCount)` — the 3.3.0-era shape, not the
  single `itemCount` of later 3.3.5 builds. For a token item: `0, 0, 1`.
- `GetMerchantItemCostItem(i, 1)` → `(texture, value, itemLink)`.
  `GetMerchantItemCostItem(i, 2)` → **`(nil, 0)`, arity 2 with a leading
  nil** — not an empty return.
- `GetMerchantItemInfo(i)`'s 7th return (`extendedCost`) is the **number 1,
  not boolean true**. Test truthiness, never `== true`.
- Consequence: "does this item cost an alt currency" must be decided by
  **`cost1[3]` being a non-nil item link**. Testing `cost1[n] ~= nil` across
  the tuple gives false positives, because a literal `0` sits in the tuple
  for gold-priced items (this bit the probe's own heuristic).

### Currency and catalog shape
- **Bazaar Token is itemID `975001`.** It is the sole alt currency Tiraxis
  uses — 294 of 294 token-priced entries.
- Token-priced items carry gold price 0; the branch
  *"I want to browse your goods."* is Tiraxis's ordinary gold-priced weapon
  stock (27 items, stock itemIDs 851+) and is excluded automatically by the
  `cost1[3]` test.
- **The six gossip branches are disjoint sets — 294 unique itemIDs, zero
  overlap.** "Browse Bazaar" is NOT a superset; a full catalog requires
  visiting every branch.
- Branch sizes / token cost ranges: Browse Bazaar 107 (100–7500),
  Stones of Retreat 75 (350), Heirlooms 53 (500–800), Convenience Items 46
  (35–2000), Consumables 11 (60–250), Mysterious Wares 2 (125).
- Gossip option titles arrive **wrapped in escape sequences**
  (`|TInterface/ICONS/inv_item_stonen:40:40:-22:0|t|rStones of Retreat`);
  strip `|T...|t`, `|c%x%x%x%x%x%x%x%x` and `|r` before using as a category
  key.
- Bazaar itemIDs sit in several bands (696k, 777k, 818k, 975k, 1.5M, 8.2M),
  so the "custom items are ≥ ~2,000,000" note above describes AH gear only
  and does not generalise to vendor items.

### Binding vocabulary — includes a custom type
Merchant tooltips render binding lines reliably (321/321). The vocabulary
across token-priced items:

| line | count | tradeable |
|---|---|---|
| Binds when used | 104 | yes |
| Binds when equipped | 96 | yes |
| **Binds to realm** | 58 | **no — custom Ascension bind type** |
| Binds when picked up | 5 | no |
| *(no binding line)* | 31 | yes |

**`Binds to realm` is not a stock string** and has no `ITEM_BIND_*` global.
Omitting it misclassifies all 53 heirlooms plus Mysterious Wares as
tradeable. Any bind check must list it explicitly.

Net: **231 of 294 token items are tradeable** — the Bazaar tab's catalog is
fully derivable from the merchant, with no hand-curated item list.

### Other tooltip lines worth harvesting
- `Prestigious` — a custom quality tier line (53 items).
- `You don't own this vanity item` / `You haven't collected this appearance`
  — per-character vanity ownership, with affirmative forms observed in game
  (`You own this vanity item`, `You've collected this appearance`). Usable
  for an "hide items I already own" filter.
- `Heirlooms cannot be equipped until you have a level 60 character on this
  realm!` — a gating line, not a bind line.

### Later findings (2026-07, during Bazaar tab work)
- The Bazaar Token's own currency icon is `Interface\Icons\Spell_Shadow_Teleport`
  (from `GetMerchantItemCostItem`'s first return).
- `CopyToClipboard(text)` exists on this client (documented in
  `Awesome_WotLKDocumentation.lua`) and is by far the fastest way to get bulk
  diagnostics out of the game, given pasting from the client is awkward.
- **`GetItemInfo` returns nil for uncached custom items.** Bazaar item IDs sit
  in several bands (696k, 777k, 818k, 975k, 1.5M, 8.2M) and a fresh client has
  seen none of them, so anything that needs a name or icon for a custom item
  must ship it rather than look it up.
- **3.3.5 FontStrings wrap once a width is set, and nothing clips them.** There
  is no `SetWordWrap` or `SetMaxLines` on this client; the only reliable way to
  keep a name on one line is to measure it with `GetStringWidth` and chop.
- `FauxScrollFrameTemplate` anchors its scrollbar OUTSIDE the scroll frame's
  right edge. A narrow list placed next to another panel will put its bar
  inside that panel unless the bar is explicitly re-anchored.
- Auction listings with `buyoutPrice == 0` are bid-only. They are real
  competition and should be displayed, but they carry no purchase price and
  must never be read as free — the token market has many of them.
- Auction house cut on a sale is 5%. Any "what would I clear" figure that
  ignores it is optimistic on every row, worst on expensive items.
