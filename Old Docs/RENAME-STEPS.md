# Rename: Auctionator → Auctionator-Finder-Ascension

Do all of this with the game closed.

1. Rename the addon folder:
   `Interface/AddOns/Auctionator` → `Interface/AddOns/Auctionator-Finder-Ascension`
2. Inside it, delete `Auctionator.toc` and add the new
   `Auctionator-Finder-Ascension.toc` (folder name and toc filename must match).
3. Replace `Auctionator.lua` with the patched version
   (rename-proof `addonName` lookups at lines 522/630, version nag neutered at 462,
   all tagged `FINDER_TAB`).
4. Migrate SavedVariables (otherwise price DB, history, and settings appear wiped):
   - `WTF/Account/<acct>/SavedVariables/Auctionator.lua` → `Auctionator-Finder-Ascension.lua`
     (also rename the `.lua.bak` if present)
   - For EACH character: `WTF/Account/<acct>/<realm>/<char>/SavedVariables/Auctionator.lua`
     → `Auctionator-Finder-Ascension.lua` (+ `.bak`)
5. One manual check I couldn't do (file not in project): open `Auctionator.xml` and
   search for `Interface\AddOns\Auctionator` — if any texture paths are hardcoded,
   update them to the new folder name. Relative paths need no change.
6. `Auctionator_Finder_Debug` stays exactly as is (separate addon, no dependency link).
7. Delete the two stub folders `Auctionator_Price_Database` and
   `Auctionator_Pricing_History`. They are upstream's SavedVariables shells and both
   declare `## Dependencies: Auctionator`, so they'd stop loading after the rename
   anyway. Your main toc declares the same variables itself, so your main SV file
   already holds an identical copy of the price DB and pricing history — the stubs
   only duplicate the data and double the logout write.
   BEFORE deleting, verify: open the renamed
   `WTF/Account/<acct>/SavedVariables/Auctionator-Finder-Ascension.lua` in a text
   editor and confirm `AUCTIONATOR_PRICE_DATABASE = {` and
   `AUCTIONATOR_PRICING_HISTORY = {` both appear with real content. (If your stub
   tocs somehow differ from upstream's, check them for any extra variable names
   first.) The orphaned `WTF/.../SavedVariables/Auctionator_Price_Database.lua` and
   `Auctionator_Pricing_History.lua` files can be kept as backups or deleted.
8. Note: the new toc also fixes a pre-existing missing comma in the SavedVariables
   line (`...MEAN_PRICE_DATABASE AUCTIONATOR_LAST_SCAN_TIME...`). Because of that
   typo, mean-price data and last-scan-time were never being saved; from now on
   they will persist across sessions.

Rules going forward:
- NEVER install stock Auctionator (launcher or manual) alongside this fork — both
  define the same `Atr_*` globals and `AUCTIONATOR_*` SavedVariables and will corrupt
  each other. Before the rename, an accidental install merely overwrote the folder;
  now it would coexist and clash.
- The toc `Version` is now 2.9.9 and the in-game "newer version" reminder is
  permanently disabled, so upstream releases (3.0.0+) will never nag.
