AUCTIONATOR + FINDER TAB (Ascension.gg edition) - SHARING GUIDE
================================================================

WHAT TO PACKAGE
---------------
Zip these three folders from your Interface/AddOns/ directory, keeping the
folder structure intact:

  Auctionator/                    (the full folder - includes the three
                                   modified/new files: Auctionator.lua,
                                   Auctionator.toc, AuctionatorFinder.lua,
                                   plus all original files, Images/, Locales/)
  Auctionator_Price_Database/     (original stub - price DB storage)
  Auctionator_Pricing_History/    (original stub - history storage)

Installation for recipients: extract all folders into
  <Ascension>/Interface/AddOns/
and fully restart the client. In the AddOns list, "Allow Non-Launcher
AddOns" must be enabled (it is by default for anyone already using
non-launcher addons).

MODIFIED / NEW FILES (vs the warperia / Ascension-Addons build)
---------------------------------------------------------------
  Auctionator.lua        - small integration patches, all tagged FINDER_TAB:
                           tab registration, tab-click handling, panel
                           show/hide, init hook
  Auctionator.toc        - loads AuctionatorFinder.lua; adds
                           AUCTIONATOR_FINDER_SETTINGS to SavedVariables
  AuctionatorFinder.lua  - NEW: the entire Finder tab

DISTRIBUTION CHANNELS (Ascension-specific)
------------------------------------------
WowUp does NOT support Ascension - it only detects official Blizzard
retail/classic installations, not custom 3.3.5 clients. The Ascension
ecosystem uses these channels instead, in rough order of reach:

1. THE ASCENSION LAUNCHER (best long-term option)
   The launcher's Addons tab is the official one-click install channel.
   It is fed from the Ascension-Addons GitHub organization:
     https://github.com/Ascension-Addons
   There is already an Auctionator repo there:
     https://github.com/Ascension-Addons/Auctionator
   Route: fork it, apply the Finder changes, open a pull request. If
   accepted, every launcher user gets the Finder with automatic updates.
   The org front page describes their request/PR process.

2. GITHUB RELEASE (immediate, manual install)
   Publish your own repo (fork of Ascension-Addons/Auctionator keeps
   attribution and diff history clean) and attach a release zip built as
   described above. Users download + extract. This is the standard
   pattern for community 3.3.5 addons.

3. ASCENSION FORUM + DISCORDS
   forum.ascension.gg has an Addons category for sharing. The #addons /
   #addons-discussion channels on the Ascension Discord, and the
   SzylerAddons community Discord (linked from the pinned messages there),
   are where addon-savvy players actually look. A post with screenshots
   of the Finder tab will travel.

CREDIT / LICENSE NOTES
----------------------
Auctionator is by Zirco, community-maintained for Ascension by the
Ascension-Addons contributors. When sharing, credit the original addon
and note this build adds the Finder tab on top of the Ascension build.
Contributing the changes back to Ascension-Addons/Auctionator is the
cleanest way to honor that lineage.

SUPPORT NOTES FOR YOUR USERS
----------------------------
- Settings (Compare, No Warn) persist per account automatically.
- Known Ascension quirk: the server rescales item levels and level
  requirements; the Finder displays the base values the AH API reports
  and enforces the level-range filter against those displayed values.
