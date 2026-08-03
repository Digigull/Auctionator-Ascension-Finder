# Vendor research cleanup plan — retire the formula-discovery scaffolding

**Status: DONE — Phases 0–3 (2026-08). Phase 4 GATED on the seed verdict.**
Self-contained execution plan. It removes the machinery that existed only to
*discover* the Ascension vendor-price formula, now that pricing is solved by the
shipped confirmed-price seed table (`VENDOR-SEED-PLAN.md`). It does **not** touch
the live prediction path, and it deliberately keeps one piece of "research"
instrumentation — the `.log` recorder — until the seed experiment returns its
verdict.

**What shipped (Phases 0–3):**
- Phase 0 — inlined the `Fdr_ResearchItemID` link→itemID helper at the scan
  engine's AH-variant call site, de-coupling it from the ledger (pure refactor).
- Phase 1 — deleted the research target ledger (`AuctionatorFinderResearch.lua`,
  `/atrtarget`, `AUCTIONATOR_FINDER_RESEARCH`, `Fdr_Research_Absorb`) and its
  tests (`ledger_relevance_test.lua` and the split-load/leak-audit references).
- Phase 2 — removed the debug/upload channel entirely: `Fdr_SaveDebugDump`,
  `Fdr_ResearchDump_Enabled`, `AUCTIONATOR_FINDER_DEBUG`, the `researchDump`
  setting, the "Research capture" options row, `/atrresearch`, and the
  `Auctionator_Finder_Debug/` stub addon.
- Phase 3 — archived the research journal to `archive/VENDOR-PRICE-RESEARCH.md`,
  and dropped the `/atrtarget` / research-capture references from
  `VENDOR-PRICE.md`, `README.md`, and `README-SHARING.txt`.

The predictor (`AuctionatorHints.lua`) was not touched, so no live prediction
changed. The full `tests/` sweep is green.

## Why (one paragraph)

The vendor-price investigation is finished. The server model
(`price = base × multiplier`) is understood, the shape-refit path is a proven
dead end (`VENDOR-PRICE.md`), and the real lever — reducing the `est` share by
shipping confirmed prices — is now in the code as the seed table. What remains
from the research era is **scaffolding built to find and haul data**: a
per-scan *research target ledger* that ranks unpriced gear into a shopping list,
an upload channel that dumps that ledger for offline analysis, the options
toggles that gate it, and a 1,120-line research journal. None of it feeds a
tooltip. Per this repo's own hard-won lesson (`CLAUDE.md`: the old Projects
workspace died of context bloat), dead scaffolding is not free — it is surface
area every future reader has to understand and every test has to carry. Delete
it.

## The one rule that governs this whole plan

**Removing research scaffolding must not change a single live prediction.**
Prove it: the `est` shape, `db.trk`, `db.cb`, `db.base`, and `db.obs` are the
live estimator and are **out of scope** here (see the KEEP table). If a step
would alter what `Atr_VendorPredict_Get` returns, it is the wrong step.

## What is bloat (remove) vs load-bearing (keep)

Dependency map verified 2026-08 against the live code.

### REMOVE — pure research scaffolding, no live-price role

| Component | Path : anchor | Notes |
|-----------|---------------|-------|
| Research target ledger (whole file) | `AuctionatorFinderResearch.lua` (611 lines) | ranks unpriced scaled gear into a `/atrtarget` shopping list; built for harvest #5 |
| Ledger producer call | `AuctionatorFinder.lua:2764` `Fdr_Research_Absorb()` | runs after every scan |
| Debug/upload dump + target hijack | `AuctionatorFinder.lua:2812-2877` (`Fdr_ResearchDump_Enabled`, `Fdr_SaveDebugDump`, the `Fdr_Research_Targets`/`Fdr_Research_Wants` write) | default OFF; writes `AUCTIONATOR_FINDER_DEBUG` |
| Research options row + slash | `AuctionatorFinderOptions.lua:102-107, 127, 140, 178-193` | "Research capture" checkbox, `/atrresearch` |
| SavedVariables registration | `Auctionator-Finder-Ascension.toc:9` (`AUCTIONATOR_FINDER_RESEARCH`), `:37` (file load) | |
| Debug companion addon | `Auctionator_Finder_Debug/` (whole folder) | self-labelled "Safe to delete"; the upload sink |
| Research journal | `Old Docs/VENDOR-PRICE-RESEARCH.md` (~1,120 lines) | evidence trail; archive/trim, do not carry as live doc |
| Ledger tests | `tests/ledger_relevance_test.lua`; refs in `tests/finder_split_load_test.lua:60-61`, `tests/finder_split_leak_audit.lua:24` | remove/adjust with the code |

