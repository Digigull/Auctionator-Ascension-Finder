# CLAUDE.md — Auctionator-Finder-Ascension

A fork of **Auctionator** for **Project Ascension** (custom WotLK 3.3.5 private
server, classless). Adds two AH tabs: **Finder** (gear search + instance-exact
buying + vendor-price learning) and **Bazaar** (Bazaar Token economy board).

This file is orientation only. It deliberately contains **no feature history** —
that lives in the architecture docs, which are the source of truth. If this file
and a doc disagree, the doc wins.

---

## 1. First move in any session

**Before your first code edit** (not before answering a question), run
`sh test.sh all`. It takes seconds, and a failure usually means an
**attached source file is stale**, not that the code is broken — the harnesses
extract blocks verbatim from the shipped files, so they detect drift between
what is attached here and what is deployed in-game. This has already caught a
stale `Auctionator.lua` missing an entire session's work.

If `lua5.1` isn't present: `apt-get install -y lua5.1` works.

Read the harnesses only when one is failing. Running them is nearly free —
one line of output each. Reading one costs 20–30 KB.

## 2. Load only what the task needs

The repo is ~1.6 MB. Do not read it all; you will run out of room and start
guessing. Pick a row, load those files, ignore everything else.

| Task | Load | Test with |
|---|---|---|
| Finder scan / filter / sort / group / buy | `FINDER-ARCHITECTURE.md`, `AuctionatorFinder.lua` | `sh test.sh AuctionatorFinder.lua` |
| Vendor prices, scaling detector, predictor | `VENDOR-PRICE.md`, `ASCENSION-CLIENT-NOTES.md`, `AuctionatorHints.lua` | `sh test.sh AuctionatorHints.lua` |
| Bazaar tab | `BAZAAR-ARCHITECTURE.md`, `AuctionatorBazaar.lua` | `sh test.sh AuctionatorBazaar.lua` |
| Sell tab layout / AuctionFrame art | `AUCTIONATOR-INTERNALS.md`, `Auctionator.lua` | `sh test.sh Auctionator.lua` |
| Tab plumbing / upstream integration | `AUCTIONATOR-INTERNALS.md`, `Auctionator.lua`, `Auctionator.xml` | `sh test.sh Auctionator.lua Auctionator.xml` |
| A failing harness | that harness + `README-TESTS.md` | `lua5.1 harnessN.lua` |

**Never read these into context:**
- `AuctionatorVendor.lua` — line 8 is a single 100,000-character packed blob
  (upstream armory data). Untouched, unreadable, ~25k tokens of noise.
- `Auctionator.xml` (61 KB) — grep it; do not read it whole.
- The harnesses, unless one is failing. Run them instead — see section 1.
- `VENDOR-PRICE-RESEARCH.md` (61 KB) — **archived**. The vendor estimator is
  closed; `VENDOR-PRICE.md` is the live reference. Open the archive only to
  reopen the investigation.

**Ask before starting** if the task doesn't map cleanly to one row. Two rows at
once is usually two sessions.

---

## 3. Hard rules — these fail silently

Each of these has shipped a real bug. They are ordered by how often they bite.

**Editing**
1. **Exact-string replacement with assertions**, in the four big sources.
   Fail loudly if the anchor
   isn't found exactly once. Never slice by index — a slice whose end preceded
   its start once *duplicated* a block instead of replacing it, and the file
   still compiled and the harness still passed.
2. **Line endings differ per file and must be preserved.**
   CRLF: `Auctionator.lua`, `AuctionatorConfig.lua`, `AuctionatorHints.lua`,
   `Auctionator.xml`, `AuctionatorVendor.lua`, all `.toc`.
   LF: `AuctionatorFinder.lua`, `AuctionatorBazaar.lua`, all docs and harnesses.
   Verify by counting CRs before and after, not by eye.
3. **`--` is illegal inside an XML comment.** It produces a file the client
   silently refuses to parse. After any `.xml` edit:
   `python3 -c "import xml.etree.ElementTree as E; E.parse('Auctionator.xml')"`