### KEEP — live prediction machinery (research origins, but load-bearing)

| Component | Path : anchor | Serves |
|-----------|---------------|--------|
| `Atr_VendorShape_Estimate` + shape tables | `AuctionatorHints.lua:1021-1130` | the `est` fallback tier |
| `Atr_VendorTrack_Floor` / `db.trk` | `AuctionatorHints.lua:1082-1091, 1207, 1436-1438` | plateau + est multiplier cap (self-healing) |
| `db.cb` / `Atr_VendorCB_Note` | `AuctionatorHints.lua:957-984, 1173, 1176-1186, 1271` | x1.0 sighting + candidate base (survives re-cache/reload) |
| `db.obs` / `db.base` | throughout the vendor block | learned / interp / plateau / trusted-base tiers |

Do not touch the KEEP column. "Do not refit the est shape" (`VENDOR-PRICE.md`,
"What NOT to do") still holds — this plan removes the *target-finding* rig, not
the estimator.

### GATED — the `.log` calibration recorder (keep until the seed verdict lands)

`AuctionatorHints.lua:1429-1443` writes the 500-sample `db.log` with
`smp.pp`/`smp.pt`; `/atrvp` reads it back (`:1300-1313`). This *is* research
instrumentation — but it is the **live measurement instrument for the seed
experiment just shipped**. `VENDOR-SEED-PLAN.md` decides win/kill by reading
`pt == "seed"` median error from `.log` in a returned dump. **Removing `.log`
before that verdict blinds the experiment.** So its retirement is Phase 4,
gated on the seed decision — not part of the initial cleanup.

## The coupling that must be handled first

`Fdr_ResearchItemID` (`AuctionatorFinderResearch.lua:71-75`) is a global link→
itemID helper, but it is called by the **scan engine's AH-variant path**, not
just the ledger: `AuctionatorFinder.lua:1075`
(`local itemID = Fdr_ResearchItemID (rec.link);`). Deleting the research file
without addressing this breaks that call. The helper is trivial:

```lua
return tonumber (link:match ("|Hitem:(%d+)") or link:match ("^item:(%d+)"));
```

**Before removing the file, inline this derivation** into `AuctionatorFinder.lua`
(a file-local `Fdr_ItemIDfromLink`, or fold it into `Fdr_AHVariant_Record`), and
repoint line 1075. Then the research file has no remaining live caller.

## Phases (each ends green: `luac5.1 -p` + full `tests/` sweep)

### Phase 0 — inline the shared helper (no behaviour change) — DONE
Inline `Fdr_ResearchItemID` per above; repoint `AuctionatorFinder.lua:1075`.
Verify: AH-variant recording still derives the same itemID (extend or eyeball
`finder_split_load_test.lua`). This phase alone must leave `/atrtarget` still
working — it is a pure refactor that de-couples the engine from the ledger.

### Phase 1 — remove the research target ledger — DONE
- Delete `AuctionatorFinderResearch.lua`; drop `.toc:37` and the
  `AUCTIONATOR_FINDER_RESEARCH` name from `.toc:9`.
- Remove `Fdr_Research_Absorb()` at `AuctionatorFinder.lua:2764` and the
  target-hijack block in `Fdr_SaveDebugDump` (`:2861-2874`). Decide the fate of
  `Fdr_SaveDebugDump`/`Fdr_ResearchDump_Enabled` with Phase 2.
- Remove the research options row + `/atrresearch`
  (`AuctionatorFinderOptions.lua:102-107, 127, 140, 178-193`) and the
  `researchDump` setting doc (`:28`).