**Compiling**
4. **Lua 5.1 only** (WoW's dialect). `luac5.1 -p` after every edit.
5. **`AuctionatorFinder.lua` sits near Lua's 200-local ceiling.** A file's top
   level is a function, so file-scope `local`s cap at 200. `luac` blames the
   file's *last line*, not the offending declaration, and wrapping in
   `do ... end` buys nothing. Run `sh headroom.sh`. New stateless helpers should
   be **globals**, not locals — costs one deleted word, no call-site edits.
   See `FINDER-ARCHITECTURE.md` § Namespace for which subsystems are global.

**Ascension runtime traps** (full detail in `ASCENSION-CLIENT-NOTES.md`)
6. **Link-based APIs lie for scaled equipment.** `GetItemInfo`, `GetItemStats`,
   `SetHyperlink` all resolve to whichever variant the client cached. The only
   per-instance truths are `GetAuctionItemInfo("list", i)`'s `level` return and
   `SetAuctionItem`/`SetBuybackItem` server tooltips. This is *the* root cause
   in this project; suspect it first.
7. **`AUCTION_ITEM_LIST_UPDATE` is not a reply to your query.** It fires for any
   change to the client's auction list and carries no query identity. Absence of
   a row proves nothing unless the batch is confirmed yours.
8. **`PlaceAuctionBid` is hardware-event protected** — only from a real click.
9. **Options panels capture their save function by value.** `f.okay` is set at
   XML OnLoad, so `hooksecurefunc` on the global save name is **inert** for the
   Okay path. Wrap the panel's own `okay`/`cancel`. Blizzard also calls `okay()`
   on every registered category whether shown or not, so build rows at login.
10. **A dead texture path does not clear the region** — `SetTexture` fails
    silently and the old art stays. Build paths from the `addonName` vararg.
11. **3.3.5 FontStrings wrap once a width is set, and nothing clips them.**
    Measure with `GetStringWidth` and chop.

---

## 4. How much process a change deserves

Most changes are small. Match the checks to the change; running everything on
everything is how this project got slow.

| You changed | Do this | Skip |
|---|---|---|
| Docs, comments, this file | nothing | all of it |
| A string, number or constant in existing code | `luac5.1 -p` | tests, headroom |
| Logic inside an existing function | `luac5.1 -p`, `sh test.sh <file>` | headroom, break-test |
| Added a **file-scope** `local` | + `sh headroom.sh` | |
| Added a function or new behaviour | + extend the nearest harness | break-test (that's for regression tests) |
| Edited a `.xml` | + the XML parse check (rule 3) | |
| Edited a **CRLF** file (rule 2) | + CR count before/after | |
| About to ship / end of session | `sh test.sh all` | |

Two judgement calls that are *not* ceremony, because both failure modes are
silent: anything touching a **texture path** or an **options panel** gets
checked against rules 9 and 10 regardless of size.

Everything in section 3 still applies — but a rule applies **when its trigger
is met**, not on every edit. If you find yourself running the full suite to
change a chat message, stop.

## 5. Testing policy

`sh test.sh` maps changed files to the harnesses that actually load them. The
map is derived by grepping the harnesses at runtime, so it cannot drift.

- **While iterating:** `sh test.sh <file you edited>`. That's the required bar.
- **Before shipping / end of session:** `sh test.sh all`.
- **Do not run the full suite after every small edit.** That habit is what made
  this project slow. Scoped runs are not a shortcut; a harness that does not
  load the file you changed cannot observe your change.

Some harnesses print their own PASS banner instead of a failure count, so
**never grep for `0 failures`** — grep for `^FAIL`, `lua5.1:`, and
`[1-9][0-9]* failures`. `test.sh` already does this.

`harness10`, `harness11`, `harness12`, `harness27` extract `FINDER_TAB` blocks
**verbatim from the shipped `AuctionatorHints.lua`**. A nil-global failure there
usually means a stale Hints file in the working directory, not a broken test.

Two rules that earn their keep (rationale in `README-TESTS.md` § Conventions):
- **Verify a new regression test by breaking the code**, then restoring it
  byte-identically. A test never seen to fail is not evidence.
- **When a break does *not* fail, suspect the mock before the code.** Every
  `function () end` stub is a hole in the test's reach.

---

## 6. Files

| File | Role | Covered by |
|---|---|---|
| `AuctionatorFinder.lua` | **NEW** — the entire Finder (5.8k lines, at the local ceiling) | `FINDER-ARCHITECTURE.md` |
| `AuctionatorBazaar.lua` | **NEW** — the entire Bazaar tab + 294-row seed catalogue | `BAZAAR-ARCHITECTURE.md` |
| `AuctionatorHints.lua` | Patched — 6 `FINDER_TAB` blocks: scaling detector, vendor learning + predictor, sale messages, tooltip override, AH variant prices, best-price label | `FINDER-ARCHITECTURE.md`, `VENDOR-PRICE.md` |
| `Auctionator.lua` | Patched — tab integration, version nag neutered, Sell tab layout, frame art | `AUCTIONATOR-INTERNALS.md` |
| `Auctionator.xml` | Patched — `Atr_ListTabs` reduced to Current/Ledger | `AUCTIONATOR-INTERNALS.md` |
| `AuctionatorConfig.lua/.xml` | Patched — default-tab label, tooltip options rows | `AUCTIONATOR-INTERNALS.md` |
| `Auctionator-Finder-Ascension.toc` | Fork toc; registers all SavedVariables | — |
| `Auctionator_Finder_Debug.toc` | Stub addon; research-dump upload channel (optional now — see `VENDOR-PRICE.md`) | `VENDOR-PRICE.md` |
| everything else | **untouched upstream** — do not edit | — |

Docs live flat in the repo root (there is no `docs/` directory):
`ASCENSION-CLIENT-NOTES.md` (read first — most design decisions exist because of
a fact in it), `AUCTIONATOR-INTERNALS.md`, `FINDER-ARCHITECTURE.md`,
`BAZAAR-ARCHITECTURE.md`, `VENDOR-PRICE.md`, `README-TESTS.md`,
`CHANGES.md`.

---

## 7. Standing context

- **Never install stock Auctionator alongside this.** Same `Atr_*` globals and
  `AUCTIONATOR_*` SavedVariables; they corrupt each other. Toc is pinned 2.9.9
  and the upstream nag is neutered. Upstream 2.9.9 was evaluated and not merged.
- **The user cannot easily paste from the game.** Iterate via screenshots, chat
  sale messages, and the debug dump (Research checkbox + `/reload`, written to
  `WTF/Account/<acct>/SavedVariables/Auctionator_Finder_Debug.lua`).
  `CopyToClipboard(text)` exists on this client and is the fastest route for
  bulk diagnostics.
- **Slash commands:** `/atrtarget` `/atrprices` `/atrresearch` `/atrgear`
  `/atrahdb` `/atrvp`, each `on|off` where it toggles.
- **Distribution:** Ascension's launcher-based manager, fed from the
  Ascension-Addons GitHub org. WowUp does not support Ascension. The fork's
  folder name keeps the launcher from overwriting it.