- Remove/replace the ledger tests: delete `tests/ledger_relevance_test.lua`;
  drop the `Fdr_Research_Targets` / `ATRRESEARCHTARGET` assertions from
  `tests/finder_split_load_test.lua:60-61`; drop the file from the split-leak
  list in `tests/finder_split_leak_audit.lua:24`.
- Grep for stragglers: `Fdr_Research`, `atrtarget`, `researchDump`,
  `AUCTIONATOR_FINDER_RESEARCH` must return nothing but comments you also clean.

### Phase 2 — retire the debug/upload channel — DONE (removed in full)
`Auctionator_Finder_Debug/` is self-labelled "Safe to delete" and default OFF.
With the ledger gone its only remaining job is the raw-scan dump. If nothing
still needs offline raw scans, delete the folder and `Fdr_SaveDebugDump` /
`AUCTIONATOR_FINDER_DEBUG` entirely; otherwise keep the raw-scan dump but strip
the research-target portion (already done in Phase 1). Note the seed measurement
does **not** use this channel — it reads `AUCTIONATOR_VENDOR_LEARNED.log`
directly — so removing it does not affect the seed experiment.

### Phase 3 — docs — DONE
- Archive `VENDOR-PRICE-RESEARCH.md`: it is a completed journal. Either move it
  under an `Old Docs/archive/` marker or trim it to the handful of still-true
  conclusions (the model, the "What NOT to do" list, the SavedVariables field
  key) and let `VENDOR-PRICE.md` remain the single living spec.
- Update `VENDOR-PRICE.md` and `README.md` to drop any `/atrtarget` / research-
  capture references.
- Flip this plan's status to DONE and note what shipped.

### Phase 4 — GATED: retire the `.log` calibration recorder (AFTER the seed verdict)
Only once `VENDOR-SEED-PLAN.md`'s win/kill decision is recorded:
- Remove the `.log` write + 500-cap (`AuctionatorHints.lua:1442-1443`), the
  pre-write calibration block (`:1410-1428`, the `pp/pwhy/pest`/`pt` capture and
  `smp` sample), and the `/atrvp` seed-stats readout (`:1300-1313`).
- **Keep** the `db.trk` write co-located at `:1436-1438` — it is live (KEEP
  table). Excise only the `.log`/`smp` lines around it; do not remove the whole
  branch.
- `tests/vendor_seed_test.lua` asserts `pt` classification via `db.log`; retire
  or rewrite it in the same change so the suite stays green.
Until that verdict, leave all of this exactly as shipped.

## Verification (do not skip)

1. `luac5.1 -p` every edited `.lua`.
2. Full `tests/` sweep green after **each** phase (`lua5.1 tests/<t>.lua`).
3. **Break-the-code discipline** (`README-TESTS.md`): any test kept as a
   regression guard must be seen to fail against the pre-change file, or it is
   not evidence.
4. **Live-prediction invariance:** the intended proof that KEEP is untouched —
   `Atr_VendorPredict_Get` and the `db.obs/base/cb/trk` structures are
   byte-identical before/after Phases 0-3 (Phase 4 only removes `.log`, still no
   predictor change). A quick guard: run a predictor fixture (seed a few
   `db.obs` rungs, assert interp/plateau/est outputs) before and after; the
   numbers must match.
5. Confirm the removed globals are truly dead: post-cleanup grep for
   `Fdr_Research`, `atrtarget`, `atrresearch` returns nothing.

## What NOT to do

- **Do not touch the estimator.** `Atr_VendorShape_Estimate`, `db.trk`,
  `db.cb`, `db.base`, `db.obs` are live. This plan removes target-finding, not
  pricing. Refitting the shape is still a proven dead end.
- **Do not remove `.log` before the seed verdict.** It is the seed experiment's
  measurement instrument; Phase 4 is gated for exactly this reason.
- **Do not delete the research file before Phase 0.** The scan engine calls
  `Fdr_ResearchItemID`; inline it first or you break AH-variant recording.
- **Do not rewrite merged history / open a second PR for the same change.**
  Follow `CLAUDE.md`'s sync-before-next-change loop.
