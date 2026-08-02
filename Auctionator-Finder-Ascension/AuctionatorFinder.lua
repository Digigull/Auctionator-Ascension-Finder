-------------------------------------------------------------------------------
-- AuctionatorFinder.lua  (v2)
--
-- "Finder" tab for the auction house: Blizzard-style item search that pages
-- through every result with normal queries (works with getAll disabled),
-- then displays auctions with client-side sortable columns.
--
-- v2 additions:
--   * Grouping: identical NON-equippable items (same exact item link) are
--     consolidated into one row (total qty, xN listings, cheapest price).
--     Weapons/armor stay as individual rows since their stats differ.
--     Toggle via the "Group" checkbox.
--   * iLvl column for equippable items (via GetItemInfo).
--   * Stat column: dropdown lists every stat found on gear in the current
--     results (via GetItemStats); picking one shows a sortable stat column.
--     Columns reflow automatically when the stat column appears/disappears.
--
-- Integration points (see patched Auctionator.lua):
--   * ATR_FINDER_TAB, Atr_Finder_Init(), Atr_Finder_Panel, Atr_Finder_OnTabClick(i)
-------------------------------------------------------------------------------

local addonName, addonTable = ...;
local zc = addonTable and addonTable.zc;

local function FT (s)
	if (ZT) then return ZT(s); end
	return s;
end

-------------------------------------------------------------------------------
-- constants / state
-------------------------------------------------------------------------------

local FDR_NULL		= 0;
local FDR_PREQUERY	= 1;
local FDR_POSTQUERY	= 2;
local FDR_PAUSED	= 3;	-- waiting on the large-search confirmation

local FDR_NUM_ROWS		= 15;
local FDR_ROW_HEIGHT	= 20;
-- Page limits.  There is deliberately NO fixed page cap any more: a scan runs
-- until the server serves a short page, which is the real end of the result
-- set.  What remains is a RUNAWAY GUARD, because "run until a short page" is
-- not by itself terminating on this server -- the duplicate-page path
-- (CheckForDuplicatePage) advances gFdr_Page after 4 failed retries, so a
-- server that keeps re-serving one full page would otherwise loop forever.
-- The guard is derived from the server's OWN reported total (page 0's
-- GetNumAuctionItems), so it is a fact about the query rather than an
-- arbitrary number, with slack for the pages the dup path skips past.
local FDR_MAX_PAGES		= 0;	-- >0 forces a hard page limit; 0 = no fixed limit
local FDR_PAGE_SLACK	= 25;	-- pages allowed ABOVE the server's reported total
local FDR_RUNAWAY_PAGES	= 2000;	-- absolute stop when the server reports no usable total
local FDR_WARN_PAGES	= 25;	-- prompt before scans larger than this
local FDR_QUERY_TIMEOUT	= 8;

local gFdr_State		= FDR_NULL;
local gFdr_Page			= 0;
local gFdr_Query		= nil;
local gFdr_QuerySentAt	= 0;
local gFdr_Elapsed		= 0;
local gFdr_OnFinish		= nil;		-- FINDER_TAB: full-scan driver callback (see below)
local gFdr_WaitTicks	= 0;		-- FINDER_TAB: OnUpdate ticks since the page last moved
local gFdr_RetryHold	= 0;		-- FINDER_TAB: ticks to wait before re-querying a stale page
local gFdr_Results		= {};		-- raw auction records from the scan
local gFdr_Display		= {};		-- what's actually shown (post-grouping)
local gFdr_TotalPages	= 0;

local gFdr_DupRetries	= 0;
local gFdr_SkippedPages	= 0;

local gFdr_SortKey		= "peritem";
local gFdr_SortAsc		= true;

local gFdr_SelectedCats	 = {};		-- ordered list of selected category leaves (filter, OR)
local gFdr_SelectedCatSet = {};		-- leaf key -> true
local gFdr_SpecQueue	 = {};		-- server query specs for the current scan
local gFdr_SpecIdx		 = 1;
local gFdr_CapHit		 = false;

-- The page at which the scan gives up.  Normally unreachable: the scan ends
-- when a page comes back short.  Exposed as a global so the harness and any
-- future diagnostic can read the live ceiling.
function Fdr_PageCeiling ()

	if (FDR_MAX_PAGES > 0) then return FDR_MAX_PAGES; end
	if (gFdr_TotalPages > 0) then return gFdr_TotalPages + FDR_PAGE_SLACK; end
	return FDR_RUNAWAY_PAGES;
end
local gFdr_CatSum		 = nil;		-- cached category-selection summary
local gFdr_JumpPending	 = false;	-- Finder -> Buy tab jump in progress
local gFdr_BackEnabled	 = false;	-- Back-to-Finder button state

-- Buy tab -> Finder redirect (see "gear on the Buy tab comes back here").
-- ONE table rather than four locals: this file sits against Lua 5.1's
-- 200-local file-scope ceiling (see CLAUDE.md), and the wrappers need to keep
-- the originals they replaced somewhere.
--   skip  - lowercased name we already bounced once; a second search of the
--           same item is let through, so the Buy tab is never unreachable
--   told  - the long form of the chat note has been shown this session
--   prev* - the upstream functions this file wrapped, called through
local gFdr_Redir		 = { skip = nil, told = false };
local gFdr_AutoMinLvl	 = nil;		-- min-level value we auto-filled (nil = user-owned)
local gFdr_AutoUsable	 = false;	-- we checked Usable automatically
local gFdr_UsableUserOff = false;	-- user unchecked it after our auto-check; respect that
local gFdr_AutoReq		 = false;	-- we checked My Lvl automatically
local gFdr_ReqUserOff	 = false;	-- user unchecked it after our auto-check
local gFdr_LvlMin		 = nil;		-- client-side level range (read live at rebuild)
local gFdr_LvlMax		 = nil;
local gFdr_ReqCap		 = nil;		-- "My Lvl": hide items requiring more than this

local gFdr_SelectedStats = {};		-- ordered list of selected stat keys (filter, AND)
local gFdr_SelectedSet	 = {};		-- same keys as a set for quick lookup
local gFdr_StatKeys		 = {};		-- stats discovered in current results
local FDR_MAX_STAT_COLS	 = 3;		-- columns shown for the first N selected stats
local FDR_DPS_KEY		 = "ITEM_MOD_DAMAGE_PER_SECOND_SHORT";
local gFdr_HasDPS		 = false;	-- weapons present -> automatic DPS column

local gFdr_SearchText	= "";
local gFdr_MinLevel		= nil;
local gFdr_MaxLevel		= nil;
local gFdr_UsableOnly	= nil;

local gFdr_Rows			= {};
local gFdr_Headers		= {};
gFdr_ScaledNames		= gFdr_ScaledNames or {};	-- item names with known scaled variants (session)

-------------------------------------------------------------------------------
-- helpers
-------------------------------------------------------------------------------

local function Fdr_IgnoreWarn ()
	return AUCTIONATOR_FINDER_SETTINGS and AUCTIONATOR_FINDER_SETTINGS.ignoreLargeWarn;
end

-- one setting, mirrored by the dialog checkbox and the toolbar checkbox
function Atr_Finder_SetIgnoreWarn (v)

	AUCTIONATOR_FINDER_SETTINGS = AUCTIONATOR_FINDER_SETTINGS or {};
	AUCTIONATOR_FINDER_SETTINGS.ignoreLargeWarn = v and true or false;

	if (Atr_Finder_NoWarnCheck)		then Atr_Finder_NoWarnCheck:SetChecked (v and true or nil); end
	if (Atr_Finder_WarnIgnoreCheck)	then Atr_Finder_WarnIgnoreCheck:SetChecked (v and true or nil); end
end

local function Fdr_MoneyString (copper)

	if (copper == nil or copper <= 0) then
		return "|cff888888--|r";
	end

	local gold	 = math.floor (copper / 10000);
	local silver = math.floor ((copper % 10000) / 100);
	local cop	 = copper % 100;

	if (gold > 0) then
		return string.format ("|cffffffff%d|r|cffffd70bg|r |cffffffff%02d|r|cffc7c7cfs|r", gold, silver);
	elseif (silver > 0) then
		return string.format ("|cffffffff%d|r|cffc7c7cfs|r |cffffffff%02d|r|cffeda55fc|r", silver, cop);
	else
		return string.format ("|cffffffff%d|r|cffeda55fc|r", cop);
	end
end

local gFdr_TimeLeftText = { "|cffff4444S|r", "|cffffff44M|r", "|cff44ff44L|r", "|cff4488ffV|r" };

local function Fdr_SetMessage (msg)
	if (Atr_Finder_Message) then
		Atr_Finder_Message:SetText (msg or "");
	end

	-- FINDER_TAB: during a Full Scan run the dialog covers the Finder tab, so
	-- the engine's live page counter has to be echoed there or the user has no
	-- way to tell a working scan from a hung one.
	if (Fdr_FS_EchoProgress) then Fdr_FS_EchoProgress (msg); end
end

local function Fdr_StatDisplayName (key)

	local s = _G[key];
	if (type(s) == "string" and s ~= "") then
		return s;
	end
	-- fall back to a cleaned-up token: ITEM_MOD_ATTACK_POWER_SHORT -> Attack Power
	s = key:gsub ("^ITEM_MOD_", ""):gsub ("_SHORT$", ""):lower():gsub ("_", " "):gsub ("^%l", string.upper);
	return s;
end

local function Fdr_GetStats (rec)

	if (rec.stats == nil) then
		if (GetItemStats and rec.link) then
			local ok, t = pcall (GetItemStats, rec.link);
			rec.stats = (ok and type(t) == "table") and t or {};
		else
			rec.stats = {};
		end
	end

	return rec.stats;
end

local function Fdr_GetStat (rec, key)

	if (not key or not rec.equippable) then
		return 0;
	end

	-- A verified value wins, exactly as rec.trueDPS already beats the
	-- cached DPS.  This feeds the stat COLUMNS and Fdr_SortValue alike, so
	-- sorting by a stat orders rows by the real listings rather than by
	-- whichever scale variant the client cached.
	if (rec.trueStats and rec.trueStats[key]) then
		return rec.trueStats[key];
	end

	return Fdr_GetStats(rec)[key] or 0;
end

-------------------------------------------------------------------------------
-- column layout (reflows when the stat column is shown/hidden)
-------------------------------------------------------------------------------

local function Fdr_NumStatCols ()
	return math.min (#gFdr_SelectedStats, FDR_MAX_STAT_COLS);
end

-- builds { {key, x, width, justify}, ... } for the current stat selection;
-- the name column absorbs whatever width the stat columns don't take
local function Fdr_BuildLayout ()

	local ROW_W		= 690;
	local GAP		= 2;
	local STAT_W	= 46;

	local nstats = Fdr_NumStatCols();

	local tail =
	{
		{ "ilvl",		40,  "RIGHT"  },
		{ "level",		32,  "RIGHT"  },
		{ "qty",		32,  "RIGHT"  },
		{ "timeleft",	38,  "CENTER" },
	};

	if (gFdr_HasDPS) then
		tinsert (tail, { "dps", 46, "RIGHT" });
	end

	local i;
	for i = 1, nstats do
		tinsert (tail, { "stat"..i, STAT_W, "RIGHT" });
	end

	tinsert (tail, { "buyout",	112, "RIGHT" });
	tinsert (tail, { "peritem",	 96, "RIGHT" });

	local fixed = 0;
	for _, c in ipairs (tail) do
		fixed = fixed + c[2] + GAP;
	end

	local layout = {};
	local x = 20;

	local namew = ROW_W - fixed - GAP;
	tinsert (layout, { "name", x, namew, "LEFT" });
	x = x + namew + GAP;

	for _, c in ipairs (tail) do
		tinsert (layout, { c[1], x, c[2], c[3] });
		x = x + c[2] + GAP;
	end

	return layout;
end

local function Fdr_ApplyColumnLayout ()

	local layout = Fdr_BuildLayout();
	local active = {};

	for _, col in ipairs (layout) do

		local key, x, w = col[1], col[2], col[3];
		active[key] = true;

		local hdr = gFdr_Headers[key];
		if (hdr) then
			hdr:SetPoint ("TOPLEFT", x, -74);
			hdr:SetWidth (w);
			if (hdr.label.SetWidth) then hdr.label:SetWidth (w - 4); end
			hdr:Show();
		end

		for i = 1, FDR_NUM_ROWS do
			local cell = gFdr_Rows[i] and gFdr_Rows[i].cells[key];
			if (cell) then
				if (key == "name") then
					cell:SetPoint ("LEFT", 22, 0);		-- right of the icon
					cell:SetWidth (w - 22);
				else
					cell:SetPoint ("LEFT", x - 18, 0);	-- rows start at panel x=20
					cell:SetWidth (w);
				end
			end
		end
	end

	-- hide stat headers/cells beyond the current selection
	for key, hdr in pairs (gFdr_Headers) do
		if (not active[key]) then
			hdr:Hide();
			for i = 1, FDR_NUM_ROWS do
				local cell = gFdr_Rows[i] and gFdr_Rows[i].cells[key];
				if (cell) then cell:SetText (""); end
			end
		end
	end

	-- stat header labels follow the selected stats
	local i;
	for i = 1, Fdr_NumStatCols() do
		local hdr = gFdr_Headers["stat"..i];
		if (hdr) then
			hdr.label:SetText (Fdr_StatDisplayName (gFdr_SelectedStats[i]));
		end
	end
end

-------------------------------------------------------------------------------
-- sorting
-------------------------------------------------------------------------------

local BIGNUM = 999999999999;

local function Fdr_SortValue (rec, key)

	if (key == "name")		then return string.lower (rec.name or ""); end
	if (key == "level")		then return rec.level or 0; end
	if (key == "qty")		then return rec.count or 0; end
	if (key == "timeleft")	then return rec.timeLeft or 0; end
	if (key == "ilvl")		then return rec.trueIlvl or rec.ilvl or 0; end

	if (key == "dps") then
		return rec.trueDPS or Fdr_GetStat (rec, FDR_DPS_KEY);
	end

	local statIdx = key:match ("^stat(%d)$");
	if (statIdx) then
		return Fdr_GetStat (rec, gFdr_SelectedStats[tonumber (statIdx)]);
	end

	if (key == "buyout") then
		if (rec.buyoutPrice and rec.buyoutPrice > 0) then return rec.buyoutPrice; end
		return BIGNUM;
	end

	if (key == "peritem") then
		if (rec.perItem and rec.perItem > 0) then return rec.perItem; end
		return BIGNUM;
	end

	return 0;
end

local function Fdr_Comparator (a, b)

	local av = Fdr_SortValue (a, gFdr_SortKey);
	local bv = Fdr_SortValue (b, gFdr_SortKey);

	if (av == bv) then
		local an = string.lower (a.name or "");
		local bn = string.lower (b.name or "");
		if (an ~= bn) then
			return an < bn;
		end
		return Fdr_SortValue (a, "peritem") < Fdr_SortValue (b, "peritem");
	end

	if (gFdr_SortAsc) then
		return av < bv;
	else
		return av > bv;
	end
end

local function Fdr_SortAndRedisplay ()

	table.sort (gFdr_Display, Fdr_Comparator);
	Atr_Finder_Redisplay ();
end

local function Fdr_UpdateHeaderArrows ()

	for key, btn in pairs (gFdr_Headers) do
		if (key == gFdr_SortKey) then
			btn.arrow:SetText (gFdr_SortAsc and "|cff88ccff^|r" or "|cff88ccffv|r");
		else
			btn.arrow:SetText ("");
		end
	end
end

local function Fdr_HeaderClick (key)

	if (gFdr_SortKey == key) then
		gFdr_SortAsc = not gFdr_SortAsc;
	else
		gFdr_SortKey = key;
		-- stats and item level: highest first feels right by default
		gFdr_SortAsc = not (key:match ("^stat%d$") or key == "ilvl" or key == "dps");
	end

	Fdr_UpdateHeaderArrows ();
	Fdr_SortAndRedisplay ();
end

-------------------------------------------------------------------------------
-- grouping / display list construction
-------------------------------------------------------------------------------

local FDR_ARMOR_CLASS = 2;	-- index of Armor in GetAuctionItemClasses (stable in 3.3.5)

-- Summarizes the category selection. Armor is special: material subclasses
-- (Cloth/Leather/...) and slots (Legs/Chest/...) combine with AND — materials
-- OR'd among themselves, slots OR'd among themselves — so "Leather + Legs +
-- Chest" means leather items that are legs or chest, not all leather.
local function Fdr_CatSummary ()

	local s = { classSet = {}, otherSubs = {}, armorAll = false,
				mats = {}, matLeaves = {}, nMats = 0,
				slotTokens = {}, slotLeaves = {}, nSlots = 0, armorName = nil };

	for _, leaf in ipairs (gFdr_SelectedCats) do

		if (leaf.kind == "class") then
			if (leaf.ci == FDR_ARMOR_CLASS) then
				s.armorAll	= true;
				s.armorName	= leaf.label;
			else
				s.classSet[leaf.label] = true;
			end

		elseif (leaf.kind == "subclass") then
			if (leaf.ci == FDR_ARMOR_CLASS) then
				s.mats[leaf.label]	= true;
				s.nMats				= s.nMats + 1;
				tinsert (s.matLeaves, leaf);
				s.armorName			= leaf.className;
			else
				s.otherSubs[leaf.className] = s.otherSubs[leaf.className] or {};
				s.otherSubs[leaf.className][leaf.label] = true;
			end

		elseif (leaf.kind == "slot") then
			for t in pairs (leaf.tokens) do
				s.slotTokens[t] = true;
			end
			tinsert (s.slotLeaves, leaf);
			s.nSlots = s.nSlots + 1;
		end
	end

	if (not s.armorName and GetAuctionItemClasses) then
		s.armorName = select (FDR_ARMOR_CLASS, GetAuctionItemClasses());
	end
	s.armorName		= s.armorName or "Armor";
	s.armorSelected	= s.armorAll or s.nMats > 0 or s.nSlots > 0;

	return s;
end

-- Server-side inventory-type filter (arg 4 of QueryAuctionItems). The index
-- is a 1-based ordinal into GetAuctionInvTypes(class, subclass), which returns
-- alternating token/display pairs.
--
-- Verified on Ascension 2026-07 (see ASCENSION-CLIENT-NOTES):
--   * the list order is NOT our FDR_ARMOR_SLOTS order (waist 6, wrist 9),
--   * its length varies by subclass (Cloth/Leather 11, Miscellaneous 14),
--   * INVTYPE_ROBE has no entry at all - the server folds robes into
--     INVTYPE_CHEST, so a chest query returns both.
-- Resolve by token, never by position.
local gFdr_InvTypeCache = {};

local function Fdr_InvTypeMap (classIndex, subclassIndex)

	if (not classIndex or not subclassIndex or not GetAuctionInvTypes) then
		return nil;
	end

	local ckey = classIndex.."/"..subclassIndex;

	if (gFdr_InvTypeCache[ckey] == nil) then

		local map	= {};
		local list	= { GetAuctionInvTypes (classIndex, subclassIndex) };
		local any	= false;

		local i;
		for i = 1, #list, 2 do
			local token = list[i];
			if (type (token) == "string" and map[token] == nil) then
				map[token]	= (i + 1) / 2;
				any			= true;
			end
		end

		-- Never cache a failed probe: GetAuctionInvTypes can come back empty
		-- before the AH has finished opening, and a cached empty map would
		-- disable slot filtering for the rest of the session.
		if (not any) then
			return nil;
		end

		gFdr_InvTypeCache[ckey] = map;
	end

	return gFdr_InvTypeCache[ckey];
end

-- Resolves every selected slot to a server inv-type index for one armor
-- subclass. Returns a sorted { index, label } list, or nil if ANY selected
-- slot has no index there (INVTYPE_CLOAK has none under Cloth or Leather).
-- nil means "fall back to an unfiltered scan for this material": an item the
-- server never sends cannot be recovered by the client-side equipLoc check,
-- so a partial server filter would silently lose rows.
local function Fdr_SlotSpecTypes (slotLeaves, subclassIndex)

	if (not slotLeaves or #slotLeaves == 0) then
		return nil;
	end

	local map = Fdr_InvTypeMap (FDR_ARMOR_CLASS, subclassIndex);
	if (not map) then
		return nil;
	end

	local out	= {};
	local seen	= {};

	local _, leaf;
	for _, leaf in ipairs (slotLeaves) do

		local got = false;

		local token;
		for token in pairs (leaf.tokens or {}) do
			local idx = map[token];
			if (idx) then
				got = true;
				if (not seen[idx]) then
					seen[idx] = true;
					tinsert (out, { index = idx, label = leaf.label });
				end
			end
		end

		if (not got) then
			return nil;
		end
	end

	table.sort (out, function (a, b) return a.index < b.index; end);

	return out;
end

-- Builds the list of server queries for the current category selection.
-- Class/subclass selections each get their own server-filtered scan
-- (autoAccept: the server guarantees the category). Armor slot selections
-- collapse into one Armor-wide scan filtered client-side by equip location.
local function Fdr_BuildSpecQueue ()

	local specs = {};

	if (#gFdr_SelectedCats == 0) then
		tinsert (specs, { class = nil, subclass = nil, autoAccept = false, label = "" });
		return specs;
	end

	local s = Fdr_CatSummary ();

	-- non-armor: class scans, plus subclass scans not covered by a class scan
	local classAll = {};
	for _, leaf in ipairs (gFdr_SelectedCats) do
		if (leaf.kind == "class" and leaf.ci ~= FDR_ARMOR_CLASS) then
			classAll[leaf.ci] = true;
			tinsert (specs, { class = leaf.ci, subclass = nil, autoAccept = true, label = leaf.label });
		end
	end
	for _, leaf in ipairs (gFdr_SelectedCats) do
		if (leaf.kind == "subclass" and leaf.ci ~= FDR_ARMOR_CLASS and not classAll[leaf.ci]) then
			tinsert (specs, { class = leaf.ci, subclass = leaf.si, autoAccept = true, label = leaf.label });
		end
	end

	-- armor: materials AND slots
	if (s.armorSelected) then

		if (s.nSlots == 0) then
			-- no slot restriction: server-filtered, auto-accepted
			if (s.armorAll) then
				tinsert (specs, { class = FDR_ARMOR_CLASS, subclass = nil, autoAccept = true, label = s.armorName });
			else
				for _, leaf in ipairs (s.matLeaves) do
					tinsert (specs, { class = FDR_ARMOR_CLASS, subclass = leaf.si, autoAccept = true, label = leaf.label });
				end
			end
		else
			-- Slot restriction. With a material also chosen, push the slot down
			-- to the server's inventory-type filter: "Leather + Head" becomes
			-- one small query instead of scanning all leather and discarding
			-- most of it. autoAccept stays false regardless - the client-side
			-- equipLoc check is kept as a net against a wrong index, which also
			-- means a server that ignores the parameter behaves as before.
			if (s.nMats > 0 and not s.armorAll) then
				for _, leaf in ipairs (s.matLeaves) do

					local invTypes = Fdr_SlotSpecTypes (s.slotLeaves, leaf.si);

					if (invTypes) then
						local _, it;
						for _, it in ipairs (invTypes) do
							tinsert (specs, { class = FDR_ARMOR_CLASS, subclass = leaf.si,
											  invType = it.index, autoAccept = false,
											  label = leaf.label.." "..it.label });
						end
					else
						tinsert (specs, { class = FDR_ARMOR_CLASS, subclass = leaf.si,
										  autoAccept = false, label = leaf.label });
					end
				end
			else
				tinsert (specs, { class = FDR_ARMOR_CLASS, subclass = nil, autoAccept = false, label = s.armorName });
			end
		end
	end

	return specs;
end

-- OR across selected category leaves; autoAccept records came from a scan
-- whose server filter already guarantees a selected category
local function Fdr_PassesCategoryFilter (rec)

	if (#gFdr_SelectedCats == 0) then
		return true;
	end

	if (rec.autoAccept) then
		return true;
	end

	local s = gFdr_CatSum or Fdr_CatSummary ();

	if (s.classSet[rec.itemType]) then
		return true;
	end

	local subs = s.otherSubs[rec.itemType];
	if (subs and subs[rec.itemSubType]) then
		return true;
	end

	if (s.armorSelected and rec.itemType == s.armorName) then
		local matOK		= s.armorAll or s.nMats == 0 or s.mats[rec.itemSubType] == true;
		local slotOK	= s.nSlots == 0 or (rec.equipLoc and s.slotTokens[rec.equipLoc] == true);
		if (matOK and slotOK) then
			return true;
		end
	end

	return false;
end

-- Strips the per-instance fields from an item link payload so that two
-- physically identical items produce the same key:
--   field 8 = uniqueId (random seed), field 9 = linkLevel (seller's level).
-- Any extra fields Ascension appends are preserved untouched.
local function Fdr_NormalizeLink (link)

	if (not link) then return nil; end

	local payload = link:match ("|Hitem:([%-%d:]+)|h") or link:match ("^item:([%-%d:]+)$");
	if (not payload) then return link; end

	local fields = {};
	for f in payload:gmatch ("[^:]+") do
		tinsert (fields, f);
	end

	if (fields[8]) then fields[8] = "0"; end
	if (fields[9]) then fields[9] = "0"; end

	return table.concat (fields, ":");
end

-- Group key for equippable items: normalized identity + exact stat fingerprint
-- + quality + item level. Same name is NOT sufficient (Ascension items with
-- identical names can carry different rolls); identical key IS sufficient.
local function Fdr_GearGroupKey (rec)

	local parts = {};
	for statKey, val in pairs (Fdr_GetStats (rec)) do
		tinsert (parts, statKey.."="..tostring (val));
	end
	table.sort (parts);

	return (Fdr_NormalizeLink (rec.link) or rec.name or "?")
			.."#q"..tostring (rec.quality or 0)
			.."#i"..tostring (rec.ilvl or 0)
			.."#L"..tostring (rec.level or 0)
			.."#"..table.concat (parts, ";");
end

local function Fdr_PerItem (rec)

	if (rec.buyoutPrice and rec.buyoutPrice > 0 and rec.count and rec.count > 0) then
		return math.floor (rec.buyoutPrice / rec.count);
	end
	return 0;
end

local Fdr_PassesStatFilter;		-- fwd decl

-- enforced against rec.level: the same value shown in the Lvl column, so the
-- filter always agrees with what's on screen
local function Fdr_PassesLevelFilter (rec)

	if (gFdr_LvlMin and (rec.level or 0) < gFdr_LvlMin) then return false; end
	if (gFdr_LvlMax and (rec.level or 0) > gFdr_LvlMax) then return false; end
	if (gFdr_ReqCap and (rec.level or 0) > gFdr_ReqCap) then return false; end
	return true;
end

local function Fdr_PassesFilters (rec)
	return Fdr_PassesLevelFilter (rec) and Fdr_PassesCategoryFilter (rec) and Fdr_PassesStatFilter (rec);
end

Fdr_PassesStatFilter = function (rec)

	if (#gFdr_SelectedStats == 0) then
		return true;
	end

	if (not rec.equippable) then
		return false;		-- stat filter active: only gear can qualify
	end

	local i;
	for i = 1, #gFdr_SelectedStats do
		if (Fdr_GetStat (rec, gFdr_SelectedStats[i]) == 0) then
			return false;
		end
	end

	return true;
end

local Fdr_PostRebuild;		-- set below; runs after every display rebuild

function Atr_Finder_RebuildDisplay ()

	gFdr_Display = {};
	gFdr_CatSum  = Fdr_CatSummary ();

	gFdr_LvlMin = nil;
	gFdr_LvlMax = nil;
	if (Atr_Finder_MinLevel) then
		local n = Atr_Finder_MinLevel:GetNumber();
		if (n and n > 0) then gFdr_LvlMin = n; end
	end
	if (Atr_Finder_MaxLevel) then
		local n = Atr_Finder_MaxLevel:GetNumber();
		if (n and n > 0) then gFdr_LvlMax = n; end
	end

	gFdr_ReqCap = nil;
	if (Atr_Finder_ReqCheck and Atr_Finder_ReqCheck:GetChecked() and UnitLevel) then
		gFdr_ReqCap = UnitLevel ("player");
	end

	local grouping = Atr_Finder_GroupCheck and Atr_Finder_GroupCheck:GetChecked();

	if (not grouping) then

		local i;
		for i = 1, #gFdr_Results do
			local rec = gFdr_Results[i];
			rec.perItem		= Fdr_PerItem (rec);
			rec.numListings	= 1;
			if (Fdr_PassesFilters (rec)) then
				tinsert (gFdr_Display, rec);
			end
		end

		if (Fdr_PostRebuild) then Fdr_PostRebuild (); end
		return;
	end

	local groups = {};		-- link -> group display rec

	local i;
	for i = 1, #gFdr_Results do

		local rec = gFdr_Results[i];
		rec.perItem = Fdr_PerItem (rec);

		if (not Fdr_PassesFilters (rec)) then
			-- filtered out entirely

		elseif (not rec.link) then

			rec.numListings = 1;
			tinsert (gFdr_Display, rec);

		else
			local key = rec.equippable and Fdr_GearGroupKey (rec) or rec.link;
			local g = groups[key];

			if (g == nil) then

				g = {};
				for k, v in pairs (rec) do g[k] = v; end

				g.numListings	= 1;
				g.totalQty		= rec.count or 1;
				g.groupKey		= key;
				g.members		= { rec };

				-- per-instance fields never belong to a merged face directly;
				-- they are re-derived below once all members are known
				g.trueIlvl		= nil;
				g.trueDPS		= nil;
				g.trueLines		= nil;
				g.trueStats		= nil;
				g.fdrVerified	= nil;
				g.fdrGone		= nil;

				groups[key] = g;
				tinsert (gFdr_Display, g);
			else
				g.numListings	= g.numListings + 1;
				g.totalQty		= g.totalQty + (rec.count or 1);
				tinsert (g.members, rec);

				-- keep the cheapest per-item listing as the face of the group
				if (rec.perItem > 0 and (g.perItem == 0 or rec.perItem < g.perItem)) then
					g.perItem		= rec.perItem;
					g.buyoutPrice	= rec.buyoutPrice;
					g.count			= rec.count;
					g.timeLeft		= rec.timeLeft;
					g.owner			= rec.owner;
				end
			end
		end
	end

	-- for groups, the qty column shows the TOTAL quantity across listings;
	-- (for gear that's simply the number of identical copies listed)
	for key, g in pairs (groups) do
		g.count = g.totalQty;

		-- the face may show verified values only when EVERY member was
		-- verified and they agree (per-instance scaling can differ even
		-- inside one group; disagreement keeps the face dimmed)
		--
		-- Stats merge PER KEY, exactly as ilvl and DPS merge: two listings
		-- can share an agility roll and differ on stamina, and dropping the
		-- agreed half would send the column back to the cached number for no
		-- reason.  A dropped key falls back to the cache and, because the
		-- stat cells dim per cell, says so.
		--
		-- The captured TOOLTIP is different in kind: it is one document, not
		-- a bag of fields, so it transfers only when every member captured
		-- exactly the same one.  Otherwise the face keeps the cached body and
		-- the scaled warning, and a click opens the per-listing window.
		local ti, td, tstats, tlines, allv;
		allv = true;
		local mi;
		for mi = 1, #g.members do
			local m = g.members[mi];
			if (not m.fdrVerified) then
				allv = false;
				break;
			end
			if (mi == 1) then
				ti = m.trueIlvl;
				td = m.trueDPS;
				tlines = m.trueLines;

				-- copied, never shared: the merge below prunes keys, and a
				-- face must not be able to edit its own member
				if (m.trueStats) then
					tstats = {};
					local k, v;
					for k, v in pairs (m.trueStats) do tstats[k] = v; end
				end
			else
				if (ti ~= m.trueIlvl) then ti = nil; end
				if (td ~= m.trueDPS)  then td = nil; end

				if (not Fdr_SameTrueLines (tlines, m.trueLines)) then tlines = nil; end

				if (tstats) then
					local ms = m.trueStats;
					local k, v;
					-- clearing existing fields during a pairs() walk is
					-- explicitly allowed in Lua 5.1; adding them is not
					for k, v in pairs (tstats) do
						if (ms == nil or ms[k] ~= v) then tstats[k] = nil; end
					end
				end
			end
		end
		if (allv) then
			g.trueIlvl	= ti;
			g.trueDPS	= td;
			g.trueStats	= tstats;
			g.trueLines	= tlines;
		end
	end

	if (Fdr_PostRebuild) then Fdr_PostRebuild (); end
end

function Atr_Finder_HasDPSColumn ()
	return gFdr_HasDPS;
end

-- weapons in the display -> DPS column appears; called after every rebuild
local function Fdr_UpdateDPSColumn ()

	local has = false;
	local i;
	for i = 1, #gFdr_Display do
		local rec = gFdr_Display[i];
		if (rec.equippable and Fdr_GetStat (rec, FDR_DPS_KEY) ~= 0) then
			has = true;
			break;
		end
	end

	if (has ~= gFdr_HasDPS) then
		gFdr_HasDPS = has;
		if (gFdr_SortKey == "dps" and not has) then
			gFdr_SortKey = "peritem";
			gFdr_SortAsc = true;
		end
		Fdr_ApplyColumnLayout ();
		Fdr_UpdateHeaderArrows ();
	end
end

Fdr_PostRebuild = Fdr_UpdateDPSColumn;

-------------------------------------------------------------------------------
-- direct buy: locate a specific listing by its full identity tuple
-- (name + stack + buyout + required level) and buy exactly that one.
-- The level component is what makes this safe on Ascension: scaled variants
-- share links but never levels, so the tuple can't buy the wrong version.
-------------------------------------------------------------------------------

local FDRBUY_IDLE		= 0;
local FDRBUY_QUERY		= 1;	-- waiting to send the next page query
local FDRBUY_WAIT		= 2;	-- page query sent, waiting for results
local FDRBUY_CONFIRM	= 3;	-- listing found and loaded; awaiting the user's
								-- Buyout/Bid choice (PlaceAuctionBid is hardware-
								-- event protected and must run inside a click)
local FDRBUY_FINAL		= 4;	-- final are-you-sure step before the purchase

local gFdrBuy_State		= FDRBUY_IDLE;
local gFdrBuy_Rec		= nil;
local gFdrBuy_Page		= 0;
local gFdrBuy_Query		= nil;
local gFdrBuy_SentAt	= 0;

local FDRBUY_MAX_PAGES	= 10;
local FDRBUY_TIMEOUT	= 8;

local gFdrBuy_FoundIndex = nil;
local gFdrBuy_BidShown	 = nil;		-- bid amount displayed to the user at Found
local gFdrBuy_FinalMode	 = nil;		-- "buyout"/"bid" pending final confirmation
local gFdrBuy_FinalPrice = nil;

function FdrBuy_RequiredBid (bidAmount, minIncrement, minBid)

	if (bidAmount and bidAmount > 0) then
		return bidAmount + (minIncrement or 0);
	end
	return minBid or 0;
end

function FdrBuy_HidePreview ()
	if (Atr_Finder_PreviewTT) then Atr_Finder_PreviewTT:Hide(); end
end

-- With the listing live-loaded we can read the SERVER's tooltip for this
-- exact instance - the only accurate source for scaled items - and pull the
-- true DPS and item level back into the row.
function FdrBuy_HarvestTrueData (index, rec)

	local tt = Atr_FinderScanTT;
	if (not (tt and tt.SetAuctionItem and tt.NumLines)) then return; end

	tt:SetOwner (UIParent, "ANCHOR_NONE");
	tt:SetAuctionItem ("list", index);

	local n = tt:NumLines() or 0;
	local ilvlPat = (ITEM_LEVEL and ITEM_LEVEL:gsub ("%%d", "(%%d+)")) or "Item Level (%d+)";

	-- The same pass now keeps the WHOLE rendered tooltip.  This is the only
	-- moment the server's text for this exact instance is on screen, and the
	-- row tooltip cannot reproduce it later: SetHyperlink resolves a link,
	-- and scaled variants share one byte-identical link.  Capped at 40 lines
	-- so a pathological tooltip cannot bloat a scan holding thousands of
	-- records; nothing in 3.3.5 comes close.
	local lines = {};

	local j;
	for j = 1, n do
		local fs  = _G["Atr_FinderScanTTTextLeft"..j];
		local txt = fs and fs:GetText();
		if (txt) then
			local d = txt:match ("([%d%.]+)%s+damage per second");	-- enUS pattern
			if (d) then rec.trueDPS = tonumber (d); end

			local il = txt:match (ilvlPat);
			if (il) then rec.trueIlvl = tonumber (il); end
		end

		if (j <= 40) then
			local fsr = _G["Atr_FinderScanTTTextRight"..j];
			local e = { l = txt or "" };

			-- GetTextColor is absent on some mock fontstrings and on any
			-- future client that drops it; a nil colour simply means "leave
			-- whatever the cached line was using".
			if (fs and fs.GetTextColor) then e.lr, e.lg, e.lb = fs:GetTextColor(); end

			if (fsr and fsr.GetText) then
				e.r = fsr:GetText() or "";
				if (e.r ~= "" and fsr.GetTextColor) then e.rr, e.rg, e.rb = fsr:GetTextColor(); end
			end

			lines[j] = e;
		end
	end

	rec.trueLines	= (#lines > 0) and lines or nil;
	rec.trueStats	= Fdr_TrueStatsFromLines (rec.trueLines, Fdr_GetStats (rec));
	rec.fdrVerified = true;

	Fdr_AHVariant_Record (rec);
end

-- Verification is the moment a scaled listing becomes storable: the server
-- tooltip just gave us its real item level, and the list API's own `level`
-- return gave us its real required level.  That tuple names the variant
-- exactly, so unlike the name-keyed feed (Fdr_PriceDB_Update rule 2) this
-- price can be filed without smearing six variants together -- and the
-- tooltip can find it again from the same tuple.  See the
-- FINDER_TAB "verified auction prices per scale-variant" block in
-- AuctionatorHints.lua for the storage rules.
--
-- Deliberately narrow: only scaled equipment, which is precisely what the
-- name-keyed DB refuses.  Everything else already prices correctly by name,
-- and writing it here would give one item two sources that could disagree.
function Fdr_AHVariant_Record (rec)

	if (type (rec) ~= "table" or not Atr_AHVariant_Note) then return false; end
	if (not (rec.scaled and rec.equippable)) then return false; end

	local itemID = Fdr_ResearchItemID (rec.link);
	local ilvl   = tonumber (rec.trueIlvl or 0) or 0;
	local req    = tonumber (rec.level or 0) or 0;
	if (not itemID or ilvl <= 0 or req <= 0) then return false; end

	-- bid-only listings carry no buyout and must never be read as free
	local bo = tonumber (rec.buyoutPrice or 0) or 0;
	if (bo <= 0) then return false; end

	local cnt = tonumber (rec.count or 1) or 1;
	if (cnt < 1) then cnt = 1; end

	return Atr_AHVariant_Note (itemID, ilvl, req, math.floor (bo / cnt));
end

-- Lua patterns have no "literal" flag, so a stat label has to be escaped
-- before it can be matched.  Locale labels are ordinary words in enUS but
-- nothing guarantees that everywhere.
function Fdr_EscapePattern (s)
	return (tostring (s):gsub ("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1"));
end

-- True when two captured tooltips would render identically.  Used to decide
-- whether a merged face may claim its members' tooltip: same length, same
-- text on both sides, same colours.  Two nils count as the same (neither
-- member captured anything), which is harmless - the face ends up with nil
-- either way.
function Fdr_SameTrueLines (a, b)

	if (a == b) then return true; end
	if (type (a) ~= "table" or type (b) ~= "table") then return false; end
	if (#a ~= #b) then return false; end

	local i;
	for i = 1, #a do
		local x, y = a[i], b[i];
		if (x == nil or y == nil) then return false; end
		if (x.l ~= y.l or x.r ~= y.r) then return false; end
		if (x.lr ~= y.lr or x.lg ~= y.lg or x.lb ~= y.lb) then return false; end
		if (x.rr ~= y.rr or x.rg ~= y.rg or x.rb ~= y.rb) then return false; end
	end

	return true;
end

-- Reads real stat values out of a captured server tooltip.
--
-- The CACHED stat table decides which stats to look for and under which
-- keys; the captured tooltip supplies the values.  That split matters:
-- GetItemStats returns keys (ITEM_MOD_AGILITY_SHORT), a tooltip renders
-- labels ("Agility"), and _G[key] is the only bridge between them - which
-- also keeps this correct in every locale without a word list.
--
-- Deliberately limited to the "+18 Agility" / "126 Armor" forms, i.e. the
-- base stats and armor - the ones the stat picker offers by default.
-- Ratings arrive as prose ("Equip: Improves hit rating by 3.") whose
-- shape varies by effect and by locale; guessing at those would put wrong
-- numbers in a column that now looks authoritative, which is exactly the
-- bug being fixed.  Those keys stay absent and fall back to the cache.
--
-- The label must match to END of line, or "Agility" would also claim a
-- line reading "+3 Agility Rating".
function Fdr_TrueStatsFromLines (lines, cached)

	if (type (lines) ~= "table" or type (cached) ~= "table") then return nil; end

	local out, any = {}, false;

	local key;
	for key in pairs (cached) do

		local label = _G[key];
		if (type (label) == "string" and label ~= "") then

			local pat = "^%+?([%d%.]+)%s+"..Fdr_EscapePattern (label).."$";

			local i;
			for i = 1, #lines do
				local txt = lines[i] and lines[i].l;
				if (txt and txt ~= "") then
					local v = tonumber (txt:match (pat));
					if (v) then
						out[key] = v;
						any = true;
						break;
					end
				end
			end
		end
	end

	return any and out or nil;
end

-- Replays a captured server tooltip over the cached body that SetHyperlink
-- just drew.  nItem is where that body ends (published by the hints module
-- as Atr_Finder_TipItemLines); everything past it is Auctionator's own
-- price lines and must not be touched.
--
-- Overwriting rather than rebuilding is deliberate: the tooltip keeps the
-- item identity SetHyperlink gave it, so GameTooltip_ShowCompareItem still
-- works.  A rebuilt-from-text tooltip has no GetItem() and Compare dies.
function Fdr_ApplyTrueLines (tip, lines, nItem)

	if (not (tip and lines and nItem and nItem > 0)) then return; end

	local tname = tip.GetName and tip:GetName();
	if (not tname) then return; end

	local i;
	for i = 1, nItem do

		local src = lines[i];
		local L   = _G[tname.."TextLeft"..i];
		local R   = _G[tname.."TextRight"..i];

		if (L and L.SetText) then
			-- no counterpart means the cached body was LONGER; blanking is
			-- the honest option, since the leftover line describes a variant
			-- that is not the one under the cursor
			L:SetText ((src and src.l) or "");
			if (src and src.lr and L.SetTextColor) then L:SetTextColor (src.lr, src.lg, src.lb); end
		end

		if (R and R.SetText) then
			if (src and src.r and src.r ~= "") then
				R:SetText (src.r);
				if (src.rr and R.SetTextColor) then R:SetTextColor (src.rr, src.rg, src.rb); end
				if (R.Show) then R:Show(); end
			else
				R:SetText ("");
				if (R.Hide) then R:Hide(); end
			end
		end
	end

	-- the true tooltip ran LONGER than the cached one.  The surplus cannot be
	-- spliced into the middle of a drawn tooltip, so append it rather than
	-- drop it: out of order beats missing.
	for i = nItem + 1, #lines do
		local src = lines[i];
		if (src and src.l and src.l ~= "") then
			if (src.r and src.r ~= "" and tip.AddDoubleLine) then
				tip:AddDoubleLine (src.l, src.r, src.lr, src.lg, src.lb, src.rr, src.rg, src.rb);
			elseif (tip.AddLine) then
				tip:AddLine (src.l, src.lr, src.lg, src.lb, true);
			end
		end
	end
end

function FdrBuy_Fail (msg)

	gFdrBuy_State = FDRBUY_IDLE;
	FdrBuy_HidePreview ();
	if (Atr_Finder_BuyFrame) then Atr_Finder_BuyFrame:Hide(); end
	Fdr_SetMessage ("|cffff6666"..(msg or FT("Purchase failed")).."|r");
end

function Atr_Finder_CancelBuy ()

	gFdrBuy_State = FDRBUY_IDLE;
	FdrBuy_HidePreview ();
	if (Atr_Finder_BuyFrame) then Atr_Finder_BuyFrame:Hide(); end
end

function FdrBuy_Matches (i, rec)

	local name, _, count, _, _, level, _, _, buyoutPrice = GetAuctionItemInfo ("list", i);

	return name == rec.name
		and (count or 1) == (rec.count or 1)
		and (buyoutPrice or 0) == (rec.buyoutPrice or 0)
		and (level or 0) == (rec.level or 0);
end

function FdrBuy_Found (i, rec)

	gFdrBuy_FoundIndex	= i;
	gFdrBuy_State		= FDRBUY_CONFIRM;

	FdrBuy_HarvestTrueData (i, rec);

	-- fresh bid data from the live listing (scan-time values may be stale)
	local _, _, _, _, _, _, liveMinBid, liveIncr, liveBuyout, liveBid = GetAuctionItemInfo ("list", i);
	gFdrBuy_BidShown = FdrBuy_RequiredBid (liveBid, liveIncr, liveMinBid);

	FdrBuy_ShowConfirmView ();

	Atr_Finder_Redisplay ();	-- true DPS/iLvl now render verified (white)
end

-- (re)populates the dialog for the found listing: preview embedded, prices
-- above their buttons, bid input prefilled with the minimum
function FdrBuy_ShowConfirmView ()

	local f, rec, i = Atr_Finder_BuyFrame, gFdrBuy_Rec, gFdrBuy_FoundIndex;
	if (not f or not rec or not i) then return; end

	gFdrBuy_State = FDRBUY_CONFIRM;

	f.details:SetText (FT("Listing found and verified."));

	if (rec.buyoutPrice and rec.buyoutPrice > 0) then
		f.buyoutLabel:SetText (Fdr_MoneyString (rec.buyoutPrice));
		f.buyBtn:Enable();
	else
		f.buyoutLabel:SetText ("|cff888888--|r");
		f.buyBtn:Disable();
	end
	f.buyBtn:SetText (FT("Buyout"));

	if (gFdrBuy_BidShown and gFdrBuy_BidShown > 0) then
		if (f.bidInput and MoneyInputFrame_SetCopper) then
			MoneyInputFrame_SetCopper (f.bidInput, gFdrBuy_BidShown);
			f.bidInput:Show();
			f.bidLabel:SetText ("");
		else
			f.bidLabel:SetText (Fdr_MoneyString (gFdrBuy_BidShown));
		end
		f.bidBtn:Enable();
	else
		if (f.bidInput) then f.bidInput:Hide(); end
		f.bidLabel:SetText ("|cff888888--|r");
		f.bidBtn:Disable();
	end
	f.bidBtn:SetText (FT("Bid"));
	f.cancelBtn:SetText (FT("Cancel"));

	local tt = Atr_Finder_PreviewTT;
	if (tt and tt.SetAuctionItem) then
		tt:SetOwner (f, "ANCHOR_NONE");
		tt:SetAuctionItem ("list", i);
		tt:ClearAllPoints ();
		tt:SetPoint ("TOP", f, "TOP", 0, -58);
		tt:Show ();

		local th = (tt.GetHeight and tt:GetHeight()) or 0;
		if (f.SetHeight) then f:SetHeight (150 + th); end
		local tw = (tt.GetWidth and tt:GetWidth()) or 0;
		if (f.SetWidth and tw + 40 > 380) then f:SetWidth (tw + 40); end
	end
end

function FdrBuy_InlineError (msg)
	if (Atr_Finder_BuyFrame) then
		Atr_Finder_BuyFrame.details:SetText ("|cffff6666"..msg.."|r");
	end
end

-- first choice click (Buyout/Bid at CONFIRM): validate, then ask once more
function FdrBuy_EnterFinal (mode)

	local rec, i = gFdrBuy_Rec, gFdrBuy_FoundIndex;
	if (not rec or not i) then return; end

	if (not FdrBuy_Matches (i, rec)) then
		FdrBuy_Fail (FT("Listing changed - please try again"));
		return;
	end

	local payPrice;

	if (mode == "bid") then
		local _, _, _, _, _, _, liveMinBid, liveIncr, _, liveBid = GetAuctionItemInfo ("list", i);
		local required = FdrBuy_RequiredBid (liveBid, liveIncr, liveMinBid);

		payPrice = required;
		if (Atr_Finder_BuyFrame and Atr_Finder_BuyFrame.bidInput and MoneyInputFrame_GetCopper) then
			payPrice = MoneyInputFrame_GetCopper (Atr_Finder_BuyFrame.bidInput) or required;
		end

		if (payPrice < required) then
			FdrBuy_InlineError (string.format (FT("Bid too low - minimum is %s"), Fdr_MoneyString (required)));
			return;
		end
	else
		payPrice = rec.buyoutPrice;
		if (not payPrice or payPrice <= 0) then return; end
	end

	if (GetMoney and GetMoney() < payPrice) then
		FdrBuy_InlineError (FT("Not enough gold"));
		return;
	end

	gFdrBuy_FinalMode	= mode;
	gFdrBuy_FinalPrice	= payPrice;
	gFdrBuy_State		= FDRBUY_FINAL;

	local f = Atr_Finder_BuyFrame;
	if (f) then
		local verb = (mode == "bid") and FT("Place bid of") or FT("Buy out for");
		f.details:SetText ("|cffffd100"..verb.." "..Fdr_MoneyString (payPrice).."?|r");
		f.buyBtn:SetText (FT("Confirm"));
		f.buyBtn:Enable();
		f.bidBtn:Disable();
		f.cancelBtn:SetText (FT("Back"));
	end
end

-- FINAL confirm click: the purchase itself (still a hardware event)
function FdrBuy_ConfirmPurchase ()

	local rec, i	= gFdrBuy_Rec, gFdrBuy_FoundIndex;
	local mode		= gFdrBuy_FinalMode;
	local payPrice	= gFdrBuy_FinalPrice;

	if (not rec or not i or not payPrice) then
		FdrBuy_Fail (FT("Nothing to confirm"));
		return;
	end

	-- last-instant insurance: the tuple must still match at this index
	if (not FdrBuy_Matches (i, rec)) then
		FdrBuy_Fail (FT("Listing changed - please try again"));
		return;
	end

	if (mode == "bid") then
		local _, _, _, _, _, _, liveMinBid, liveIncr, _, liveBid = GetAuctionItemInfo ("list", i);
		if (FdrBuy_RequiredBid (liveBid, liveIncr, liveMinBid) > payPrice) then
			gFdrBuy_State = FDRBUY_CONFIRM;
			FdrBuy_ShowConfirmView ();
			FdrBuy_InlineError (FT("Bid has increased - amount refreshed"));
			return;
		end
	end

	PlaceAuctionBid ("list", i, payPrice);

	if (mode == "bid") then
		gFdrBuy_State = FDRBUY_IDLE;
		FdrBuy_HidePreview ();
		if (Atr_Finder_BuyFrame) then Atr_Finder_BuyFrame:Hide(); end
		Fdr_SetMessage ("|cff66ff66"..string.format (FT("Bid placed: %s (%s)"), rec.name, Fdr_MoneyString (payPrice)).."|r");
		return;
	end

	gFdrBuy_State = FDRBUY_IDLE;
	FdrBuy_HidePreview ();
	if (Atr_Finder_BuyFrame) then Atr_Finder_BuyFrame:Hide(); end

	-- remove one matching raw record so the display reflects the purchase
	FdrBuy_DropRec (rec);

	Atr_Finder_RebuildDisplay ();
	Fdr_SortAndRedisplay ();

	Fdr_SetMessage ("|cff66ff66"..string.format (FT("Bought: %s for %s"), rec.name, Fdr_MoneyString (payPrice)).."|r");
end

-- Drops one raw record matching this listing's tuple.  Identity is no use
-- here: a grouped row is a COPY of its member, so == never matches, which
-- is why FdrGrp_RemoveRec cannot be reused.  Returns true if one went.
function FdrBuy_DropRec (rec)

	if (rec == nil) then return false; end

	local k;
	for k = 1, #gFdr_Results do
		local r = gFdr_Results[k];
		if (r.name == rec.name and (r.count or 1) == (rec.count or 1)
				and (r.buyoutPrice or 0) == (rec.buyoutPrice or 0)
				and (r.level or 0) == (rec.level or 0)) then
			table.remove (gFdr_Results, k);
			return true;
		end
	end
	return false;
end

-- Does a short page really prove the server has nothing left to give?
--
-- Only if the page is OURS.  AUCTION_ITEM_LIST_UPDATE fires for any change to
-- the client's auction list - a completed bid, an owner refresh, another
-- addon's query - and both find loops consume whichever one arrives while they
-- are waiting; neither ever checked that the batch it read was the answer to
-- its own query.  Read a foreign batch and every unmatched member looks sold,
-- so one short foreign page condemns a whole name at once.  The server's own
-- unstable sort can hand back an incomplete result set for a query it answered
-- correctly seconds earlier (ASCENSION-CLIENT-NOTES), which reads identically
-- from here.  Either route explains a Verify that deleted six of seven live
-- listings once and never again.
--
-- An exhausted exact-name query must therefore still CONTAIN that name.  The
-- one case where it legitimately does not - every listing of the name sold in
-- the last few seconds - is precisely the case where guessing wrong deletes
-- rows the user came here to buy, so it resolves toward keeping them: a stale
-- row costs one wasted click and dies at the next scan, a wrongly pruned row
-- hides a purchase and looks like data loss.
--
-- The name is compared exactly.  QueryAuctionItems matches substrings, so a
-- batch can carry longer names that merely contain ours; those are somebody
-- else's listings and prove nothing about this one.
function FdrGrp_ShortPageProvesGone (numBatch, name)

	if (numBatch == nil or numBatch >= 50) then return false; end
	if (name == nil or name == "") then return false; end

	local i;
	for i = 1, numBatch do
		-- extra parens truncate the multi-return (see conventions)
		if ((GetAuctionItemInfo ("list", i)) == name) then return true; end
	end

	return false;
end

function FdrBuy_ScanPage ()

	local numBatch = GetNumAuctionItems ("list");

	local i;
	for i = 1, numBatch do
		if (FdrBuy_Matches (i, gFdrBuy_Rec)) then
			FdrBuy_Found (i, gFdrBuy_Rec);
			return;
		end
	end

	-- A short page means the server had nothing more to give: every listing
	-- under this name was seen and none of them is ours, so the row is a
	-- sold listing (or one double-seen across a page boundary during the
	-- scan).  Prune it, on the same rule FdrGrp_Finish uses - and leaving it
	-- on screen only invites the same click again.
	--
	-- Hitting the page cap is NOT that proof.  The search was cut short, so
	-- the row stays and the message stays uncommitted.
	if (FdrGrp_ShortPageProvesGone (numBatch, gFdrBuy_Rec and gFdrBuy_Rec.name)) then
		local rec = gFdrBuy_Rec;
		local dropped = FdrBuy_DropRec (rec);

		FdrBuy_Fail (dropped
			and FT("Listing is gone - it sold, and the row has been removed")
			or  FT("Listing not found - it may have sold or changed"));

		if (dropped) then
			Atr_Finder_RebuildDisplay ();
			Fdr_SortAndRedisplay ();
		end
		return;
	end

	-- Short, but not one row of it is the name we asked for: this batch is
	-- not our answer, or not a whole one.  Absence proves nothing, so the row
	-- stays and the user can click it again.
	if (numBatch < 50) then
		FdrBuy_Fail (FT("Listing not found - the auction list changed; try again"));
		return;
	end

	if (gFdrBuy_Page + 1 >= FDRBUY_MAX_PAGES) then
		FdrBuy_Fail (FT("Listing not found - it may have sold or changed"));
		return;
	end

	gFdrBuy_Page	= gFdrBuy_Page + 1;
	gFdrBuy_State	= FDRBUY_QUERY;
	gFdrBuy_SentAt	= time();
end

-- called by the Buy button on the confirm dialog
function Atr_Finder_ExecuteBuy ()

	local rec = gFdrBuy_Rec;
	if (not rec) then return; end

	gFdrBuy_Page	= 0;
	gFdrBuy_State	= FDRBUY_QUERY;
	gFdrBuy_SentAt	= time();

	if (Atr_NewQuery) then gFdrBuy_Query = Atr_NewQuery(); end
end

function FdrBuy_SendQuery ()

	local queryString = gFdrBuy_Rec.name;
	if (zc and zc.UTF8_Truncate) then
		queryString = zc.UTF8_Truncate (queryString, 63);
	end

	QueryAuctionItems (queryString, nil, nil, nil, 0, 0, gFdrBuy_Page, nil, nil);

	gFdrBuy_State	= FDRBUY_WAIT;
	gFdrBuy_SentAt	= time();
end

-------------------------------------------------------------------------------
-- group listings window: a grouped row's face carries the group TOTAL in its
-- count field, so the face is NOT a buyable identity tuple (this is why a
-- direct buy on a multi-listing group used to end in "Listing not found").
-- Clicking such a row opens this window instead: every real listing in the
-- group on its own line (qty / ilvl / dps / time left / buyout / per item),
-- each line individually buyable via the normal exact-buy flow.
-- For scaled gear the window auto-runs an exact-name find (same channel and
-- dup handling as the buy engine) and reads each listing's SERVER tooltip,
-- so dimmed base values populate to verified white per listing - the same
-- greyed->white behavior as the buy dialog, but for the whole group at once.
-------------------------------------------------------------------------------

local FDRGRP_IDLE	= 0;
local FDRGRP_QUERY	= 1;	-- waiting to send the next page query
local FDRGRP_WAIT	= 2;	-- page query sent, waiting for results
local FDRGRP_DONE	= 3;	-- window open; verification finished or not needed

local gFdrGrp_State		= FDRGRP_IDLE;
local gFdrGrp_Face		= nil;
local gFdrGrp_Members	= nil;
local gFdrGrp_Page		= 0;
local gFdrGrp_Query		= nil;
local gFdrGrp_SentAt	= 0;

local gFdrGrp_Mode		= "window";	-- "window" | "sweep" (the Verify button)
local gFdrGrp_Name		= nil;		-- exact-name query of the current find
local gFdrGrp_Queue		= nil;		-- sweep: remaining {name, members} entries
local gFdrGrp_QTotal	= 0;		-- sweep: total entries, for progress text
local gFdrGrp_Pruned	= 0;		-- stale records removed this run

local FDRGRP_MAX_PAGES	= 10;
local FDRGRP_TIMEOUT	= 8;
local FDRGRP_NUM_ROWS	= 10;
local FDRGRP_ROW_H		= 17;

local gFdrGrp_Rows = nil;
local gFdrGrp_Cols = nil;		-- active column layout (per group type)
local gFdrGrp_StatKeys = {};	-- the picked top-2 stat keys for this group

local FDRGRP_INNER_W = 348;

-- default whitelist for the window's stat columns: the five base stats.
-- Everything else (armor, resistances, PVE/PVP_POWER, ratings) stays out
-- unless the user picked it in the Stats dropdown.
local FDRGRP_BASE_STATS = {
	"ITEM_MOD_STAMINA_SHORT",
	"ITEM_MOD_STRENGTH_SHORT",
	"ITEM_MOD_AGILITY_SHORT",
	"ITEM_MOD_INTELLECT_SHORT",
	"ITEM_MOD_SPIRIT_SHORT",
};

-- picks the window's two stat columns:
--  1) stats selected in the Finder's Stats dropdown, in selection order
--     (this is how Armor or any other stat can be shown deliberately);
--  2) otherwise the two biggest BASE stats present on the item.
function FdrGrp_TopStats (face)

	local out = {};
	local i;

	for i = 1, #gFdr_SelectedStats do
		if (#out >= 2) then break; end
		if (gFdr_SelectedStats[i] ~= FDR_DPS_KEY) then
			tinsert (out, gFdr_SelectedStats[i]);
		end
	end
	if (#out > 0) then return out; end

	local base = {};
	for i = 1, #FDRGRP_BASE_STATS do base[FDRGRP_BASE_STATS[i]] = true; end

	local picks = {};
	local k, v;
	for k, v in pairs (Fdr_GetStats (face)) do
		if (base[k]) then
			tinsert (picks, { k = k, v = tonumber (v) or 0 });
		end
	end
	table.sort (picks, function (a, b)
		if (a.v ~= b.v) then return a.v > b.v; end
		return a.k < b.k;
	end);

	for i = 1, 2 do
		if (picks[i]) then out[i] = picks[i].k; end
	end
	return out;
end

-- builds the column list for this group and (re)anchors headers + row cells.
-- gear:  Qty | Lvl | [DPS] | [stat1] | [stat2] | Buyout
-- goods: Qty | Buyout | Per Item
function FdrGrp_ApplyLayout (face)

	local cols = {};
	local x = 0;
	local function add (key, label, w, j)
		tinsert (cols, { key = key, label = label, x = x, w = w, j = j });
		x = x + w + 8;
	end

	if (face.equippable) then
		add ("qty",  FT("Qty"),  30, "RIGHT");
		add ("lvl",  FT("Lvl"),  30, "RIGHT");

		if (face.trueDPS or Fdr_GetStat (face, FDR_DPS_KEY) ~= 0) then
			add ("dps", FT("DPS"), 42, "RIGHT");
		end

		gFdrGrp_StatKeys = FdrGrp_TopStats (face);
		local si;
		for si = 1, #gFdrGrp_StatKeys do
			add ("stat"..si, Fdr_StatDisplayName (gFdrGrp_StatKeys[si]), 58, "RIGHT");
		end

		add ("buyout", FT("Buyout"), 60, "RIGHT");
	else
		gFdrGrp_StatKeys = {};
		add ("qty",		FT("Qty"),		36, "RIGHT");
		add ("buyout",	FT("Buyout"),	130, "RIGHT");
		add ("peritem",	FT("Per Item"),	60, "RIGHT");
	end

	-- last column absorbs the remaining width
	local last = cols[#cols];
	last.w = FDRGRP_INNER_W - last.x;

	gFdrGrp_Cols = cols;

	local f = Atr_Finder_GroupFrame;
	if (not f) then return; end

	-- headers: park every known header, then place the active ones
	local key, fs;
	for key, fs in pairs (f.heads) do
		fs:SetText ("");
	end
	local ci;
	for ci = 1, #cols do
		local c = cols[ci];
		fs = f.heads[c.key];
		if (fs) then
			if (fs.ClearAllPoints) then fs:ClearAllPoints (); end
			fs:SetPoint ("TOPLEFT", 20 + c.x, -48);
			fs:SetWidth (c.w);
			fs:SetJustifyH (c.j);
			fs:SetText (c.label);
		end
	end

	-- row cells follow the same layout
	local i;
	for i = 1, FDRGRP_NUM_ROWS do
		local row = gFdrGrp_Rows[i];
		for ci = 1, #cols do
			local c = cols[ci];
			local cell = row.cells[c.key];
			if (cell) then
				if (cell.ClearAllPoints) then cell:ClearAllPoints (); end
				cell:SetPoint ("LEFT", c.x, 0);
				cell:SetWidth (c.w);
				cell:SetJustifyH (c.j);
			end
		end
	end
end

-- what a cell shows for a member; nil-safe for inactive columns
function FdrGrp_CellValue (key, m)

	if (key == "qty") then
		return tostring (m.count or 1);
	end
	if (key == "lvl") then
		return (m.level and m.level > 0) and tostring (m.level) or "";
	end
	if (key == "dps") then
		local dps = m.trueDPS or Fdr_GetStat (m, FDR_DPS_KEY);
		if (dps and dps ~= 0) then
			return (dps % 1 == 0) and tostring (dps) or string.format ("%.1f", dps);
		end
		return "";
	end
	local si = key:match ("^stat(%d)$");
	if (si) then
		local sk = gFdrGrp_StatKeys[tonumber (si)];
		local v = sk and Fdr_GetStat (m, sk);
		if (v and v ~= 0) then
			return (v % 1 == 0) and tostring (v) or string.format ("%.1f", v);
		end
		return "";
	end
	if (key == "buyout") then
		return Fdr_MoneyString (m.buyoutPrice);
	end
	if (key == "peritem") then
		if (m.perItem and m.perItem > 0 and m.count and m.count > 1) then
			return Fdr_MoneyString (m.perItem);
		end
		return "";
	end
	return "";
end

function FdrGrp_SetNote (txt)
	if (Atr_Finder_GroupFrame) then
		Atr_Finder_GroupFrame.note:SetText (txt or "");
	end
end

function FdrGrp_Redisplay ()

	local f = Atr_Finder_GroupFrame;
	if (not f or not gFdrGrp_Members or gFdrGrp_Mode ~= "window") then return; end

	local num = #gFdrGrp_Members;

	FauxScrollFrame_Update (Atr_Finder_GroupScroll, num, FDRGRP_NUM_ROWS, FDRGRP_ROW_H);
	local offset = FauxScrollFrame_GetOffset (Atr_Finder_GroupScroll);

	local scaled = gFdrGrp_Face and gFdrGrp_Face.scaled;

	local i;
	for i = 1, FDRGRP_NUM_ROWS do

		local row = gFdrGrp_Rows[i];
		local idx = offset + i;
		local m = gFdrGrp_Members[idx];

		if (m) then
			row.member = m;

			-- greyed until THIS listing's server tooltip has confirmed it
			local dim = 1;
			if (m.fdrGone) then
				dim = 0.4;
			elseif (scaled and not m.fdrVerified) then
				dim = 0.55;
			end

			-- blank every cell, then fill the active columns
			local key, cell;
			for key, cell in pairs (row.cells) do
				cell:SetText ("");
			end
			local ci;
			for ci = 1, #(gFdrGrp_Cols or {}) do
				local c = gFdrGrp_Cols[ci];
				cell = row.cells[c.key];
				if (cell) then
					local txt = FdrGrp_CellValue (c.key, m);
					if (m.fdrGone and c.key == "buyout") then
						txt = "|cffff6666?|r  "..txt;
					end
					cell:SetText (txt);
					-- price cells carry their own colors; the rest dim
					if (c.key ~= "buyout" and c.key ~= "peritem") then
						cell:SetTextColor (dim, dim, dim);
					end
				end
			end

			row:Show();
		else
			row.member = nil;
			row:Hide();
		end
	end
end

function Atr_Finder_CancelGroup ()

	gFdrGrp_State	= FDRGRP_IDLE;
	gFdrGrp_Face	= nil;
	gFdrGrp_Members	= nil;
	gFdrGrp_Queue	= nil;
	gFdrGrp_Mode	= "window";

	if (Atr_Finder_GroupFrame) then Atr_Finder_GroupFrame:Hide(); end
	if (Atr_Finder_UpdateVerifyButton) then Atr_Finder_UpdateVerifyButton (); end
end

-- removes a raw scan record by reference
function FdrGrp_RemoveRec (rec)

	local k;
	for k = 1, #gFdr_Results do
		if (gFdr_Results[k] == rec) then
			table.remove (gFdr_Results, k);
			return true;
		end
	end
	return false;
end


-- completes the current find. reason: "ok" | "exhausted" | "capped" |
-- "timeout". exhausted=true means every page was seen, so unverified
-- members truly aren't on the AH anymore: flag them gone AND remove them
-- from the scan results - they are sold listings, or single listings
-- double-seen across page boundaries during the scan (the server's
-- unstable sort). Timeouts, page caps and unproven batches never prune:
-- the search was cut short or was not ours, and absence proves nothing.
function FdrGrp_Finish (reason, exhausted)

	local gone = 0;
	if (gFdrGrp_Members and exhausted) then
		local i;
		for i = 1, #gFdrGrp_Members do
			local m = gFdrGrp_Members[i];
			if (not m.fdrVerified) then
				m.fdrGone = true;
				if (FdrGrp_RemoveRec (m)) then gone = gone + 1; end
			end
		end
	end
	gFdrGrp_Pruned = gFdrGrp_Pruned + gone;

	if (gFdrGrp_Mode == "sweep") then
		-- progressive: each finished name whitens/cleans the main list
		Atr_Finder_RebuildDisplay ();
		Fdr_SortAndRedisplay ();
		FdrGrp_NextInQueue ();
		return;
	end

	gFdrGrp_State = FDRGRP_DONE;

	local note;
	if (reason == "timeout") then
		note = FT("Verification timed out");
	elseif (reason == "unproven") then
		note = FT("The auction list changed - nothing removed; try again");
	elseif (gone > 0) then
		note = string.format (FT("%d stale listing(s) removed - sold or double-counted by the scan"), gone);
	elseif (reason == "capped") then
		note = FT("Some listings could not be verified");
	else
		note = FT("All listings verified");
	end
	FdrGrp_SetNote (note);
	FdrGrp_Redisplay ();

	-- a rebuild re-derives face trueIlvl/trueDPS from the (now verified)
	-- members, so the main list row turns white too when they agree
	Atr_Finder_RebuildDisplay ();
	Fdr_SortAndRedisplay ();
end

function FdrGrp_ScanPage ()

	if (not gFdrGrp_Members) then return; end

	local numBatch = GetNumAuctionItems ("list");
	local claimed = {};		-- one live index verifies at most one member

	local i;
	for i = 1, numBatch do
		local j;
		for j = 1, #gFdrGrp_Members do
			local m = gFdrGrp_Members[j];
			if (not m.fdrVerified and not claimed[i] and FdrBuy_Matches (i, m)) then
				claimed[i] = true;
				FdrBuy_HarvestTrueData (i, m);
				m.fdrVerified = true;
				break;
			end
		end
	end

	local remaining = 0;
	for i = 1, #gFdrGrp_Members do
		if (not gFdrGrp_Members[i].fdrVerified) then remaining = remaining + 1; end
	end

	if (remaining == 0) then
		FdrGrp_Finish ("ok", false);
		return;
	end

	if (FdrGrp_ShortPageProvesGone (numBatch, gFdrGrp_Name)) then
		FdrGrp_Finish ("exhausted", true);
		return;
	end

	-- Short page that does not carry our own name: see FdrGrp_ShortPageProvesGone.
	-- Finishing UNPROVEN prunes nothing, so the rows stay greyed and the Verify
	-- button stays on screen - which is the signal that a name was skipped, and
	-- pressing it again re-runs exactly those names.
	if (numBatch < 50) then
		FdrGrp_Finish ("unproven", false);
		return;
	end

	if (gFdrGrp_Page + 1 >= FDRGRP_MAX_PAGES) then
		FdrGrp_Finish ("capped", false);
		return;
	end

	FdrGrp_Redisplay ();

	gFdrGrp_Page	= gFdrGrp_Page + 1;
	gFdrGrp_State	= FDRGRP_QUERY;
	gFdrGrp_SentAt	= time();
end

function FdrGrp_SendQuery ()

	local queryString = gFdrGrp_Name or "";
	if (zc and zc.UTF8_Truncate) then
		queryString = zc.UTF8_Truncate (queryString, 63);
	end

	QueryAuctionItems (queryString, nil, nil, nil, 0, 0, gFdrGrp_Page, nil, nil);

	gFdrGrp_State	= FDRGRP_WAIT;
	gFdrGrp_SentAt	= time();
end

-- Flat, opaque dialog chrome for the Finder's popups.
--
-- UI-DialogBox-Background renders semi-transparent on this client, so the
-- group window and the buy dialog were showing the listing rows straight
-- through their own text.  WHITE8X8 tinted by SetBackdropColor is the
-- reliable way to get a solid fill on 3.3.5 - there is no alpha argument on
-- SetBackdrop itself, and the stock dialog art cannot be made opaque.
--
-- Every call is guarded: a frame without SetBackdrop (the test harness's
-- mock, say) degrades to no chrome rather than to an error.
function Fdr_StyleDialog (f)

	if (not (f and f.SetBackdrop)) then return; end

	f:SetBackdrop ({
		bgFile		= "Interface\\Buttons\\WHITE8X8",
		edgeFile	= "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile		= true, tileSize = 32, edgeSize = 32,
		insets		= { left = 11, right = 12, top = 12, bottom = 11 },
	});

	-- alpha 1 is the entire point; anything less and the rows read through
	if (f.SetBackdropColor) then f:SetBackdropColor (0.10, 0.10, 0.11, 1); end
	if (f.SetBackdropBorderColor) then f:SetBackdropBorderColor (0.85, 0.85, 0.85, 1); end
end

function FdrGrp_BuildFrame ()

	if (Atr_Finder_GroupFrame) then return; end

	local parent = Atr_Finder_Panel or AuctionFrame or UIParent;

	local f = CreateFrame ("Frame", "Atr_Finder_GroupFrame", parent);
	f:SetSize (400, 124 + FDRGRP_NUM_ROWS * FDRGRP_ROW_H);
	f:SetPoint ("CENTER", parent, "CENTER", 0, 30);
	f:SetFrameStrata ("DIALOG");
	Fdr_StyleDialog (f);
	f:EnableMouse (true);
	f:Hide();

	f.itemname = f:CreateFontString (nil, "ARTWORK", "GameFontNormal");
	f.itemname:SetPoint ("TOP", 0, -18);
	f.itemname:SetWidth (350);

	f.sub = f:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
	f.sub:SetPoint ("TOP", 0, -33);

	-- header fontstrings for every column the layout may use; positions,
	-- widths and labels are assigned per group by FdrGrp_ApplyLayout
	local CELLKEYS = { "qty", "lvl", "dps", "stat1", "stat2", "buyout", "peritem" };
	f.heads = {};
	local hi;
	for hi = 1, #CELLKEYS do
		local fs = f:CreateFontString (nil, "ARTWORK", "GameFontNormalSmall");
		fs:SetHeight (12);
		f.heads[CELLKEYS[hi]] = fs;
	end

	f.note = f:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
	f.note:SetPoint ("BOTTOM", 0, 42);
	f.note:SetWidth (360);
	f.note:SetJustifyH ("CENTER");

	local scroll = CreateFrame ("ScrollFrame", "Atr_Finder_GroupScroll", f, "FauxScrollFrameTemplate");
	scroll:SetPoint ("TOPLEFT", 20, -64);
	scroll:SetSize (348, FDRGRP_NUM_ROWS * FDRGRP_ROW_H);
	scroll:SetScript ("OnVerticalScroll", function (self, offset)
		FauxScrollFrame_OnVerticalScroll (self, offset, FDRGRP_ROW_H, FdrGrp_Redisplay);
	end);

	gFdrGrp_Rows = {};
	local i;
	for i = 1, FDRGRP_NUM_ROWS do

		local row = CreateFrame ("Button", "Atr_Finder_GroupRow"..i, f);
		row:SetSize (348, FDRGRP_ROW_H);
		row:SetPoint ("TOPLEFT", 20, -64 - (i-1) * FDRGRP_ROW_H);
		row:SetHighlightTexture ("Interface\\QuestFrame\\UI-QuestTitleHighlight");

		row.cells = {};
		local hj;
		for hj = 1, #CELLKEYS do
			local fs = row:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
			fs:SetHeight (FDRGRP_ROW_H);
			row.cells[CELLKEYS[hj]] = fs;
		end

		row:RegisterForClicks ("LeftButtonUp");
		row:SetScript ("OnClick", function (self)
			local m = self.member;
			if (not m) then return; end
			Atr_Finder_CancelGroup ();
			Atr_Finder_RequestBuy (m);
		end);
		row:SetScript ("OnEnter", function (self)
			if (not self.member) then return; end
			GameTooltip:SetOwner (self, "ANCHOR_RIGHT");
			if (self.member.owner) then
				GameTooltip:AddLine (FT("Seller")..": "..self.member.owner, 0.8, 0.8, 0.8);
			end
			if (self.member.fdrGone) then
				GameTooltip:AddLine (FT("Not found on the last check - it may have sold"), 1, 0.4, 0.4);
			end
			GameTooltip:AddLine (FT("Click to go to this listing"), 0.5, 0.7, 1.0);
			GameTooltip:Show();
		end);
		row:SetScript ("OnLeave", function () GameTooltip:Hide(); end);

		row:Hide();
		gFdrGrp_Rows[i] = row;
	end

	f.closeBtn = CreateFrame ("Button", "Atr_Finder_GroupClose", f, "UIPanelButtonTemplate");
	f.closeBtn:SetSize (86, 22);
	f.closeBtn:SetPoint ("BOTTOM", 0, 14);
	f.closeBtn:SetText (FT("Close"));
	f.closeBtn:SetScript ("OnClick", function ()
		Atr_Finder_CancelGroup ();
	end);
end

function Atr_Finder_ShowGroup (face)

	if (not face or not face.members) then return; end

	-- the verification find shares the AH query channel with the scanner
	if (gFdr_State ~= FDR_NULL) then
		Fdr_SetMessage (FT("Finish or cancel the scan first"));
		return;
	end

	Atr_Finder_CancelBuy ();
	FdrGrp_BuildFrame ();

	gFdrGrp_Mode	= "window";
	gFdrGrp_Queue	= nil;
	gFdrGrp_Face	= face;
	if (Atr_AHVariant_NewSession) then Atr_AHVariant_NewSession (); end
	gFdrGrp_Name	= face.name;
	gFdrGrp_Members	= {};
	gFdrGrp_Pruned	= 0;

	local needVerify = face.scaled and face.equippable;

	local i;
	for i = 1, #face.members do
		local m = face.members[i];
		m.fdrGone = nil;
		if (needVerify) then
			m.fdrVerified = nil;	-- always re-verify: catches sold listings
		end
		tinsert (gFdrGrp_Members, m);
	end

	table.sort (gFdrGrp_Members, function (a, b)
		local ap = (a.perItem and a.perItem > 0) and a.perItem or math.huge;
		local bp = (b.perItem and b.perItem > 0) and b.perItem or math.huge;
		if (ap ~= bp) then return ap < bp; end
		return (a.buyoutPrice or 0) < (b.buyoutPrice or 0);
	end);

	local f = Atr_Finder_GroupFrame;
	local r, g, b = GetItemQualityColor (face.quality or 1);
	f.itemname:SetText (face.name);
	f.itemname:SetTextColor (r, g, b);

	local sub = string.format (FT("%d listings"), #gFdrGrp_Members);
	if (face.equippable and face.level and face.level > 0) then
		sub = sub.."  ·  "..string.format (FT("Requires level %d"), face.level);
	end
	f.sub:SetText (sub);

	FdrGrp_ApplyLayout (face);

	local shown = #gFdrGrp_Members;
	if (shown > FDRGRP_NUM_ROWS) then shown = FDRGRP_NUM_ROWS; end
	if (shown < 1) then shown = 1; end
	f:SetHeight (124 + shown * FDRGRP_ROW_H);
	if (Atr_Finder_GroupScroll) then
		Atr_Finder_GroupScroll:SetHeight (shown * FDRGRP_ROW_H);
	end

	if (needVerify) then
		gFdrGrp_Page	= 0;
		gFdrGrp_State	= FDRGRP_QUERY;
		gFdrGrp_SentAt	= time();
		if (Atr_NewQuery) then gFdrGrp_Query = Atr_NewQuery(); end
		FdrGrp_SetNote (FT("Verifying each listing..."));
	else
		gFdrGrp_State = FDRGRP_DONE;
		FdrGrp_SetNote (FT("Go to listing..."));
	end

	f:Show();
	FdrGrp_Redisplay ();
end

-- called from the shared OnUpdate handler (throttled there)
function Atr_Finder_GroupOnUpdate ()

	if (gFdrGrp_State == FDRGRP_QUERY) then
		if (CanSendAuctionQuery()) then
			FdrGrp_SendQuery ();
		elseif (time() - gFdrGrp_SentAt > 12) then
			FdrGrp_Finish ("timeout", false);
		end
	elseif (gFdrGrp_State == FDRGRP_WAIT) then
		if (time() - gFdrGrp_SentAt > FDRGRP_TIMEOUT) then
			FdrGrp_Finish ("timeout", false);
		end
	end
end

function Atr_Finder_GroupIsFinding ()
	return gFdrGrp_State == FDRGRP_QUERY or gFdrGrp_State == FDRGRP_WAIT;
end

-- called from the shared AUCTION_ITEM_LIST_UPDATE handler
function Atr_Finder_GroupOnListUpdate ()

	if (gFdrGrp_State ~= FDRGRP_WAIT) then return; end

	if (gFdrGrp_Query and gFdrGrp_Query.CheckForDuplicatePage
			and gFdrGrp_Query:CheckForDuplicatePage (gFdrGrp_Page)) then
		gFdrGrp_State	= FDRGRP_QUERY;
		gFdrGrp_SentAt	= time();
	else
		FdrGrp_ScanPage ();
	end
end

-------------------------------------------------------------------------------
-- "Verify" button: appears when the list contains greyed (scaled, unverified)
-- rows. Runs one exact-name find per distinct name, verifying EVERY matching
-- scan record from its server tooltip - the same greyed->white behavior as
-- opening each listing, automated. Exhausted finds also prune records that
-- are no longer on the AH (sold, or double-seen during the paged scan).
-------------------------------------------------------------------------------

function FdrGrp_NextInQueue ()

	if (not gFdrGrp_Queue or #gFdrGrp_Queue == 0) then

		gFdrGrp_State	= FDRGRP_IDLE;
		gFdrGrp_Queue	= nil;
		gFdrGrp_Members	= nil;
		gFdrGrp_Mode	= "window";

		local msg = FT("Verification complete");
		if (gFdrGrp_Pruned > 0) then
			msg = msg.." · "..string.format (FT("%d stale listing(s) removed"), gFdrGrp_Pruned);
		end
		Fdr_SetMessage (msg);
		Atr_Finder_UpdateVerifyButton ();
		return;
	end

	local entry = table.remove (gFdrGrp_Queue, 1);

	gFdrGrp_Name	= entry.name;
	gFdrGrp_Members	= entry.members;
	gFdrGrp_Page	= 0;
	gFdrGrp_State	= FDRGRP_QUERY;
	gFdrGrp_SentAt	= time();
	if (Atr_NewQuery) then gFdrGrp_Query = Atr_NewQuery(); end

	Fdr_SetMessage (string.format (FT("Verifying (%d/%d): %s"),
		gFdrGrp_QTotal - #gFdrGrp_Queue, gFdrGrp_QTotal, entry.name));
end

-- does the current display contain rows that would render greyed?
local function Fdr_HasUnverifiedScaled ()

	local i;
	for i = 1, #gFdr_Display do
		local rec = gFdr_Display[i];
		if (rec.scaled and rec.equippable and not rec.trueIlvl) then
			return true;
		end
	end
	return false;
end

function Atr_Finder_UpdateVerifyButton ()

	local btn = Atr_Finder_VerifyButton;
	if (not btn) then return; end

	if (gFdrGrp_Mode == "sweep" and gFdrGrp_State ~= FDRGRP_IDLE) then
		btn:SetText (FT("Cancel"));
		btn:Show();
	elseif (Fdr_HasUnverifiedScaled ()) then
		btn:SetText (FT("Verify"));
		btn:Show();
	else
		btn:Hide();
	end
end

function Atr_Finder_StartVerify ()

	-- the button doubles as Cancel while a sweep runs
	if (gFdrGrp_Mode == "sweep" and gFdrGrp_State ~= FDRGRP_IDLE) then
		Atr_Finder_CancelGroup ();
		Fdr_SetMessage (FT("Verification cancelled"));
		return;
	end

	if (gFdr_State ~= FDR_NULL) then
		Fdr_SetMessage (FT("Finish or cancel the scan first"));
		return;
	end

	Atr_Finder_CancelBuy ();
	Atr_Finder_CancelGroup ();

	-- one queue entry per distinct name among the greyed DISPLAYED rows;
	-- its members are ALL unverified scaled scan records with that name
	-- (every variant of the name verifies off the same exact-name query)
	local wanted, order = {}, {};
	local i;
	for i = 1, #gFdr_Display do
		local rec = gFdr_Display[i];
		if (rec.scaled and rec.equippable and not rec.trueIlvl
				and rec.name and not wanted[rec.name]) then
			wanted[rec.name] = true;
			tinsert (order, rec.name);
		end
	end

	if (#order == 0) then
		Fdr_SetMessage (FT("Nothing to verify"));
		Atr_Finder_UpdateVerifyButton ();
		return;
	end

	gFdrGrp_Queue = {};
	for i = 1, #order do
		local name = order[i];
		local members = {};
		local k;
		for k = 1, #gFdr_Results do
			local r = gFdr_Results[k];
			if (r.name == name and r.scaled and not r.fdrVerified) then
				r.fdrGone = nil;
				tinsert (members, r);
			end
		end
		if (#members > 0) then
			tinsert (gFdrGrp_Queue, { name = name, members = members });
		end
	end

	gFdrGrp_Mode	= "sweep";
	gFdrGrp_Face	= nil;
	if (Atr_AHVariant_NewSession) then Atr_AHVariant_NewSession (); end
	gFdrGrp_QTotal	= #gFdrGrp_Queue;
	gFdrGrp_Pruned	= 0;

	Atr_Finder_UpdateVerifyButton ();
	FdrGrp_NextInQueue ();
end

-------------------------------------------------------------------------------
-- scan engine
-------------------------------------------------------------------------------

-- returns added, updated -- what the partial flush salvaged
function Atr_Finder_CancelSearch (showMsg)

	if (Atr_Finder_WarnFrame) then
		Atr_Finder_WarnFrame:Hide();
	end

	local wasScanning = (gFdr_State ~= FDR_NULL);
	local pAdd, pUpd = 0, 0;

	if (wasScanning) then
		gFdr_State = FDR_NULL;

		-- FINDER_TAB: a cancel used to bin everything harvested so far, which
		-- on a long sweep means throwing away minutes of scanning. Keep it,
		-- insert-only so a truncated slice can never overwrite better data.
		pAdd, pUpd = Fdr_PriceDB_Update (nil, true);

		if (showMsg) then
			if (pAdd > 0) then
				Fdr_SetMessage (string.format (FT("Search cancelled - kept %d new prices"), pAdd));
			else
				Fdr_SetMessage (FT("Search cancelled"));
			end
		end
	end

	if (Atr_Finder_SearchButton) then
		Atr_Finder_SearchButton:SetText (FT("Search"));
		Atr_Finder_SearchButton:Enable();
	end

	-- FINDER_TAB: a cancel never reaches Fdr_FinishSearch, so the driver's
	-- callback would never fire and a full scan would hang on this category.
	-- Tell it directly, and drop the hook so nothing fires later.
	gFdr_OnFinish = nil;
	if (Fdr_FS_Running and Fdr_FS_Running ()) then
		Fdr_FS_Cancel (false);
	end

	-- Same problem for the Sell tab's "Scan Prices" driver: its per-name chain
	-- rides gFdr_OnFinish, which we just cleared, so tell it to stop too.
	if (Atr_SB_ScanRunning and Atr_SB_ScanRunning ()) then
		Atr_SB_ScanCancel ();
	end

	return pAdd, pUpd;
end

function Atr_Finder_OnTabClick (index)

	if (index ~= Atr_FindTabIndex (ATR_FINDER_TAB)) then
		Atr_Finder_CancelSearch (false);
		Atr_Finder_CancelBuy ();
		Atr_Finder_CancelGroup ();
	end
end

-- FINDER_TAB: install/clear the completion callback.  Separate from
-- StartQueueScan so a driver can clear it on cancel without starting anything.
function Atr_Finder_SetFinishHook (fn)
	gFdr_OnFinish = fn;
end


-- FINDER_TAB: start a scan from an EXPLICIT spec queue rather than from the
-- tab's widgets.  Everything downstream (paging, dup-page retry, the runaway
-- guard, Fdr_PriceDB_Update, the research ledger) is the ordinary engine --
-- this only replaces where the queue comes from, so the Full Scan dialog
-- cannot drift from the behaviour the Finder tab is tested against.
--
-- Returns false when a scan is already in flight; the caller must not assume
-- its callback will fire.
function Atr_Finder_StartQueueScan (specs, onFinish)

	if (type (specs) ~= "table" or #specs == 0) then return false; end
	if (gFdr_State ~= FDR_NULL) then return false; end

	Atr_Finder_CancelBuy ();
	Atr_Finder_CancelGroup ();

	-- no name/level/usable narrowing: a category sweep wants the whole class
	gFdr_SearchText	= "";
	gFdr_MinLevel	= nil;
	gFdr_MaxLevel	= nil;
	gFdr_UsableOnly	= nil;

	gFdr_Results		= {};
	gFdr_Display		= {};
	gFdr_Page			= 0;
	gFdr_TotalPages		= 0;
	gFdr_DupRetries		= 0;
	gFdr_SkippedPages	= 0;
	gFdr_CapHit			= false;
	gFdr_WaitTicks		= 0;
	gFdr_RetryHold		= 0;

	-- The large-scan confirmation must NOT fire during a queued run. The
	-- dialog is built as a Finder-panel child, and Atr_FullScanFrame is
	-- toplevel at DIALOG strata, so the prompt appears BEHIND it: the scan
	-- parks in FDR_PAUSED waiting for a click the user cannot make, and
	-- nothing in OnUpdate drives that state, so it waits forever.
	-- Marking each spec pre-warned reuses the existing suppression. Choosing
	-- categories and pressing the button IS the confirmation.
	local q;
	for q = 1, #specs do
		if (type (specs[q]) == "table") then specs[q].warned = true; end
	end

	gFdr_SpecQueue		= specs;
	gFdr_SpecIdx		= 1;
	gFdr_State			= FDR_PREQUERY;
	gFdr_QuerySentAt	= time();

	gFdr_OnFinish = onFinish;

	if (Atr_NewQuery) then
		gFdr_Query = Atr_NewQuery();
	else
		gFdr_Query = nil;
	end

	if (Atr_Finder_SearchButton) then
		Atr_Finder_SearchButton:SetText (FT("Cancel"));
	end
	Fdr_SetMessage (FT("Scanning..."));
	if (Atr_Finder_Redisplay) then Atr_Finder_Redisplay (); end

	return true;
end


-- FINDER_TAB: scan the AH for ONE exact item name and feed the price DB, for
-- callers OUTSIDE the Finder tab (the Sell tab's "Scan Prices" button).
-- Identical to Atr_Finder_StartQueueScan except the server-side NAME filter is
-- KEPT instead of blanked, and the queue is a single all-class spec -- so the
-- server returns just this item's listings and the ordinary Fdr_PriceDB_Update
-- writes its lowest current buyout to gAtr_ScanDB[name].  onFinish fires with
-- (pAdd, pUpd, pSkip, pWhy) exactly as for a queued scan.  The shared event
-- frame is parented to UIParent, so this pages correctly while the user is on
-- the Sell tab.  Returns false when the engine is already busy.
function Atr_Finder_StartNameScan (name, onFinish)

	if (type (name) ~= "string" or name == "") then return false; end
	if (gFdr_State ~= FDR_NULL) then return false; end

	Atr_Finder_CancelBuy ();
	Atr_Finder_CancelGroup ();

	gFdr_SearchText	= name;			-- the ONE difference from StartQueueScan
	gFdr_MinLevel	= nil;
	gFdr_MaxLevel	= nil;
	gFdr_UsableOnly	= nil;

	gFdr_Results		= {};
	gFdr_Display		= {};
	gFdr_Page			= 0;
	gFdr_TotalPages		= 0;
	gFdr_DupRetries		= 0;
	gFdr_SkippedPages	= 0;
	gFdr_CapHit			= false;
	gFdr_WaitTicks		= 0;
	gFdr_RetryHold		= 0;

	-- one all-class spec: the server narrows by the name filter set above.
	-- warned is pre-set for the same reason StartQueueScan does it -- no
	-- confirmation dialog can be answered for a programmatic run.
	gFdr_SpecQueue		= { { class = 0, subclass = 0, autoAccept = true, label = name, warned = true } };
	gFdr_SpecIdx		= 1;
	gFdr_State			= FDR_PREQUERY;
	gFdr_QuerySentAt	= time();

	gFdr_OnFinish = onFinish;

	if (Atr_NewQuery) then
		gFdr_Query = Atr_NewQuery();
	else
		gFdr_Query = nil;
	end

	if (Atr_Finder_SearchButton) then
		Atr_Finder_SearchButton:SetText (FT("Cancel"));
	end
	Fdr_SetMessage (FT("Scanning..."));
	if (Atr_Finder_Redisplay) then Atr_Finder_Redisplay (); end

	return true;
end


function Atr_Finder_StartSearch ()

	if (gFdr_State ~= FDR_NULL) then
		Atr_Finder_CancelSearch (true);
		return;
	end

	Atr_Finder_CancelBuy ();
	Atr_Finder_CancelGroup ();

	gFdr_SearchText = Atr_Finder_SearchBox:GetText() or "";

	local minlev = Atr_Finder_MinLevel:GetNumber();
	local maxlev = Atr_Finder_MaxLevel:GetNumber();

	gFdr_MinLevel	= (minlev and minlev > 0) and minlev or nil;
	gFdr_MaxLevel	= (maxlev and maxlev > 0) and maxlev or nil;
	gFdr_UsableOnly	= Atr_Finder_UsableCheck:GetChecked() and 1 or nil;

	gFdr_Results		= {};
	gFdr_Display		= {};
	gFdr_Page			= 0;
	gFdr_TotalPages		= 0;
	gFdr_DupRetries		= 0;
	gFdr_SkippedPages	= 0;
	gFdr_CapHit			= false;
	gFdr_WaitTicks		= 0;
	gFdr_RetryHold		= 0;
	gFdr_SpecQueue		= Fdr_BuildSpecQueue ();
	gFdr_SpecIdx		= 1;
	gFdr_State			= FDR_PREQUERY;
	gFdr_QuerySentAt	= time();

	if (Atr_NewQuery) then
		gFdr_Query = Atr_NewQuery();
	else
		gFdr_Query = nil;
	end

	Atr_Finder_SearchButton:SetText (FT("Cancel"));
	Fdr_SetMessage (FT("Scanning..."));
	Atr_Finder_Redisplay ();
end

local function Fdr_SendQuery ()

	local queryString = gFdr_SearchText;

	if (zc and zc.UTF8_Truncate) then
		queryString = zc.UTF8_Truncate (queryString, 63);
	end

	local spec = gFdr_SpecQueue[gFdr_SpecIdx] or {};

	QueryAuctionItems (queryString, gFdr_MinLevel, gFdr_MaxLevel, spec.invType,
					   spec.class or 0, spec.subclass or 0,
					   gFdr_Page, gFdr_UsableOnly, nil);

	gFdr_State			= FDR_POSTQUERY;
	gFdr_QuerySentAt	= time();
end

local function Fdr_AnalyzeResults ()

	-- per-record enrichment: equippable flag, item level, stat discovery

	local statSeen	= {};	-- key -> { count, min, max }
	local eqTotal	= 0;

	local i;
	for i = 1, #gFdr_Results do

		local rec = gFdr_Results[i];

		if (rec.link) then
			rec.equippable = (IsEquippableItem and IsEquippableItem (rec.link)) and true or false;

			if (GetItemInfo) then
				local _, _, _, iLevel, reqLevel, itype, isub, _, eloc = GetItemInfo (rec.link);
				rec.ilvl		= (rec.equippable and iLevel) or 0;
				rec.baseReq		= reqLevel;
				rec.itemType	= itype;
				rec.itemSubType	= isub;
				rec.equipLoc	= eloc;
			else
				rec.ilvl = 0;
			end

			if (rec.equippable) then
				eqTotal = eqTotal + 1;
			end

			if (rec.equippable and GetItemStats) then
				for statKey, val in pairs (Fdr_GetStats (rec)) do
					if (val and val ~= 0) then
						local s = statSeen[statKey];
						if (not s) then
							s = { count = 0, min = val, max = val };
							statSeen[statKey] = s;
						end
						s.count	= s.count + 1;
						if (val < s.min) then s.min = val; end
						if (val > s.max) then s.max = val; end
					end
				end
			end
		else
			rec.equippable	= false;
			rec.ilvl		= 0;
		end
	end

	-- a "stat" that appears on EVERY item with the SAME value (like Ascension's
	-- PVE_POWER, constant across the whole AH) carries no information: sorting
	-- and filtering by it is meaningless, so keep it out of the dropdown.
	-- Ascension scales item INSTANCES server-side without changing the link:
	-- identical links can be different power levels, and every link-based API
	-- (stats, ilvl, tooltips) reports only the cached base version. The one
	-- per-instance signal in the list API is the required level, so flag a
	-- record as scaled when its level disagrees with the base item's, or when
	-- listings sharing a link disagree with each other.
	local linkLevels = {};
	for i = 1, #gFdr_Results do
		local rec = gFdr_Results[i];
		if (rec.equippable and rec.link) then
			local nl = Fdr_NormalizeLink (rec.link);
			local e  = linkLevels[nl];
			if (not e) then
				linkLevels[nl] = { min = rec.level or 0, max = rec.level or 0 };
			else
				if ((rec.level or 0) < e.min) then e.min = rec.level or 0; end
				if ((rec.level or 0) > e.max) then e.max = rec.level or 0; end
			end
		end
	end

	for i = 1, #gFdr_Results do
		local rec = gFdr_Results[i];
		if (rec.equippable and rec.link) then
			local e = linkLevels[Fdr_NormalizeLink (rec.link)];
			rec.scaled = (e and e.min ~= e.max)
					or (rec.baseReq and rec.baseReq > 0 and rec.level and rec.level > 0
						and rec.level ~= rec.baseReq)
					or false;

			if (rec.scaled) then
				gFdr_ScaledNames[rec.name] = true;
			end
		end
	end

	gFdr_StatKeys = {};
	for key, s in pairs (statSeen) do
		local ubiquitousConstant = (eqTotal >= 5 and s.count == eqTotal and s.min == s.max);
		if (not ubiquitousConstant and key ~= FDR_DPS_KEY) then
			tinsert (gFdr_StatKeys, key);
		end
	end
	table.sort (gFdr_StatKeys, function (a, b)
		return Fdr_StatDisplayName (a) < Fdr_StatDisplayName (b);
	end);

	-- if the previously selected stat no longer exists in results, keep it
	-- anyway (values just read 0) so the user's choice is stable
end

function Atr_Finder_GetStatKeys ()
	return gFdr_StatKeys;
end

local function Fdr_FinishSearch (note)

	gFdr_State = FDR_NULL;

	Atr_Finder_SearchButton:SetText (FT("Search"));
	Atr_Finder_SearchButton:Enable();

	Fdr_AnalyzeResults ();
	Atr_Finder_RebuildDisplay ();

	local n = #gFdr_Results;

	local msg;
	if (n == 0) then
		msg = FT("No auctions found");
	elseif (#gFdr_Display < n) then
		local why = (#gFdr_SelectedStats > 0) and FT("%d rows after filters") or FT("%d rows after grouping");
		msg = string.format (FT("%d auctions found"), n).." · "..string.format (why, #gFdr_Display);
	else
		msg = string.format (FT("%d auctions found"), n);
	end

	if (gFdr_CapHit) then
		local capnote = FT("page ceiling reached - results incomplete");
		note = note and (note..", "..capnote) or capnote;
	end

	local pAdd, pUpd, pSkip, pWhy = Fdr_PriceDB_Update ();
	if (pAdd + pUpd > 0) then
		msg = msg..string.format (FT("  ·  prices: %d new, %d updated"), pAdd, pUpd);
		if (pSkip > 0) then
			msg = msg..string.format (FT(", %d scaled skipped"), pSkip);
		end
	else
		local why = Fdr_PriceDB_WhyText (pWhy, pSkip);		-- nil for "empty": the row count already said it
		if (why) then
			note = note and (note..", "..why) or why;
		end
	end

	if (gFdr_SkippedPages > 0) then
		local skipnote = string.format (FT("%d pages skipped - server lag"), gFdr_SkippedPages);
		note = note and (note..", "..skipnote) or skipnote;
	end

	if (note) then
		msg = msg.."  |cffff8888("..note..")|r";
	end

	Fdr_SetMessage (msg);
	Fdr_UpdateHeaderArrows ();
	Fdr_SortAndRedisplay ();

	Fdr_Research_Absorb ();		-- research ledger: always on, tiny, and useless if it only runs when a checkbox happens to be ticked
	Fdr_SaveDebugDump ();

	-- FINDER_TAB: full-scan driver hook.  Deliberately LAST, so the price
	-- feed and the research ledger have both already consumed this
	-- category's rows and the driver is free to throw them away.
	if (gFdr_OnFinish) then
		gFdr_OnFinish (pAdd or 0, pUpd or 0, pSkip or 0, pWhy);
	end
end




-- ===========================================================================
-- FINDER_TAB begin: price database feed
--
-- A category sweep is long, and the user reasonably does not want to run one
-- without Auctionator's own price data benefiting.  Upstream's Full Scan is
-- dead on this server (it calls QueryAuctionItems with getAll=true, which
-- Ascension disables; its paged "slow scan" alternative was never written -
-- see VENDOR-PRICE-RESEARCH.md), so the Finder feeds the DB instead.
--
-- gAtr_ScanDB is AUCTIONATOR_PRICE_DATABASE[realm_Faction]: a flat
-- name -> lowest per-unit buyout map.  gAtr_MeanDB is the same keying with an
-- array of up to 15 sorted samples.  Both are created by Atr_InitScanDB at
-- login, so nothing needs initialising here.
--
-- FOUR RULES make this safe on a PARTIAL scan, which is the whole difference
-- from upstream's whole-AH pass:
--   1. NEVER DELETE.  Upstream prunes names below the quality floor because a
--      full scan saw everything; for us a missing name means "not scanned",
--      not "not for sale".  Insert and update only.
--   2. SKIP SCALED EQUIPMENT.  The DB is name-keyed, which CLAUDE.md flags as
--      never safe here - one price would stand in for every scaled variant.
--      Nothing of value is lost: commodities never scale.
--   3. SKIP A CAPPED SCAN.  A truncated slice yields the lowest of an
--      arbitrary subset, which is biased HIGH and would silently inflate
--      prices.  Per-category scanning should mean this never fires.
--   4. BID-ONLY ROWS CONTRIBUTE NOTHING.  buyoutPrice 0 must never enter the
--      DB as a zero price.
-- ===========================================================================

function Fdr_PriceDB_Enabled ()

	if (AUCTIONATOR_FINDER_SETTINGS == nil) then return true; end
	return (AUCTIONATOR_FINDER_SETTINGS.feedPriceDB ~= false);		-- default ON
end


-- Turns the reason token from Fdr_PriceDB_Update into a status-line note.
-- Returns nil when the outcome needs no note (rows were written, or the scan
-- found nothing at all and the row count has already said so).
function Fdr_PriceDB_WhyText (why, skipped)

	if (why == nil or why == "empty") then return nil; end

	if (why == "off")		then return FT("prices not saved - Prices option is off (options > Scanning)");	end
	if (why == "cap")		then return FT("prices not saved - capped scan");				end
	if (why == "nodb")		then return FT("prices not saved - price DB not loaded");		end
	if (why == "nobuyout")	then return FT("prices not saved - no buyout rows");			end
	if (why == "quality")	then return FT("prices not saved - below the quality floor");	end
	if (why == "scaled") then
		return string.format (FT("prices not saved - all %d rows are scaled gear"), skipped or 0);
	end

	return FT("prices not saved");
end


-- returns added, updated, skippedScaled, reason
--
-- reason is nil when rows were written and a short token otherwise, so the
-- caller can always tell the user WHY nothing was saved.  Silence was the
-- real complaint here: four of these paths used to return 0,0,0 with no
-- message, which is indistinguishable from the feed never running at all.
--   "empty"    - the scan itself found nothing
--   "off"      - the Prices checkbox is unticked
--   "cap"      - rule 3: capped scan, prices would be biased high
--   "nodb"     - Atr_InitScanDB has not run (gAtr_ScanDB is not a table)
--   "scaled"   - rule 2: every candidate row was scaled equipment
--   "nobuyout" - rule 4: every row was bid-only (or a zero unit price)
--   "quality"  - everything sat below AUCTIONATOR_SCAN_MINLEVEL
-- partial=true: INSERT ONLY, never overwrite.  A half-finished scan's
-- "lowest" price is biased high (the cheap listing may be on a page we never
-- reached), so it must not be allowed to degrade a value a completed scan
-- already established -- but for a name we have NOTHING on, a possibly-high
-- price still beats no price at all.
function Fdr_PriceDB_Update (results, partial)

	results = results or gFdr_Results;
	if (type (results) ~= "table" or #results == 0) then return 0, 0, 0, "empty"; end
	if (not Fdr_PriceDB_Enabled ()) then return 0, 0, 0, "off"; end
	if (gFdr_CapHit) then return 0, 0, 0, "cap"; end						-- rule 3
	if (type (gAtr_ScanDB) ~= "table") then return 0, 0, 0, "nodb"; end		-- Atr_InitScanDB has not run

	local lows, quals, skipped = {}, {}, 0;
	local candidates = 0;						-- distinct names that cleared rules 2 and 4

	local i;
	for i = 1, #results do

		local rec = results[i];

		if (rec and rec.name) then

			if (rec.equippable and rec.scaled) then				-- rule 2
				skipped = skipped + 1;
			else
				local cnt = tonumber (rec.count or 1) or 1;
				if (cnt < 1) then cnt = 1; end

				local bo = tonumber (rec.buyoutPrice or 0) or 0;
				if (bo > 0) then								-- rule 4
					local unit = math.floor (bo / cnt);
					if (unit > 0) then
						if (lows[rec.name] == nil) then
							lows[rec.name] = unit;
							candidates = candidates + 1;
						elseif (unit < lows[rec.name]) then
							lows[rec.name] = unit;
						end
						quals[rec.name] = rec.quality or 1;
					end
				end
			end
		end
	end

	local added, updated = 0, 0;
	local minq = tonumber (AUCTIONATOR_SCAN_MINLEVEL or 0) or 0;

	for name, price in pairs (lows) do

		if ((quals[name] or 0) + 1 >= minq) then				-- upstream's quality floor, same 1-based shift

			local known = (gAtr_ScanDB[name] ~= nil);

			if (partial and known) then
				price = nil;									-- keep the completed scan's value
			else
				if (known) then updated = updated + 1; else added = added + 1; end
				gAtr_ScanDB[name] = price;					-- rule 1: assign, never nil out
			end

			if (price and type (gAtr_MeanDB) == "table") then
				local m = gAtr_MeanDB[name];
				if (type (m) ~= "table") then m = {}; gAtr_MeanDB[name] = m; end
				if (#m >= 15) then table.remove (m, math.random (1, #m)); end
				tinsert (m, price);
				table.sort (m);
			end
		end
	end

	-- Feed changed the price DB: drop the suffix-variant estimate cache so base
	-- gear estimates (Atr_GetAHVariantEstimate) reflect the new variant prices.
	if (added + updated > 0 and Atr_AH_InvalidateVariantCache) then Atr_AH_InvalidateVariantCache (); end

	if (added + updated > 0 and time) then
		AUCTIONATOR_LAST_SCAN_TIME = time();					-- display-only; the real gate is CanSendAuctionQuery
	end

	if (added + updated > 0) then
		return added, updated, skipped, nil;
	end

	-- nothing written: say which rule swallowed the scan
	local why;
	if (candidates == 0) then
		why = (skipped > 0) and "scaled" or "nobuyout";			-- rule 2 vs rule 4
	else
		why = "quality";										-- everything below the quality floor
	end

	return added, updated, skipped, why;
end


-- /atrprices - the direct answer to "is the Finder actually feeding the
-- price database?".  Prints the feed's state and the DB's current size, so
-- the question can be settled without a scan or a /reload.
function Fdr_PriceDB_Report ()

	local function say (s)
		if (zc and zc.msg_atr) then zc.msg_atr (s);
		elseif (DEFAULT_CHAT_FRAME) then DEFAULT_CHAT_FRAME:AddMessage (s); end
	end

	say ("Finder price feed: "..(Fdr_PriceDB_Enabled () and "|cff40ff40ON|r" or "|cffff4040OFF|r (Auctionator options > Scanning)"));

	if (type (gAtr_ScanDB) ~= "table") then
		say ("  |cffff4040gAtr_ScanDB is not loaded|r - Auctionator's Atr_InitScanDB has not run.");
		return 0;
	end

	local names, mean = 0, 0;
	local k;
	for k in pairs (gAtr_ScanDB) do names = names + 1; end
	if (type (gAtr_MeanDB) == "table") then
		for k in pairs (gAtr_MeanDB) do mean = mean + 1; end
	end

	say (string.format ("  price DB: |cffffffff%d|r names, mean DB: |cffffffff%d|r names", names, mean));

	local t = tonumber (AUCTIONATOR_LAST_SCAN_TIME or 0) or 0;
	if (t > 0 and time) then
		local mins = math.floor ((time() - t) / 60);
		say (string.format ("  last write: |cffffffff%d|r minute%s ago", mins, (mins == 1) and "" or "s"));
	else
		say ("  last write: |cff888888never|r");
	end

	say (string.format ("  quality floor: |cffffffff%d|r  (Auctionator options; rows below it are ignored)",
					tonumber (AUCTIONATOR_SCAN_MINLEVEL or 0) or 0));
	say ("  |cff888888scaled gear is excluded by design - the DB is name-keyed and cannot tell variants apart|r");

	return names;
end


-- Read-only inspector for a single item's stored price data.  Prints exactly
-- what the two name-keyed databases hold for a name so a "tooltip looks wrong"
-- report can be pinned to a cause:
--   * auction (gAtr_ScanDB)        - the single lowest per-unit buyout kept by
--                                    the last scan (no outlier rejection)
--   * median samples (gAtr_MeanDB) - the up-to-15 sample array the median is
--                                    taken from; a wide spread means the median
--                                    is mixing several market eras
--   * tooltip shows                - what Atr_GetAuctionPrice / Atr_GetMeanPrice
--                                    actually render (may differ from the raw
--                                    store via recent-sale / variant fallbacks)
-- Touches nothing; accepts a typed name or a shift-clicked item link, and
-- resolves case-insensitively to the real stored key.
function Fdr_PriceDB_Inspect (query)

	local function say (s)
		if (zc and zc.msg_atr) then zc.msg_atr (s);
		elseif (DEFAULT_CHAT_FRAME) then DEFAULT_CHAT_FRAME:AddMessage (s); end
	end

	if (type (gAtr_ScanDB) ~= "table") then
		say ("  |cffff4040gAtr_ScanDB is not loaded|r - Auctionator's Atr_InitScanDB has not run.");
		return;
	end

	query = tostring (query or "");
	local bracket = query:match ("%[(.-)%]");			-- name inside a shift-clicked link
	local name = bracket or query:gsub ("^%s+", ""):gsub ("%s+$", "");

	if (name == "") then
		say ("  usage: |cffffffff/atrprices <item name>|r  (or shift-click an item into chat)");
		return;
	end

	-- Resolve to an actual stored key: exact first, then case-insensitive across
	-- either database, so "fadeleaf" finds the "Fadeleaf" the DB is keyed under.
	local haveExact = (gAtr_ScanDB[name] ~= nil)
		or (type (gAtr_MeanDB) == "table" and type (gAtr_MeanDB[name]) == "table");
	if (not haveExact) then
		local lq = name:lower();
		local k;
		for k in pairs (gAtr_ScanDB) do
			if (type (k) == "string" and k:lower() == lq) then name = k; haveExact = true; break; end
		end
		if (not haveExact and type (gAtr_MeanDB) == "table") then
			for k in pairs (gAtr_MeanDB) do
				if (type (k) == "string" and k:lower() == lq) then name = k; break; end
			end
		end
	end

	say (string.format ("Price DB inspect: |cffffd100%s|r", name));

	local auc = gAtr_ScanDB[name];
	say (string.format ("  auction (gAtr_ScanDB): %s",
			auc and Fdr_MoneyString (auc) or "|cff888888(not stored)|r"));

	local m = (type (gAtr_MeanDB) == "table") and gAtr_MeanDB[name] or nil;
	if (type (m) == "table" and #m > 0) then
		local n = #m;
		local lo, hi = m[1], m[1];
		local parts = {};
		local i;
		for i = 1, n do
			if (m[i] < lo) then lo = m[i]; end
			if (m[i] > hi) then hi = m[i]; end
			parts[i] = Fdr_MoneyString (m[i]);
		end
		say (string.format ("  median samples (gAtr_MeanDB): |cffffffff%d|r/15", n));
		say ("    "..table.concat (parts, "|cff555555,|r "));
		say (string.format ("    low %s   high %s   spread |cffffffffx%.1f|r",
				Fdr_MoneyString (lo), Fdr_MoneyString (hi),
				(lo > 0) and (hi / lo) or 0));
	else
		say ("  median samples (gAtr_MeanDB): |cff888888(none)|r");
	end

	-- What the tooltip renders can differ from the raw store (recent-sale or
	-- suffix-variant fallbacks in Atr_GetAuctionPrice), so show both.
	local tipAuc = (Atr_GetAuctionPrice) and Atr_GetAuctionPrice (name) or nil;
	local tipMed = (Atr_GetMeanPrice) and Atr_GetMeanPrice (name) or nil;
	say (string.format ("  tooltip shows -> auction %s   median %s",
			tipAuc and Fdr_MoneyString (tipAuc) or "|cff888888--|r",
			tipMed and Fdr_MoneyString (tipMed) or "|cff888888--|r"));
end


-- The toggle itself lives in the options panel now, so the slash command
-- doubles as the fallback for any build whose Scanning panel we cannot find:
-- /atrprices on|off.  No argument still just reports; any other argument (a
-- typed name or a shift-clicked item link) inspects that one item's stored
-- price data via Fdr_PriceDB_Inspect.
if (SlashCmdList) then
	SLASH_ATRPRICEFEED1 = "/atrprices";
	SlashCmdList["ATRPRICEFEED"] = function (msg)
		local raw = tostring (msg or "");
		local firstword = raw:lower():match ("%a+");
		if (firstword == "on" or firstword == "off") then
			AUCTIONATOR_FINDER_SETTINGS = AUCTIONATOR_FINDER_SETTINGS or {};
			AUCTIONATOR_FINDER_SETTINGS.feedPriceDB = (firstword == "on");
			if (Fdr_Options_Sync) then Fdr_Options_Sync (); end
			Fdr_PriceDB_Report ();
			return;
		end

		-- Anything other than on/off/blank names an item to inspect.
		if (raw:match ("%[(.-)%]") or raw:match ("%S")) then
			Fdr_PriceDB_Inspect (raw);
			return;
		end

		Fdr_PriceDB_Report ();
	end
end
-- FINDER_TAB end: price database feed

-- ===========================================================================
-- FINDER_TAB begin: research targets
--
-- Vendor-price research needs SCALED EQUIPMENT VARIANTS that are (a) cheap,
-- (b) repeatedly available, and (c) at levels no confirmed sale has mapped
-- yet.  Finding those by eye is the bottleneck (VENDOR-PRICE-RESEARCH.md,
-- harvest #5 protocol), so every scan feeds a persistent ledger and the
-- ledger is ranked into a shopping list.
--
-- The per-instance truth used here is rec.level - GetAuctionItemInfo("list")'s
-- required-level return, the cornerstone documented in ASCENSION-CLIENT-NOTES.
-- It is on EVERY scanned row without running Verify.  rec.trueIlvl is stored
-- when Verify happens to have pinned it, but nothing depends on it: requiring
-- Verify would make the ledger depend on a second query pass per name.
--
-- Only equippable+scaled rows are absorbed.  That mirrors the vendor learning
-- hook, which files a sale NOWHERE unless GetItemInfo gave the item an equip
-- slot (only equipment scales).
-- ===========================================================================

local FDR_RESEARCH_VER = 1;

-- IsEquippableItem() is true for ammo, bags and quivers.  A wildcard scan
-- proved this live: 5 of 13 "equippable" itemIDs in a 2500-row sample were
-- ammo (Thorium Shells, Forestwood Arrows, Mithril Gyro-Shot...).  None of
-- these scale and none can ever be a research target, so keep them out of
-- the ledger entirely rather than relying on the scaled test to reject them.
local FDR_RESEARCH_SKIP_SLOT = {
	INVTYPE_AMMO	= true,
	INVTYPE_BAG		= true,
	INVTYPE_QUIVER	= true,
};

function Fdr_ResearchDB ()

	if (type (AUCTIONATOR_FINDER_RESEARCH) ~= "table") then
		AUCTIONATOR_FINDER_RESEARCH = {};
	end

	local db = AUCTIONATOR_FINDER_RESEARCH;

	if (type (db.items) ~= "table")  then db.items = {}; end
	if (type (db.scans) ~= "number") then db.scans = 0; end
	db.ver = FDR_RESEARCH_VER;

	return db;
end


-- Global, not a local: Fdr_AHVariant_Record sits ~2000 lines EARLIER in the
-- file and needs the same derivation.  A global resolves at call time, so the
-- definition order stops mattering, and it buys back a file-local slot.
function Fdr_ResearchItemID (link)

	if (not link) then return nil; end
	return tonumber (link:match ("|Hitem:(%d+)") or link:match ("^item:(%d+)"));
end


-- Absorb the finished scan.  Called once per scan, after the scaled-detection
-- pass has run (rec.scaled is only meaningful afterwards).
function Fdr_Research_Absorb (results)

	results = results or gFdr_Results;
	if (type (results) ~= "table" or #results == 0) then return 0; end

	local db = Fdr_ResearchDB();
	db.scans = (db.scans or 0) + 1;
	if (time) then db.when = time(); end

	local touched, n = {}, 0;

	local i;
	for i = 1, #results do

		local rec = results[i];

		if (rec and rec.equippable and rec.scaled and rec.link
				and not FDR_RESEARCH_SKIP_SLOT[rec.equipLoc or ""]) then

			local id  = Fdr_ResearchItemID (rec.link);
			local lvl = tonumber (rec.level or 0) or 0;

			if (id and id > 0 and lvl > 0) then

				local it = db.items[id];
				if (it == nil) then it = { v = {} }; db.items[id] = it; end
				if (type (it.v) ~= "table") then it.v = {}; end

				it.n    = rec.name or it.n;
				it.q    = rec.quality or it.q;
				it.eq   = rec.equipLoc or it.eq;
				it.seen = (it.seen or 0) + 1;

				-- cached TEMPLATE il/req.  Untrustworthy as a price input (see
				-- the measurement problem) but the best available FLOOR for
				-- deciding what counts as a down-scale - see Fdr_Research_Floor.
				if (rec.baseReq and rec.baseReq > 0) then it.brq = rec.baseReq; end
				if (rec.ilvl	and rec.ilvl   > 0) then it.bil = rec.ilvl;	  end

				if (not touched[id]) then
					touched[id] = true;
					it.sc = (it.sc or 0) + 1;			-- distinct scans, not listings: supply that RECURS
				end

				local v = it.v[lvl];
				if (v == nil) then v = { n = 0 }; it.v[lvl] = v; end
				v.n = v.n + 1;

				local cnt = tonumber (rec.count or 1) or 1;
				if (cnt < 1) then cnt = 1; end

				local bo = tonumber (rec.buyoutPrice or 0) or 0;
				if (bo > 0) then								-- buyout 0 is BID-ONLY, never free (ASCENSION-CLIENT-NOTES)
					local unit = math.floor (bo / cnt);
					if (v.b == nil or unit < v.b) then v.b = unit; end
				end

				-- BID COST.  Scaled gear is overwhelmingly listed bid-only on
				-- this server (7 of 8 scaled listings in the first live wildcard
				-- scan) - sellers do not know what a scaled variant is worth,
				-- which is the very gap this addon closes.  Requiring a buyout
				-- therefore discarded almost the entire research population, so
				-- record what it costs to BID as a fallback cost: the current
				-- bid plus one increment if the listing is contested, else the
				-- opening bid.
				local need = tonumber (rec.minBid or 0) or 0;
				local cur  = tonumber (rec.bidAmount or 0) or 0;
				if (cur > 0) then need = cur + (tonumber (rec.minIncrement or 0) or 0); end
				if (need > 0) then
					local unit = math.floor (need / cnt);
					if (v.mb == nil or unit < v.mb) then v.mb = unit; end
				end

				if (rec.trueIlvl and rec.trueIlvl > 0) then v.il = rec.trueIlvl; end

				n = n + 1;
			end
		end
	end

	return n;
end


-- THE DOWN-SCALE FLOOR.  A listing is only down-scaled if it sits below the
-- item's EFFECTIVE BASE - the il at which the multiplier is 1.0.  The first
-- version of this compared against the lowest CONFIRMED RUNG, which is wrong
-- whenever the only rung is a high one, and it cost real gold: item 14573's
-- sole rung was il52/rq48, so rq23/29/43 were all flagged "down" and all three
-- turned out to be AT or ABOVE the effective base (il26 = the cached template
-- il27 minus one).  Nothing was learned about the down curve.
--
-- The cached template (brq) is a far better floor: measured effective bases sit
-- just BELOW their template (-1 amice, -2 boots, -6 gloves), never above.  So
-- take the lower of the template and the lowest confirmed rung; a level below
-- that is genuinely below base.  Either input alone is enough - an item with no
-- rungs at all can still expose a below-template listing, which is exactly the
-- data the down region needs.
local function Fdr_Research_Floor (lowRq, brq)

	if (lowRq and brq) then return math.min (lowRq, brq); end
	return lowRq or brq;
end


-- What the vendor-price DB already knows about an itemID, read straight out of
-- AUCTIONATOR_VENDOR_LEARNED.obs (keys are "id:il:rq").  Matching on the rq
-- component is what lets a target be judged from a scan alone - obs is keyed by
-- BOTH, but rq is the only half a scan can see without Verify.
local function Fdr_Research_Known (id)

	local known, lowRq, rungs = {}, nil, 0;

	local db = AUCTIONATOR_VENDOR_LEARNED;
	if (type (db) ~= "table" or type (db.obs) ~= "table") then return known, nil, 0; end

	local pre  = id..":";
	local plen = string.len (pre);

	for k, o in pairs (db.obs) do
		if (string.sub (k, 1, plen) == pre and o and o.p and o.p > 0) then
			local rq = tonumber (string.match (k, "^%d+:%d+:(%d+)"));
			if (rq) then
				if (not known[rq]) then rungs = rungs + 1; end
				known[rq] = true;
				if (lowRq == nil or rq < lowRq) then lowRq = rq; end
			end
		end
	end

	return known, lowRq, rungs;
end


-- Rank the ledger.  The weights are deliberately crude and readable rather
-- than fitted; every component is reported by /atrtarget so a bad ranking can
-- be diagnosed instead of guessed at.
--
--   unmapped x 10  every unmapped level is one new confirmed rung
--   down     x 30  below the lowest confirmed rung = the ONLY unmapped part
--                  of the pricing model (harvest #5 priority 3)
--   rungs>0    25  an item with one rung gains INTERPOLATION from a second,
--                  which prices its whole span - singletons price one tuple
--   spread   <=30  how wide a ladder this item can actually supply
--   scans    <=20  recurring availability: can you buy it again next week
--
-- score = value / (1 + cheapest unmapped COST in gold), i.e. research value
-- per gold committed - and the gold is a LOAN, recoverable via buyback+relist.
-- Cost prefers a buyout; where none exists the bid cost is used instead and the
-- score is scaled by FDR_RESEARCH_BID_PENALTY, because winning a bid means
-- waiting out the auction and possibly losing it.
local FDR_RESEARCH_BID_PENALTY = 0.6;		-- bid-only targets are real, but slower and not guaranteed

-- Level-band relevance (2026-07).  The value/gold score above answers "what is
-- the most research per gold", which floats cheap low-level ladders to the top.
-- That is the wrong shopping list for the common case: a player - levelling or
-- at max - who wants the vendor ESTIMATE to be right for the gear they actually
-- see at their current level.  When an anchor level is supplied (the character
-- level by default, or an explicit /atrtarget override), a target whose unmapped
-- required levels sit in a window around it keeps its full score; targets that
-- sit further off fade towards a floor, so an exceptional out-of-band ladder
-- still appears but is demoted.  anchor == nil (the offline dump) leaves the
-- ranking untouched, so the uploaded research file stays a full ledger view.
local FDR_RESEARCH_BAND_BELOW = 8;		-- gear at/just below your level is what you wear and price
local FDR_RESEARCH_BAND_ABOVE = 4;		-- a little above: the next upgrades you would buy
local FDR_RESEARCH_BAND_FADE  = 25;		-- levels from the window edge over which relevance fades to the floor
local FDR_RESEARCH_BAND_FLOOR = 0.25;	-- out-of-band targets keep this fraction of their score
local FDR_RESEARCH_BAND_BONUS = 12;		-- value added per unmapped level that sits IN the band

-- how far a required level sits OUTSIDE the band window around anchor (0 = inside)
local function Fdr_Research_BandDist (anchor, rq)
	local lo = anchor - FDR_RESEARCH_BAND_BELOW;
	local hi = anchor + FDR_RESEARCH_BAND_ABOVE;
	if (rq < lo) then return lo - rq; end
	if (rq > hi) then return rq - hi; end
	return 0;
end

local function Fdr_Research_Relevance (dist)
	local r = 1 - (dist / FDR_RESEARCH_BAND_FADE);
	if (r < FDR_RESEARCH_BAND_FLOOR) then return FDR_RESEARCH_BAND_FLOOR; end
	return r;
end

-- the anchor level for /atrtarget: an explicit override wins, else the live
-- character level; nil when neither is available (no weighting - e.g. the
-- offline dump, or a test env with no UnitLevel)
local function Fdr_Research_Anchor (override)
	if (override and override > 0) then return override; end
	if (type (UnitLevel) == "function") then
		local L = UnitLevel ("player");
		if (L and L > 0) then return L; end
	end
	return nil;
end

function Fdr_Research_Targets (limit, anchor)

	limit = limit or 12;

	local db  = Fdr_ResearchDB();
	local out = {};

	for id, it in pairs (db.items) do

		if (type (it.v) == "table") then

			local known, lowRq, rungs = Fdr_Research_Known (id);
			local floor = Fdr_Research_Floor (lowRq, it.brq);

			local variants, unmapped, down, inBand = 0, 0, 0, 0;
			local minRq, maxRq, cheap, cheapRq, bid, bidRq, bandDist;
			local cheapIB, cheapIBRq;		-- cheapest unmapped buyout INSIDE the level band

			for rq, v in pairs (it.v) do

				variants = variants + 1;
				if (minRq == nil or rq < minRq) then minRq = rq; end
				if (maxRq == nil or rq > maxRq) then maxRq = rq; end

				if (not known[rq]) then
					unmapped = unmapped + 1;
					if (floor and rq < floor) then down = down + 1; end
					if (v.b  and (cheap == nil or v.b  < cheap)) then cheap = v.b;  cheapRq = rq; end
					if (v.mb and (bid   == nil or v.mb < bid))   then bid   = v.mb; bidRq   = rq; end
					-- relevance is judged on the UNMAPPED levels - the ones actually worth
					-- buying.  bandDist is how close the NEAREST buyable level is; inBand
					-- counts how MANY sit in the window (an item offering several buyable
					-- levels at your level does more for the tooltips you see than one that
					-- merely grazes the band), and cheapIB is what you would actually spend
					-- to buy one at your level.
					if (anchor) then
						local d = Fdr_Research_BandDist (anchor, rq);
						if (bandDist == nil or d < bandDist) then bandDist = d; end
						if (d == 0) then
							inBand = inBand + 1;
							if (v.b and (cheapIB == nil or v.b < cheapIB)) then cheapIB = v.b; cheapIBRq = rq; end
						end
					end
				end
			end

			local cost, costRq, bidOnly = cheap, cheapRq, false;
			if (cost == nil and bid) then cost = bid; costRq = bidRq; bidOnly = true; end
			-- when anchored, price the item by the cheapest variant AT your level, so the
			-- score reflects the buy you would actually make (falls back to overall cheapest)
			if (anchor and cheapIB) then cost = cheapIB; costRq = cheapIBRq; bidOnly = false; end

			if (unmapped > 0 and cost) then

				local spread = (maxRq or 0) - (minRq or 0);
				local value  = unmapped * 10
							 + down * 30
							 + ((rungs > 0) and 25 or 0)
							 + math.min (spread, 30)
							 + math.min ((it.sc or 0) * 4, 20)
							 + (anchor and (inBand * FDR_RESEARCH_BAND_BONUS) or 0);

				local score = value / (1 + (cost / 10000));
				if (bidOnly) then score = score * FDR_RESEARCH_BID_PENALTY; end

				local relevance = 1;
				if (anchor and bandDist) then
					relevance = Fdr_Research_Relevance (bandDist);
					score = score * relevance;
				end

				tinsert (out, { id = id, name = it.n or ("item:"..id),
								value = value, score = score,
								cost = cost, costRq = costRq, bidOnly = bidOnly,
								unmapped = unmapped, variants = variants, down = down,
								seen = it.seen or 0, scans = it.sc or 0,
								spread = spread, rungs = rungs, inBand = inBand,
								relevance = relevance, bandDist = bandDist,
								minRq = minRq, maxRq = maxRq, floor = floor,
								item = it, known = known, lowRq = lowRq });
			end
		end
	end

	-- With an anchor, a target that offers a buyable variant IN your level window
	-- (bandDist == 0) always sorts above one that does not - that is what makes
	-- the list "gear at my level first" instead of "cheapest low-level ladder
	-- first".  Within each tier the existing value/gold score (already scaled by
	-- relevance, so nearer out-of-band targets edge out farther ones) decides.
	table.sort (out, function (a, b)
		if (anchor) then
			local ain = (a.bandDist == 0);
			local bin = (b.bandDist == 0);
			if (ain ~= bin) then return ain; end
		end
		if (a.score ~= b.score) then return a.score > b.score; end
		return a.id < b.id;
		end);

	while (#out > limit) do table.remove (out); end

	return out;
end


-- the unmapped levels of one target, cheapest-first is NOT the order wanted -
-- ascending level is, because the shopping list is read against the AH's own
-- level column.
function Fdr_Research_Wants (e)

	local want = {};

	for rq, v in pairs (e.item.v) do
		if (not e.known[rq]) then
			tinsert (want, { rq = rq, b = v.b, mb = v.mb, n = v.n, il = v.il,
							 bidOnly = (v.b == nil and v.mb ~= nil) and true or false,
							 down = (e.floor and rq < e.floor) and true or false });
		end
	end

	table.sort (want, function (a, b) return a.rq < b.rq; end);

	return want;
end


local function Fdr_ResearchMsg (s)

	if (zc and zc.msg_atr) then zc.msg_atr (s);
	elseif (DEFAULT_CHAT_FRAME) then DEFAULT_CHAT_FRAME:AddMessage (s); end
end


-- Plain money (no colour codes or coin textures) so the copy window pastes
-- cleanly out of the game.
local function Fdr_ResearchMoneyPlain (c)

	if (c == nil) then return "no buyout"; end

	local g  = math.floor (c / 10000);
	local s  = math.floor ((c % 10000) / 100);
	local cp = c % 100;

	local out = "";
	if (g > 0) then out = g.."g"; end
	if (s > 0) then out = out..((out ~= "") and " " or "")..s.."s"; end
	if (cp > 0 or out == "") then out = out..((out ~= "") and " " or "")..cp.."c"; end
	return out;
end


-- Build the whole report as PLAIN-TEXT lines - one string per line, no colour
-- codes.  Used both for the copy window (joined with newlines) and for the chat
-- fallback (printed line by line where there is no real UI).
local function Fdr_Research_BuildLines (t, db, anchor, limit)

	local nitems = 0;
	for _ in pairs (db.items) do nitems = nitems + 1; end

	local lines = {};
	tinsert (lines, "Finder research: "..nitems.." scaled items tracked across "..(db.scans or 0).." scans");
	if (anchor) then
		tinsert (lines, "prioritising gear near level "..anchor.."  (use  /atrtarget "..limit.." <level>  to aim at another band)");
	end

	if (#t == 0) then
		tinsert (lines, "");
		tinsert (lines, "no candidates yet - scan a cheap low-level gear category, then run /atrtarget again");
		return lines;
	end

	local i;
	for i = 1, #t do

		local e    = t[i];
		local want = Fdr_Research_Wants (e);

		local relnote = "";
		if (anchor and e.relevance and e.relevance < 1) then
			relnote = string.format ("  (level relevance x%.2f)", e.relevance);
		end

		tinsert (lines, "");
		tinsert (lines, string.format ("%d. %s  (id %d)  score %.1f%s",
						i, e.name, e.id, e.score, relnote));
		tinsert (lines, string.format ("   %d unmapped of %d levels, %d confirmed rung%s, seen %dx over %d scans",
						e.unmapped, e.variants, e.rungs, (e.rungs == 1) and "" or "s", e.seen, e.scans));

		local parts = {};
		local j;
		for j = 1, #want do		-- the window scrolls, so list every buyable level, not just six
			local w   = want[j];
			local tag = "req"..w.rq..(w.down and "!" or "").." ";
			if (w.b) then		tag = tag..Fdr_ResearchMoneyPlain (w.b);
			elseif (w.mb) then	tag = tag.."bid "..Fdr_ResearchMoneyPlain (w.mb);
			else				tag = tag.."no price"; end
			tinsert (parts, tag);
		end
		tinsert (lines, "   buy: "..table.concat (parts, "   "));
	end

	tinsert (lines, "");
	tinsert (lines, "! = below this item's base level (down region - highest value);  bid = no buyout, must be won on a bid");
	return lines;
end


-- The copy window: a plain multiline EditBox inside a scroll frame, pre-selected
-- so the text is ready for Ctrl+C the instant it opens.  When the client exposes
-- the native CopyToClipboard (it does on Ascension - see ASCENSION-CLIENT-NOTES)
-- a one-click button is added too.  Returns false where there is no real UI (a
-- headless client or the test harness), so the caller falls back to chat.
function Atr_Finder_ShowResearchCopy (text)

	if (type (CreateFrame) ~= "function") then return false; end

	local f = Atr_Finder_ResearchCopyFrame;
	if (not f) then

		f = CreateFrame ("Frame", "Atr_Finder_ResearchCopyFrame", UIParent);
		f:SetWidth (600);
		f:SetHeight (440);
		f:SetPoint ("CENTER");
		f:SetFrameStrata ("DIALOG");
		if (f.SetToplevel) then f:SetToplevel (true); end
		Fdr_StyleDialog (f);
		f:EnableMouse (true);
		f:SetMovable (true);
		f:RegisterForDrag ("LeftButton");
		f:SetScript ("OnDragStart", function (self) self:StartMoving (); end);
		f:SetScript ("OnDragStop",  function (self) self:StopMovingOrSizing (); end);

		local title = f:CreateFontString (nil, "ARTWORK", "GameFontNormalLarge");
		title:SetPoint ("TOP", 0, -14);
		title:SetText ("Finder Research Targets");

		local hint = f:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
		hint:SetPoint ("TOP", 0, -36);
		hint:SetText ("Text is selected - press Ctrl+C to copy.  Esc closes the window.");

		local close = CreateFrame ("Button", "$parentClose", f, "UIPanelCloseButton");
		close:SetPoint ("TOPRIGHT", -4, -4);

		local sf = CreateFrame ("ScrollFrame", "Atr_Finder_ResearchCopyScroll", f, "UIPanelScrollFrameTemplate");
		sf:SetPoint ("TOPLEFT", 16, -56);
		sf:SetPoint ("BOTTOMRIGHT", -34, 44);
		sf:EnableMouseWheel (true);
		sf:SetScript ("OnMouseWheel", function (self, delta)
			local v    = self:GetVerticalScroll () - (delta * 28);
			local maxv = self:GetVerticalScrollRange ();
			if (v < 0) then v = 0; elseif (v > maxv) then v = maxv; end
			self:SetVerticalScroll (v);
		end);

		local eb = CreateFrame ("EditBox", "Atr_Finder_ResearchCopyEdit", sf);
		eb:SetMultiLine (true);
		eb:SetAutoFocus (false);
		eb:SetFontObject (ChatFontNormal);
		eb:SetWidth (540);
		eb:SetScript ("OnEscapePressed", function (self) self:ClearFocus (); f:Hide (); end);
		sf:SetScrollChild (eb);
		f.edit = eb;

		-- native one-click copy, when the client provides it
		if (type (CopyToClipboard) == "function") then
			local cp = CreateFrame ("Button", "$parentCopy", f, "UIPanelButtonTemplate");
			cp:SetWidth (150);
			cp:SetHeight (22);
			cp:SetPoint ("BOTTOM", 0, 14);
			cp:SetText ("Copy to clipboard");
			cp:SetScript ("OnClick", function ()
				CopyToClipboard (f.edit:GetText () or "");
				if (zc and zc.msg_atr) then zc.msg_atr ("research list copied to clipboard"); end
			end);
		end

		if (type (UISpecialFrames) == "table") then
			tinsert (UISpecialFrames, "Atr_Finder_ResearchCopyFrame");	-- Esc closes it
		end
	end

	f.edit:SetText (text or "");

	-- grow the edit box to the content height so the scroll frame can scroll it
	local _, nl = tostring (text or ""):gsub ("\n", "\n");
	f.edit:SetHeight (math.max (340, (nl + 2) * 14));

	f:Show ();
	f.edit:SetCursorPosition (0);
	f.edit:SetFocus ();
	f.edit:HighlightText ();
	return true;
end


function Fdr_Research_Report (limit, levelOverride)

	limit = limit or 8;

	local db     = Fdr_ResearchDB();
	local anchor = Fdr_Research_Anchor (levelOverride);
	local t      = Fdr_Research_Targets (limit, anchor);

	local lines  = Fdr_Research_BuildLines (t, db, anchor, limit);
	local text   = table.concat (lines, "\n");

	-- Prefer the copy window; fall back to chat where there is no real UI.
	if (Atr_Finder_ShowResearchCopy (text)) then
		Fdr_ResearchMsg (#t.." research target"..((#t == 1) and "" or "s")
						.." - opened the copy window (Ctrl+C to copy)"
						..(anchor and (", gear near level "..anchor) or ""));
	else
		local i;
		for i = 1, #lines do Fdr_ResearchMsg (lines[i]); end
	end

	return t;
end


if (SlashCmdList) then
	SLASH_ATRRESEARCHTARGET1 = "/atrtarget";
	SlashCmdList["ATRRESEARCHTARGET"] = function (msg)
		-- "/atrtarget", "/atrtarget <n>", or "/atrtarget <n> <level>" - the
		-- second number aims the shopping list at a level band other than the
		-- character's own (the default anchor).
		local n, lvl = tostring (msg or ""):match ("(%d+)%D+(%d+)");
		if (n) then
			Fdr_Research_Report (tonumber (n), tonumber (lvl));
		else
			Fdr_Research_Report (tonumber (tostring (msg or ""):match ("%d+")) or 8);
		end
	end
end
-- FINDER_TAB end: research targets


-- Research capture toggle.  Was a session-only checkbox on the Finder tab;
-- it is a setting now (Interface > AddOns > Auctionator > Scanning), so it
-- persists.  Default OFF: the dump is an upload channel, not a feature.
function Fdr_ResearchDump_Enabled ()

	if (AUCTIONATOR_FINDER_SETTINGS == nil) then return false; end
	return (AUCTIONATOR_FINDER_SETTINGS.researchDump == true);		-- default OFF
end


-- Stores the raw scan into a SavedVariable (AUCTIONATOR_FINDER_DEBUG) so the
-- links and stats can be analyzed outside the game. Written to disk on
-- /reload or logout. Capped to keep the file reasonable.
function Fdr_SaveDebugDump ()

	if (not Fdr_ResearchDump_Enabled ()) then
		return;
	end

	local dump = {};
	dump.when	= time();
	dump.search	= gFdr_SearchText;
	dump.items	= {};

	local cap = 3000;

	local i;
	for i = 1, math.min (#gFdr_Results, cap) do

		local rec = gFdr_Results[i];

		local e = {};
		e.n		= rec.name;
		e.l		= rec.link;
		e.q		= rec.quality;
		e.il	= rec.ilvl;
		e.lv	= rec.level;
		e.c		= rec.count;
		e.b		= rec.buyoutPrice;

		if (rec.equippable) then
			e.eq = 1;
			local stats = Fdr_GetStats (rec);
			if (next (stats)) then
				e.s = {};
				for k, v in pairs (stats) do e.s[k] = v; end
			end
		end

		tinsert (dump.items, e);
	end

	-- HIJACKED (2026-07): the dump is now the research upload channel too.
	-- The raw rows are one scan; the targets are the whole accumulated ledger,
	-- ranked, so the uploaded file answers "what should I go buy" offline.
	dump.targets = {};
	local t = Fdr_Research_Targets (25);
	for i = 1, #t do
		local e = t[i];
		tinsert (dump.targets, { id = e.id, n = e.name, score = e.score,
								 cost = e.cost, costRq = e.costRq,
								 unmapped = e.unmapped, variants = e.variants,
								 down = e.down, rungs = e.rungs,
								 seen = e.seen, scans = e.scans, spread = e.spread,
								 want = Fdr_Research_Wants (e) });
	end

	AUCTIONATOR_FINDER_DEBUG = dump;
end

local function Fdr_NextSpecOrFinish ()

	if (gFdr_SpecIdx < #gFdr_SpecQueue) then

		gFdr_SpecIdx		= gFdr_SpecIdx + 1;
		gFdr_Page			= 0;
		gFdr_TotalPages		= 0;
		gFdr_DupRetries		= 0;

		if (Atr_NewQuery) then
			gFdr_Query = Atr_NewQuery();
		end

		gFdr_State			= FDR_PREQUERY;
		gFdr_QuerySentAt	= time();
	else
		Fdr_FinishSearch ();
	end
end

-- The page number alone is NOT enough of a heartbeat.  A scan can sit in
-- FDR_PREQUERY for a long time while CanSendAuctionQuery throttles us, and
-- the duplicate-page path retries without advancing either -- so the line
-- froze and a working scan was indistinguishable from a hung one.  The row
-- count and the seconds-waiting both move on their own.
local function Fdr_ScanProgressLabel ()

	local spec = gFdr_SpecQueue[gFdr_SpecIdx] or {};
	local what = (spec.label and spec.label ~= "") and spec.label or FT("auctions");

	if (gFdr_State == FDR_PAUSED) then
		-- nothing drives this state but a click, so never let it look like work
		return string.format (FT("%s: waiting for confirmation"), what);
	end

	local s = string.format (FT("Scanning %s: page %d"), what, gFdr_Page + 1)
				..((gFdr_TotalPages > 0) and (" / "..gFdr_TotalPages) or "");

	-- "listings", NOT "rows": the finish line already uses "rows after
	-- grouping" to mean GROUPED rows, and these are the raw pre-grouping
	-- records. Two different numbers deserve two different words.
	s = s..string.format ("  \194\183 %d "..FT("listings"), #gFdr_Results);

	if (gFdr_DupRetries > 0) then
		s = s..string.format ("  |cffffcc00"..FT("retry %d").."|r", gFdr_DupRetries);
	end

	-- a skipped page is 50 listings lost for good; do not hide that until the
	-- summary line at the very end
	if (gFdr_SkippedPages > 0) then
		s = s..string.format ("  |cffff6666"..FT("%d skipped").."|r", gFdr_SkippedPages);
	end

	-- Seconds are derived from the OnUpdate tick count rather than time():
	-- the label is rebuilt every frame, and an extra clock read per frame is
	-- pointless when the tick rate is already a fixed 0.25s.
	local waited = math.floor (gFdr_WaitTicks * 0.25);
	if (waited >= 1) then
		s = s..string.format ("  |cff888888(%ds)|r", waited);
	end

	if (#gFdr_SpecQueue > 1) then
		s = s.."  ("..gFdr_SpecIdx.."/"..#gFdr_SpecQueue..")";
	end

	return s;
end

local function Fdr_HarvestPage ()

	local numBatchAuctions, totalAuctions = GetNumAuctionItems ("list");

	if (gFdr_Page == 0) then
		gFdr_TotalPages = math.ceil ((totalAuctions or 0) / 50);

		local spec = gFdr_SpecQueue[gFdr_SpecIdx];
		if (spec and not spec.warned and gFdr_TotalPages > FDR_WARN_PAGES
				and not Fdr_IgnoreWarn() and Atr_Finder_WarnFrame) then
			spec.warned	= true;
			gFdr_State	= FDR_PAUSED;
			Atr_Finder_ShowLargeWarn (gFdr_TotalPages, totalAuctions or 0, spec.label);
			return;
		end
	end

	local x;
	for x = 1, numBatchAuctions do

		local name, texture, count, quality, canUse, level, minBid, minIncrement,
			  buyoutPrice, bidAmount, highBidder, owner = GetAuctionItemInfo ("list", x);

		if (name) then
			local rec = {};

			rec.name		= name;
			rec.texture		= texture;
			rec.count		= count or 1;
			rec.quality		= quality or 1;
			rec.level		= level or 0;
			rec.minBid		= minBid;
			rec.minIncrement = minIncrement;
			rec.bidAmount	= bidAmount;
			rec.buyoutPrice	= buyoutPrice;
			rec.owner		= owner;
			rec.link		= GetAuctionItemLink ("list", x);
			rec.timeLeft	= GetAuctionItemTimeLeft ("list", x);
			rec.page		= gFdr_Page;

			local spec		= gFdr_SpecQueue[gFdr_SpecIdx];
			rec.autoAccept	= spec and spec.autoAccept or false;

			tinsert (gFdr_Results, rec);
		end
	end

	if (numBatchAuctions < 50) then
		Fdr_NextSpecOrFinish ();
		return;
	end

	if (gFdr_Page + 1 >= Fdr_PageCeiling ()) then
		gFdr_CapHit = true;
		Fdr_NextSpecOrFinish ();
		return;
	end

	gFdr_Page			= gFdr_Page + 1;
	gFdr_State			= FDR_PREQUERY;
	gFdr_QuerySentAt	= time();
	gFdr_WaitTicks		= 0;					-- real progress: restart the heartbeat

	Fdr_SetMessage (Fdr_ScanProgressLabel ());
end

-------------------------------------------------------------------------------
-- Buy-tab mitigation: Auctionator's name-keyed tooltips can only show one
-- cached version of a scaled item, so append a warning whenever any tooltip
-- at the AH shows an item the Finder has seen with multiple scaled versions.
-------------------------------------------------------------------------------

if (hooksecurefunc and GameTooltip and GameTooltip.SetHyperlink) then

	hooksecurefunc (GameTooltip, "SetHyperlink", function (self, link)

		if (not AuctionFrame or not AuctionFrame:IsShown()) then return; end
		if (not link) then return; end

		-- our own rows already carry a richer warning
		local owner = self.GetOwner and self:GetOwner();
		local oname = owner and owner.GetName and owner:GetName();
		if (oname and oname:find ("^Atr_Finder_Row")) then return; end

		local name = link:match ("%[(.-)%]");
		if (not name and GetItemInfo) then name = GetItemInfo (link); end

		if (name and gFdr_ScaledNames and gFdr_ScaledNames[name]) then
			self:AddLine (" ");
			self:AddLine (FT("Scaled item: multiple versions of this item exist!"), 1, 0.55, 0.1);
			self:AddLine (FT("This tooltip may show a different version. The Finder tab and Browse show each listing's true required level."), 1, 0.8, 0.5, true);
			self:Show ();
		end
	end);
end

-------------------------------------------------------------------------------
-- event / update handlers
-------------------------------------------------------------------------------

local gFdr_EventFrame = CreateFrame ("Frame", "Atr_Finder_EventFrame", UIParent);

gFdr_EventFrame:RegisterEvent ("AUCTION_ITEM_LIST_UPDATE");
gFdr_EventFrame:RegisterEvent ("AUCTION_HOUSE_CLOSED");

gFdr_EventFrame:SetScript ("OnEvent", function (self, event, ...)

	if (event == "AUCTION_HOUSE_CLOSED") then
		Atr_Finder_CancelSearch (false);
		Atr_Finder_CancelBuy ();
		Atr_Finder_CancelGroup ();
		return;
	end

	if (gFdrBuy_State == FDRBUY_CONFIRM or gFdrBuy_State == FDRBUY_FINAL) then
		-- the loaded page shifted under us (server-side change); re-verify
		if (gFdrBuy_Rec and gFdrBuy_FoundIndex
				and not FdrBuy_Matches (gFdrBuy_FoundIndex, gFdrBuy_Rec)) then
			FdrBuy_Fail (FT("Listing changed - please try again"));
		end
		return;
	end

	if (gFdrBuy_State == FDRBUY_WAIT) then
		if (gFdrBuy_Query and gFdrBuy_Query.CheckForDuplicatePage
				and gFdrBuy_Query:CheckForDuplicatePage (gFdrBuy_Page)) then
			gFdrBuy_State	= FDRBUY_QUERY;
			gFdrBuy_SentAt	= time();
		else
			FdrBuy_ScanPage ();
		end
		return;
	end

	if (Atr_Finder_GroupIsFinding ()) then
		Atr_Finder_GroupOnListUpdate ();
		return;
	end

	if (gFdr_State ~= FDR_POSTQUERY) then
		return;
	end

	if (gFdr_Query and gFdr_Query.CheckForDuplicatePage) then

		if (gFdr_Query:CheckForDuplicatePage (gFdr_Page)) then

			gFdr_DupRetries = gFdr_DupRetries + 1;

			if (gFdr_DupRetries <= 4) then
				gFdr_State			= FDR_PREQUERY;
				gFdr_QuerySentAt	= time();

				-- BACK OFF between retries. A "duplicate" page is usually just
				-- the server not having delivered the new one yet, and retrying
				-- on the very next 0.25s tick burned all four attempts inside a
				-- SECOND -- then skipped the page and lost 50 listings for good.
				-- Doubling the wait (0.25 / 0.5 / 1 / 2s) gives a loaded server
				-- ~3.75s to catch up, which turns skips into successes. Costs
				-- nothing when pages arrive promptly: the hold is only ever set
				-- after a duplicate is actually seen.
				gFdr_RetryHold = 2 ^ (gFdr_DupRetries - 1);
			else
				gFdr_DupRetries		= 0;
				gFdr_RetryHold		= 0;
				gFdr_SkippedPages	= gFdr_SkippedPages + 1;
				gFdr_Page			= gFdr_Page + 1;

				if (gFdr_Page >= Fdr_PageCeiling ()) then
					gFdr_CapHit = true;
					Fdr_NextSpecOrFinish ();
				else
					gFdr_State			= FDR_PREQUERY;
					gFdr_QuerySentAt	= time();
				end
			end

			return;
		end
	end

	gFdr_DupRetries = 0;
	gFdr_RetryHold	= 0;					-- page arrived: drop any backoff

	Fdr_HarvestPage ();
end);

gFdr_EventFrame:SetScript ("OnUpdate", function (self, elapsed)

	if (Atr_Finder_GroupIsFinding ()) then
		gFdr_Elapsed = gFdr_Elapsed + elapsed;
		if (gFdr_Elapsed < 0.25) then return; end
		gFdr_Elapsed = 0;
		Atr_Finder_GroupOnUpdate ();
		return;
	end

	if (gFdrBuy_State ~= FDRBUY_IDLE) then
		gFdr_Elapsed = gFdr_Elapsed + elapsed;
		if (gFdr_Elapsed < 0.25) then return; end
		gFdr_Elapsed = 0;

		if (gFdrBuy_State == FDRBUY_QUERY) then
			if (CanSendAuctionQuery()) then
				FdrBuy_SendQuery ();
			elseif (time() - gFdrBuy_SentAt > 12) then
				FdrBuy_Fail (FT("Auction house timed out"));
			end
		elseif (gFdrBuy_State == FDRBUY_WAIT) then
			if (time() - gFdrBuy_SentAt > FDRBUY_TIMEOUT) then
				FdrBuy_Fail (FT("Auction house timed out"));
			end
		end
		-- FDRBUY_CONFIRM: no timeout; the user is deciding
		return;
	end

	if (gFdr_State == FDR_NULL) then
		return;
	end

	gFdr_Elapsed = gFdr_Elapsed + elapsed;
	if (gFdr_Elapsed < 0.25) then
		return;
	end
	gFdr_Elapsed = 0;

	-- FINDER_TAB: refresh the status EVERY tick while a scan is live. Waiting
	-- on the throttle is the longest part of a big sweep and used to show
	-- nothing at all.
	gFdr_WaitTicks = gFdr_WaitTicks + 1;
	Fdr_SetMessage (Fdr_ScanProgressLabel ());

	if (gFdr_State == FDR_PREQUERY) then

		if (gFdr_RetryHold > 0) then
			gFdr_RetryHold = gFdr_RetryHold - 1;		-- serving out the backoff
		elseif (CanSendAuctionQuery()) then
			Fdr_SendQuery ();
		elseif (time() - gFdr_QuerySentAt > 15) then
			Fdr_FinishSearch (FT("auction house timed out"));
		end

	elseif (gFdr_State == FDR_POSTQUERY) then

		if (time() - gFdr_QuerySentAt > FDR_QUERY_TIMEOUT) then
			Fdr_FinishSearch (FT("auction house timed out"));
		end
	end
end);

-------------------------------------------------------------------------------
-- results display
-------------------------------------------------------------------------------

function Atr_Finder_Redisplay ()

	local numResults = #gFdr_Display;

	FauxScrollFrame_Update (Atr_Finder_ScrollFrame, numResults, FDR_NUM_ROWS, FDR_ROW_HEIGHT);

	local offset = FauxScrollFrame_GetOffset (Atr_Finder_ScrollFrame);

	local i;
	for i = 1, FDR_NUM_ROWS do

		local row = gFdr_Rows[i];
		local idx = offset + i;

		if (idx <= numResults) then

			local rec = gFdr_Display[idx];

			row.rec = rec;

			row.icon:SetTexture (rec.texture);

			local r, g, b = GetItemQualityColor (rec.quality or 1);

			local nametext = rec.name;
			if (rec.numListings and rec.numListings > 1) then
				nametext = nametext.." |cffaaaaaa x"..rec.numListings.."|r";
			end
			row.cells.name:SetText (nametext);
			row.cells.name:SetTextColor (r, g, b);

			local ilvlShown = rec.trueIlvl or rec.ilvl;
			row.cells.ilvl:SetText ((rec.equippable and ilvlShown and ilvlShown > 0) and ilvlShown or "");
			local dim = (rec.scaled and not rec.trueIlvl) and 0.55 or 1;
			row.cells.ilvl:SetTextColor (dim, dim, dim);
			row.cells.level:SetText ((rec.level and rec.level > 1) and rec.level or "");
			if (rec.scaled) then
				row.cells.level:SetTextColor (1, 0.55, 0.1);
			else
				row.cells.level:SetTextColor (1, 1, 1);
			end
			row.cells.qty:SetText ((rec.count and rec.count > 1) and rec.count or "");
			row.cells.timeleft:SetText (gFdr_TimeLeftText[rec.timeLeft or 0] or "");

			if (gFdr_HasDPS) then
				local v = rec.trueDPS or Fdr_GetStat (rec, FDR_DPS_KEY);
				local vt = "";
				if (v and v ~= 0) then
					vt = (v % 1 == 0) and tostring (v) or string.format ("%.1f", v);
				end
				row.cells.dps:SetText (vt);
				local ddim = (rec.scaled and not rec.trueDPS) and 0.55 or 1;
				row.cells.dps:SetTextColor (ddim, ddim, ddim);
			end

			local si;
			for si = 1, Fdr_NumStatCols() do
				local skey = gFdr_SelectedStats[si];
				local v = Fdr_GetStat (rec, skey);
				local vtext = "";
				if (v and v ~= 0) then
					vtext = (v % 1 == 0) and tostring (v) or string.format ("%.1f", v);
				end
				row.cells["stat"..si]:SetText (vtext);

				-- per CELL, not per row: verifying a listing does not
				-- necessarily pin every stat (ratings are prose and are not
				-- parsed), and a cached number rendered at full brightness
				-- reads as confirmed when it is not
				local sdim = (rec.scaled and not (rec.trueStats and rec.trueStats[skey]))
					and 0.55 or 1;
				row.cells["stat"..si]:SetTextColor (sdim, sdim, sdim);
			end

			row.cells.buyout:SetText (Fdr_MoneyString (rec.buyoutPrice));

			if (rec.perItem and rec.perItem > 0 and rec.count and rec.count > 1) then
				row.cells.peritem:SetText (Fdr_MoneyString (rec.perItem));
			else
				row.cells.peritem:SetText ("");
			end

			row:Show();
		else
			row.rec = nil;
			row:Hide();
		end
	end

	if (Atr_Finder_UpdateVerifyButton) then Atr_Finder_UpdateVerifyButton (); end
end

-------------------------------------------------------------------------------
-- row interaction
-------------------------------------------------------------------------------

function Atr_Finder_RequestBuy (rec)

	if (not rec) then return; end

	if (gFdr_State ~= FDR_NULL) then
		Fdr_SetMessage (FT("Finish or cancel the scan first"));
		return;
	end

	if (not Atr_Finder_BuyFrame) then return; end

	Atr_Finder_CancelGroup ();

	gFdrBuy_Rec			= rec;
	gFdrBuy_FoundIndex	= nil;

	local r, g, b = GetItemQualityColor (rec.quality or 1);
	Atr_Finder_BuyFrame.itemname:SetText (rec.name);
	Atr_Finder_BuyFrame.itemname:SetTextColor (r, g, b);

	local details = string.format (FT("Requires level %d"), rec.level or 0);
	if (rec.count and rec.count > 1 and rec.numListings and rec.numListings > 1) then
		details = details.."  ·  "..string.format (FT("%d listings at this price"), rec.numListings);
	end
	if (rec.scaled) then
		details = details.."\n|cffff8800"..FT("Scaled item: matched by required level, so you get exactly this version.").."|r";
	end
	Atr_Finder_BuyFrame.details:SetText (details);
	Atr_Finder_BuyFrame.price:SetText ("");

	Atr_Finder_BuyFrame.buyBtn:SetText (FT("Finding..."));
	Atr_Finder_BuyFrame.buyBtn:Disable();
	if (Atr_Finder_BuyFrame.bidBtn) then Atr_Finder_BuyFrame.bidBtn:Disable(); end

	FdrBuy_HidePreview ();
	Atr_Finder_BuyFrame:SetHeight (150);
	Atr_Finder_BuyFrame:Show();

	-- start the find immediately: the row click IS the first click
	Atr_Finder_ExecuteBuy ();
end

-- ---------------------------------------------------------------------------
-- FINDER_TAB: non-gear rows hand off to the Buy tab
--
-- Everything this tab adds -- the ilvl/DPS/stat columns, the group listings
-- window, the instance-exact buy engine -- exists because Ascension scales
-- EQUIPMENT per instance and the item link says nothing about it (see
-- ASCENSION-CLIENT-NOTES).  A stack of Saronite Bars has none of that
-- problem: what matters there is the per-unit price across every stack on
-- the AH, which is precisely what the Buy tab shows.  So a click on a
-- non-gear row goes there instead of opening a dialog built for scaled gear.
--
-- Both functions are globals, per the namespace rule in
-- FINDER-ARCHITECTURE.md: this is click-time code, not the per-record path,
-- and being global makes the routing decision drivable from a harness.
-- ---------------------------------------------------------------------------

-- THE routing predicate, shared by both directions: this tab sends non-gear
-- to the Buy tab, and the Buy tab sends gear back here.  If those two ever
-- disagreed about one item the user would be bounced between the tabs, so
-- there is deliberately only one function that decides.
--
-- Decided by item CLASS, not by IsEquippableItem: bags, quivers and ammo are
-- all equippable and are all commodities.  sType is GetItemInfo's localized
-- class string and GetAuctionItemClasses returns those same strings -- the
-- comparison Fdr_PassesCategoryFilter already relies on.
--
-- Returns true / false / **nil**, and nil is load-bearing: it means "no class
-- to test", which is not the same as "not gear".  Each caller resolves it
-- toward leaving the user where they already are.
function Fdr_IsGearClassName (sType)

	if (sType == nil or GetAuctionItemClasses == nil) then return nil; end

	-- Weapon is class 1 and Armor class 2 (stable in 3.3.5; the same
	-- assumption FDR_ARMOR_CLASS and FS_WEAPON_CLASS already make).
	-- Assigning to two locals truncates the multi-return, so this costs
	-- no table allocation in what is a mouse-over hot path.
	local weapon, armor = GetAuctionItemClasses();

	-- An empty return means the AH has not finished opening.  Nothing is
	-- cached, so the next call simply asks again (the trap Fdr_InvTypeMap
	-- documents).
	if (not weapon and not armor) then return nil; end

	return (sType == weapon or sType == armor);
end


-- True for Weapon and Armor rows; only those keep the Finder's own dialog.
function Fdr_IsGearRec (rec)

	if (rec == nil) then return false; end

	local gear = Fdr_IsGearClassName (rec.itemType);
	if (gear ~= nil) then return gear; end

	-- GetItemInfo returns nil for an item this client has never cached, which
	-- on this realm is most custom IDs (see ASCENSION-CLIENT-NOTES).  With no
	-- class to test, fall back to the equippable flag and keep the existing
	-- dialog: a wrong handoff throws the user's results away, whereas a wrong
	-- dialog still buys the item.
	return rec.equippable and true or false;
end

-- Hands a row to Auctionator's Buy tab.  Mirrors Atr_Bz_JumpToBuy: select the
-- pane FIRST (the search box belongs to the shared main panel and is hidden
-- until the Buy tab is up), then QUOTE the name so Auctionator matches it
-- exactly rather than as a substring -- unquoted, "Copper Bar" also drags in
-- every longer name that contains it.
--
-- Returns false when there is no Buy tab to hand to, so the caller can fall
-- back to the Finder's own dialog instead of swallowing the click.
function Atr_Finder_JumpToBuy (rec)

	if (rec == nil or rec.name == nil or rec.name == "") then return false; end

	if (Atr_SelectPane == nil or Atr_Search_Box == nil or Atr_Search_Onclick == nil) then
		return false;
	end

	-- leaving the tab cancels both anyway (Atr_Finder_OnTabClick); doing it
	-- first means no half-open dialog can outlive the jump
	Atr_Finder_CancelBuy ();
	Atr_Finder_CancelGroup ();

	-- raise the flag BEFORE switching: Atr_SelectPane runs
	-- Atr_AuctionFrameTab_OnClick synchronously, and the post-hook that shows
	-- "Back to Finder" reads this on the way through
	gFdr_JumpPending = true;

	Atr_SelectPane (ATR_BUY_TAB or 3);

	Atr_Search_Box:SetText ('"'..rec.name..'"');
	Atr_Search_Onclick ();

	return true;
end

-- ---------------------------------------------------------------------------
-- FINDER_TAB begin: gear on the Buy tab comes back here
--
-- The mirror image of the block above, and it exists for the reason stated in
-- AUCTIONATOR-INTERNALS: the Buy tab condenses a scan by item NAME and keeps
-- essentially one item link per name, so on a server that scales item
-- INSTANCES invisibly to the link (ASCENSION-CLIENT-NOTES, "THE BIG ONE") its
-- icon and tooltip show one cached version standing in for every variant, and
-- a purchase can deliver a different item than the one displayed.  For gear
-- that is not a cosmetic problem, it is the wrong item.  This tab exists
-- because of it.
--
-- So: pick a weapon or a piece of armor on the Buy tab and you land here
-- instead, with that name searched.  Three entry points, because there are
-- three ways to arrive at one item:
--   1. Atr_Search_Onclick     - typed or pasted name, intercepted BEFORE the
--                               query goes out, so nothing is scanned twice
--   2. Atr_OnSearchComplete   - the same, for a name GetItemInfo had never
--                               cached (most custom IDs here): the class is
--                               only knowable once the auction rows arrive
--   3. Atr_EntryOnClick       - a row picked out of a multi-item result, i.e.
--                               the Advanced Search drill-down
--
-- All three WRAP the upstream global rather than hooking it: 1 and 3 need to
-- act BEFORE the original runs, and hooksecurefunc cannot do that.  The toc
-- loads this file after Auctionator.lua / AuctionatorShop.lua, so the later
-- definition wins and no upstream file is edited -- the same mechanism the
-- full scan replacement below uses.
--
-- FOUR THINGS THIS MUST NOT DO, each of which it would do unguarded:
--   1. Steal the BAZAAR's hand-off.  Atr_Bz_JumpToBuy sends items to the Buy
--      tab to be bought, and 53 heirlooms plus Tiraxis's gold weapon stock
--      are class Weapon/Armor.  Suppressed while the Bazaar's own Back
--      button is up, which is exactly the window its jump is outstanding.
--   2. Fire on the SELL tab.  Atr_OnSearchComplete runs for whichever pane is
--      current, and the Sell tab prices a stack you are about to post with
--      its own exact search.  Every entry point is gated on the Buy tab
--      actually being the selected one.
--   3. Trap the user.  The Buy tab still has price history, the mean-price
--      database and the shopping lists, and stock unscaled gear displays
--      there perfectly well.  Searching the same name a second time is let
--      through, so the tab is always one repeat away.
--   4. Guess.  Fdr_IsGearClassName returns nil when there is no class to
--      test; only an explicit true redirects.  Both directions resolve the
--      unknown case the same way -- leave the user where they are.
-- ---------------------------------------------------------------------------

-- default ON: this is the behaviour the tab was asked for
function Fdr_BuyRedirect_Enabled ()

	if (AUCTIONATOR_FINDER_SETTINGS == nil) then return true; end
	return (AUCTIONATOR_FINDER_SETTINGS.gearToFinder ~= false);
end


-- GetItemInfo's localized class string for a name, or nil when the client has
-- never cached it.  Atr_GetItemLink is Auctionator's own name -> link cache,
-- which is already warm for anything looked up this session.
function Fdr_BuyRedirect_ClassOf (name, link)

	if (GetItemInfo == nil) then return nil; end

	if (link == nil and Atr_GetItemLink) then
		link = Atr_GetItemLink (name);
	end

	local _, _, _, _, _, sType = GetItemInfo (link or name);
	return sType;
end


-- Strips the quotes Auctionator uses for an exact match and rejects anything
-- that is not a plain single-item name.  A compound search ("Armor/Leather")
-- is a browse, not an item, and is left alone -- the user picks a row from it
-- and entry point 3 takes over there.
function Fdr_BuyRedirect_PlainName (text)

	if (type (text) ~= "string") then return nil; end

	text = text:gsub ("^%s+", ""):gsub ("%s+$", "");
	if (text == "") then return nil; end

	if (Atr_IsCompoundSearch and Atr_IsCompoundSearch (text)) then return nil; end

	local inner = text:match ('^"(.*)"$');
	if (inner) then text = inner; end

	if (text == "") then return nil; end
	return text;
end


-- Sends the Finder to a name handed over by the Buy tab.
--
-- ClearFilters first, and deliberately the whole thing: a category selection
-- left over from an earlier sweep would constrain the query, and the gear
-- autofills (min level = charLevel-5, Usable, My Lvl) would filter out the
-- very item we were sent here to display -- a level 70 weapon on a level 30
-- character would arrive to an empty list.  It resets the My Lvl setting as a
-- side effect, which is the lesser surprise: the alternative is landing on
-- zero rows for the item you just asked to see.
--
-- Returns false when the Finder cannot take it, so the caller leaves the Buy
-- tab to get on with the search it was already doing.
function Atr_Finder_JumpFromBuy (name)

	if (name == nil or name == "") then return false; end

	if (Atr_SelectPane == nil or Atr_Finder_Panel == nil) then return false; end
	if (Atr_Finder_SearchBox == nil or Atr_Finder_StartSearch == nil) then return false; end

	-- a scan cannot be running (leaving this tab cancels it) but the guard is
	-- free, and Atr_Finder_StartSearch CANCELS rather than starts when busy --
	-- it would silently throw the scan away and search nothing
	if (gFdr_State ~= FDR_NULL) then return false; end

	Atr_SelectPane (ATR_FINDER_TAB or 4);

	if (Atr_Finder_ClearFilters) then Atr_Finder_ClearFilters (); end

	Atr_Finder_SearchBox:SetText (name);
	Atr_Finder_StartSearch ();

	return true;
end


-- The decision, shared by all three entry points.
-- Returns true when the redirect happened and the caller must not continue.
function Fdr_BuyRedirect_Consider (name, link)

	if (not Fdr_BuyRedirect_Enabled ()) then return false; end
	if (name == nil or name == "") then return false; end

	-- guard 2: the Buy tab, and only the Buy tab
	if (Atr_IsTabSelected == nil) then return false; end
	if (not Atr_IsTabSelected (ATR_BUY_TAB or 3)) then return false; end

	-- guard 1: the Bazaar sent this here to be bought
	if (Atr_Bz_BuyBackButton and Atr_Bz_BuyBackButton:IsShown()) then return false; end

	-- guard 3: we already made this point about this item
	local key = string.lower (name);
	if (gFdr_Redir.skip == key) then return false; end

	-- guard 4: nil is not false
	if (Fdr_IsGearClassName (Fdr_BuyRedirect_ClassOf (name, link)) ~= true) then
		return false;
	end

	if (not Atr_Finder_JumpFromBuy (name)) then return false; end

	gFdr_Redir.skip = key;

	-- The status line cannot carry this: Atr_Finder_StartSearch overwrites it
	-- with "Scanning..." and the progress heartbeat rebuilds it every tick.
	-- Chat is the only channel that survives, and a tab change the user did
	-- not ask for has to explain itself.
	local s = string.format (FT("Finder: showing |cffffd200%s|r here - the Buy tab shows one cached version of every scaled variant."), name);

	if (not gFdr_Redir.told) then
		gFdr_Redir.told = true;
		s = s.."  "..FT("Search it again to stay on the Buy tab, or turn this off in Auctionator options > Scanning.");
	end

	if (zc and zc.msg_atr) then zc.msg_atr (s);
	elseif (DEFAULT_CHAT_FRAME) then DEFAULT_CHAT_FRAME:AddMessage (s); end

	return true;
end


-- entry point 1: before the query.  The cheap path -- for a name the client
-- has cached, no page is ever fetched by the Buy tab at all.
gFdr_Redir.prevSearch = Atr_Search_Onclick;

function Atr_Search_Onclick (...)

	local box = (Atr_Search_Box and Atr_Search_Box.GetText) and Atr_Search_Box:GetText() or nil;
	local nm  = Fdr_BuyRedirect_PlainName (box);

	if (nm and Fdr_BuyRedirect_Consider (nm)) then return; end

	if (gFdr_Redir.prevSearch) then return gFdr_Redir.prevSearch (...); end
end


-- entry point 2: after the query, for names entry point 1 could not classify.
-- NumScans() == 1 is upstream's own test for "the search settled on one item",
-- and it is the same condition under which Atr_OnSearchComplete assigns
-- activeScan -- whose itemLink came from a real auction row, so the class is
-- known even for an item this client had never seen.
function Fdr_BuyRedirect_AfterSearch ()

	local pane = Atr_GetCurrentPane and Atr_GetCurrentPane ();
	if (pane == nil or pane.activeSearch == nil or pane.activeScan == nil) then return; end
	if (pane.activeSearch.NumScans == nil) then return; end
	if (pane.activeSearch:NumScans() ~= 1) then return; end

	if (pane.activeScan.itemName == nil) then return; end

	Fdr_BuyRedirect_Consider (pane.activeScan.itemName, pane.activeScan.itemLink);
end

gFdr_Redir.prevComplete = Atr_OnSearchComplete;

function Atr_OnSearchComplete (...)

	if (gFdr_Redir.prevComplete) then gFdr_Redir.prevComplete (...); end
	Fdr_BuyRedirect_AfterSearch ();
end


-- entry point 3: a row picked out of a multi-item result.
--
-- Atr_ShowingSearchSummary must be read BEFORE the original runs.  It is
-- derived from gCurrentPane:IsScanEmpty(), and the original's whole job in
-- that branch is to assign a non-empty activeScan -- so by the time a
-- post-hook could look, the answer has already flipped to false.  This is why
-- the function is wrapped rather than hooked.
gFdr_Redir.prevEntry = Atr_EntryOnClick;

function Atr_EntryOnClick (entry, ...)

	local fromSummary = (Atr_ShowingSearchSummary and Atr_ShowingSearchSummary()) and true or false;

	if (gFdr_Redir.prevEntry) then gFdr_Redir.prevEntry (entry, ...); end

	if (fromSummary) then
		local pane = Atr_GetCurrentPane and Atr_GetCurrentPane ();
		local scn  = pane and pane.activeScan;
		if (scn and scn.itemName) then
			Fdr_BuyRedirect_Consider (scn.itemName, scn.itemLink);
		end
	end
end
-- FINDER_TAB end: gear on the Buy tab comes back here

local function Fdr_Row_OnEnter (self)

	if (self.rec and self.rec.link) then

		-- with Dress active the dressing room sits to the right, so park the
		-- tooltip mid-panel instead of covering the preview
		if (AUCTIONATOR_FINDER_SETTINGS and AUCTIONATOR_FINDER_SETTINGS.dressHover
				and Atr_Finder_Panel) then
			GameTooltip:SetOwner (self, "ANCHOR_NONE");
			GameTooltip:ClearAllPoints ();
			GameTooltip:SetPoint ("TOPLEFT", Atr_Finder_Panel, "TOP", -70, -110);
		else
			GameTooltip:SetOwner (self, "ANCHOR_RIGHT");
		end

		-- C: tell the hints module which instance this row really is, so its
		-- vendor lookup is keyed on this listing rather than on whichever
		-- variant the client cached.  Set for exactly one SetHyperlink call
		-- and cleared the instant it returns: every other tooltip in the
		-- game, including the Compare tooltips raised below, must keep
		-- reading their own values.
		Atr_Finder_TipItemLines = nil;
		Atr_Finder_TipOverride  = self.rec.scaled
			and { il = self.rec.trueIlvl, rq = self.rec.level } or nil;

		GameTooltip:SetHyperlink (self.rec.link);

		Atr_Finder_TipOverride = nil;

		-- A: replay the server's own text for this exact listing over the
		-- cached body.  Silently does nothing when the row was never verified
		-- (no trueLines) or when the hints module is absent (no boundary),
		-- which leaves the previous behaviour plus the warning below.
		if (self.rec.trueLines) then
			Fdr_ApplyTrueLines (GameTooltip, self.rec.trueLines, Atr_Finder_TipItemLines);
		end
		Atr_Finder_TipItemLines = nil;

		if (self.rec.numListings and self.rec.numListings > 1) then
			GameTooltip:AddLine (string.format (FT("%d listings, %d total"), self.rec.numListings, self.rec.count or 0), 0.8, 0.8, 0.8);
		elseif (self.rec.owner) then
			GameTooltip:AddLine (FT("Seller")..": "..self.rec.owner, 0.8, 0.8, 0.8);
		end
		if (self.rec.scaled) then
			GameTooltip:AddLine (" ");
			GameTooltip:AddLine (FT("Scaled item!"), 1, 0.55, 0.1);
			GameTooltip:AddLine (string.format (FT("This listing actually requires level %d; the dimmed stats above may show a different version."), self.rec.level or 0), 1, 0.8, 0.5, true);
		end
		-- the click must not be a surprise: say where it goes
		if (not Fdr_IsGearRec (self.rec)) then
			GameTooltip:AddLine (FT("Click to open this item on the Buy tab"), 0.5, 0.7, 1.0);
		elseif (self.rec.members and (self.rec.numListings or 1) > 1) then
			GameTooltip:AddLine (FT("Click to view each listing"), 0.5, 0.7, 1.0);
		else
			GameTooltip:AddLine (FT("Click to buy this exact listing"), 0.5, 0.7, 1.0);
		end
		GameTooltip:AddLine (FT("Shift: link   Ctrl: dressing room"), 0.6, 0.6, 0.6);
		GameTooltip:Show();

		if (AUCTIONATOR_FINDER_SETTINGS and AUCTIONATOR_FINDER_SETTINGS.autoCompare
				and self.rec.equippable and GameTooltip_ShowCompareItem) then
			GameTooltip_ShowCompareItem (GameTooltip);
		end

		if (AUCTIONATOR_FINDER_SETTINGS and AUCTIONATOR_FINDER_SETTINGS.dressHover
				and self.rec.equippable and self.rec.link and DressUpItemLink) then
			DressUpItemLink (self.rec.link);
		end
	end
end

local function Fdr_Row_OnLeave ()

	GameTooltip:Hide();
	if (ShoppingTooltip1) then ShoppingTooltip1:Hide(); end
	if (ShoppingTooltip2) then ShoppingTooltip2:Hide(); end
end

local function Fdr_Row_OnClick (self, button)

	if (not self.rec) then
		return;
	end

	if (IsShiftKeyDown() and self.rec.link) then
		ChatEdit_InsertLink (self.rec.link);
		return;
	end

	if (IsControlKeyDown() and self.rec.link) then
		DressUpItemLink (self.rec.link);
		return;
	end

	-- Non-gear goes to the Buy tab.  Tested BEFORE the group-face branch on
	-- purpose: for a commodity the group window would only re-split the very
	-- stacks that the Buy tab already condenses into one per-unit view.
	if (not Fdr_IsGearRec (self.rec)) then

		-- a tab change cancels the scan, so an accidental click must not throw
		-- minutes of paging away; refuse it the way Atr_Finder_RequestBuy does
		if (gFdr_State ~= FDR_NULL) then
			Fdr_SetMessage (FT("Finish or cancel the scan first"));
			return;
		end

		if (Atr_Finder_JumpToBuy (self.rec)) then
			return;
		end
		-- no Buy tab to hand to: fall through to the Finder's own dialog
	end

	-- a multi-listing group face carries the group TOTAL as its count, so it
	-- is not a real listing's identity tuple and can never be found by the
	-- buy engine; open the group window with each real listing instead
	if (self.rec.members and (self.rec.numListings or 1) > 1) then
		Atr_Finder_ShowGroup (self.rec);
		return;
	end

	-- plain click: buy this exact listing (matched by name+stack+price+level)
	Atr_Finder_RequestBuy (self.rec);
end

-- clears every filter: categories, stats, level range, usable
function Atr_Finder_ClearFilters ()

	gFdr_SelectedStats	= {};
	gFdr_SelectedSet	= {};

	if (gFdr_SortKey:match ("^stat%d$")) then
		gFdr_SortKey = "peritem";
		gFdr_SortAsc = true;
	end

	if (Atr_Finder_SearchBox) then
		Atr_Finder_SearchBox:SetText ("");
		Atr_Finder_SearchBox:ClearFocus ();
	end
	if (Atr_Finder_MinLevel)	then Atr_Finder_MinLevel:SetText ("");	end
	if (Atr_Finder_MaxLevel)	then Atr_Finder_MaxLevel:SetText ("");	end
	if (Atr_Finder_UsableCheck)	then Atr_Finder_UsableCheck:SetChecked (nil); end
	if (Atr_Finder_ReqCheck) then
		Atr_Finder_ReqCheck:SetChecked (nil);
		if (AUCTIONATOR_FINDER_SETTINGS) then AUCTIONATOR_FINDER_SETTINGS.reqOnly = false; end
	end

	if (Fdr_StatDD_SetTextFwd) then Fdr_StatDD_SetTextFwd (); end
	Fdr_ApplyColumnLayout ();
	Fdr_UpdateHeaderArrows ();

	Atr_Finder_ToggleCategory (nil);	-- also rebuilds + redisplays + updates button
end

-------------------------------------------------------------------------------
-- category menu (Blizzard-style class/subclass tree with checkboxes)
-------------------------------------------------------------------------------

-- armor slots offered under the Armor submenu; each entry: accepted equipLoc
-- tokens (first token's global provides the localized label)
local FDR_ARMOR_SLOTS =
{
	{ "INVTYPE_HEAD" },
	{ "INVTYPE_NECK" },
	{ "INVTYPE_SHOULDER" },
	{ "INVTYPE_CLOAK" },
	{ "INVTYPE_CHEST", "INVTYPE_ROBE" },
	{ "INVTYPE_WRIST" },
	{ "INVTYPE_HAND" },
	{ "INVTYPE_WAIST" },
	{ "INVTYPE_LEGS" },
	{ "INVTYPE_FEET" },
	{ "INVTYPE_FINGER" },
	{ "INVTYPE_TRINKET" },
	{ "INVTYPE_HOLDABLE" },
};

local FDR_WEAPON_CLASS = 1;

local function Fdr_SelectionHasGear ()

	for _, leaf in ipairs (gFdr_SelectedCats) do
		if (leaf.ci == FDR_WEAPON_CLASS or leaf.ci == FDR_ARMOR_CLASS) then
			return true;
		end
	end
	return false;
end

-- When gear categories are selected: auto-fill min level (character level - 5)
-- and auto-check Usable, both server-side scan reducers. Only touches values
-- we set ourselves; manual edits and manual unchecks are respected.
local function Fdr_AutoFillMinLevel ()

	if (not Atr_Finder_MinLevel or not UnitLevel) then return; end

	local cur = Atr_Finder_MinLevel:GetText() or "";

	local hasGear = Fdr_SelectionHasGear ();

	-- Usable checkbox
	if (Atr_Finder_UsableCheck) then
		if (hasGear) then
			if (not Atr_Finder_UsableCheck:GetChecked()) then
				if (gFdr_AutoUsable) then
					gFdr_AutoUsable		= false;	-- user unchecked our auto-check
					gFdr_UsableUserOff	= true;
				elseif (not gFdr_UsableUserOff) then
					Atr_Finder_UsableCheck:SetChecked (true);
					gFdr_AutoUsable = true;
				end
			end
		else
			if (gFdr_AutoUsable and Atr_Finder_UsableCheck:GetChecked()) then
				Atr_Finder_UsableCheck:SetChecked (nil);
			end
			gFdr_AutoUsable		= false;
			gFdr_UsableUserOff	= false;
		end
	end

	-- My Lvl checkbox: same auto/override etiquette as Usable
	if (Atr_Finder_ReqCheck) then
		if (hasGear) then
			if (not Atr_Finder_ReqCheck:GetChecked()) then
				if (gFdr_AutoReq) then
					gFdr_AutoReq	= false;
					gFdr_ReqUserOff	= true;
				elseif (not gFdr_ReqUserOff) then
					Atr_Finder_ReqCheck:SetChecked (true);
					if (AUCTIONATOR_FINDER_SETTINGS) then AUCTIONATOR_FINDER_SETTINGS.reqOnly = true; end
					gFdr_AutoReq = true;
				end
			end
		else
			if (gFdr_AutoReq and Atr_Finder_ReqCheck:GetChecked()) then
				Atr_Finder_ReqCheck:SetChecked (nil);
				if (AUCTIONATOR_FINDER_SETTINGS) then AUCTIONATOR_FINDER_SETTINGS.reqOnly = false; end
			end
			gFdr_AutoReq	= false;
			gFdr_ReqUserOff	= false;
		end
	end

	if (hasGear) then
		if (cur == "" or (gFdr_AutoMinLvl and tonumber (cur) == gFdr_AutoMinLvl)) then
			local ul = UnitLevel ("player") or 0;
			if (ul > 1) then
				local lvl = ul - 5;
				if (lvl < 1) then lvl = 1; end
				Atr_Finder_MinLevel:SetText (lvl);
				gFdr_AutoMinLvl = lvl;
			end
		end
	else
		if (gFdr_AutoMinLvl and tonumber (cur) == gFdr_AutoMinLvl) then
			Atr_Finder_MinLevel:SetText ("");
		end
		gFdr_AutoMinLvl = nil;
	end
end

local function Fdr_UpdateCatButton ()

	if (not Atr_Finder_CatButton) then return; end

	local n = #gFdr_SelectedCats;
	if (n > 0) then
		Atr_Finder_CatButton:SetText (FT("Categories").." ("..n..")");
	else
		Atr_Finder_CatButton:SetText (FT("Categories"));
	end
end

-- global for testability; leaf = { kind="class"/"subclass"/"slot", ci, si,
-- className, label, tokens }.  key nil = clear all.
function Atr_Finder_ToggleCategory (key, leaf)

	if (key == nil) then
		gFdr_SelectedCats	= {};
		gFdr_SelectedCatSet	= {};
	elseif (gFdr_SelectedCatSet[key]) then
		gFdr_SelectedCatSet[key] = nil;
		local i;
		for i = #gFdr_SelectedCats, 1, -1 do
			if (gFdr_SelectedCats[i].key == key) then
				table.remove (gFdr_SelectedCats, i);
			end
		end
	else
		leaf.key = key;
		gFdr_SelectedCatSet[key] = true;
		tinsert (gFdr_SelectedCats, leaf);
	end

	Fdr_UpdateCatButton ();
	Fdr_AutoFillMinLevel ();

	-- re-filter what's on screen now; a fresh Search picks up the new scan scope
	Atr_Finder_RebuildDisplay ();
	Fdr_SortAndRedisplay ();

	if (#gFdr_Results > 0 and gFdr_State == FDR_NULL) then
		Fdr_SetMessage (string.format (FT("%d rows shown"), #gFdr_Display).."  |cff88ccff"..FT("(press Search to rescan with new categories)").."|r");
	end
end

local function Fdr_CatMenu_AddLeaf (key, label, leaf, level)

	local info = UIDropDownMenu_CreateInfo and UIDropDownMenu_CreateInfo() or {};
	info.text				= label;
	info.checked			= (gFdr_SelectedCatSet[key] == true);
	info.keepShownOnClick	= 1;
	info.func				= function() Atr_Finder_ToggleCategory (key, leaf); end;
	UIDropDownMenu_AddButton (info, level);
end

local function Fdr_CatMenu_Init (self, level)

	level = level or 1;

	if (not GetAuctionItemClasses) then return; end

	if (level == 1) then

		local info = UIDropDownMenu_CreateInfo and UIDropDownMenu_CreateInfo() or {};
		info.text			= FT("(clear all)");
		info.notCheckable	= true;
		info.func			= function() Atr_Finder_ToggleCategory (nil); CloseDropDownMenus(); end;
		UIDropDownMenu_AddButton (info, level);

		local classes = { GetAuctionItemClasses() };
		local ci;
		for ci = 1, #classes do
			info = UIDropDownMenu_CreateInfo and UIDropDownMenu_CreateInfo() or {};
			info.text			= classes[ci];
			info.hasArrow		= true;
			info.notCheckable	= true;
			info.value			= ci;
			info.keepShownOnClick = 1;
			UIDropDownMenu_AddButton (info, level);
		end

	elseif (level == 2) then

		local ci		= UIDROPDOWNMENU_MENU_VALUE;
		local classes	= { GetAuctionItemClasses() };
		local className	= classes[ci] or ("class "..tostring (ci));

		Fdr_CatMenu_AddLeaf ("c"..ci, FT("All").." "..className,
			{ kind = "class", ci = ci, className = className, label = className }, level);

		local subs = GetAuctionItemSubClasses and { GetAuctionItemSubClasses (ci) } or {};
		local si;
		for si = 1, #subs do
			Fdr_CatMenu_AddLeaf ("c"..ci.."s"..si, subs[si],
				{ kind = "subclass", ci = ci, si = si, className = className, label = subs[si] }, level);
		end

		if (ci == FDR_ARMOR_CLASS) then

			local info = UIDropDownMenu_CreateInfo and UIDropDownMenu_CreateInfo() or {};
			info.text			= FT("Slots");
			info.isTitle		= true;
			info.notCheckable	= true;
			UIDropDownMenu_AddButton (info, level);

			local k;
			for k = 1, #FDR_ARMOR_SLOTS do
				local tokens = FDR_ARMOR_SLOTS[k];
				local tokenSet = {};
				local t;
				for t = 1, #tokens do tokenSet[tokens[t]] = true; end

				local label = _G[tokens[1]] or tokens[1];

				Fdr_CatMenu_AddLeaf ("slot:"..tokens[1], label,
					{ kind = "slot", ci = FDR_ARMOR_CLASS, tokens = tokenSet, label = label }, level);
			end
		end
	end
end

-------------------------------------------------------------------------------
-- stat dropdown
-------------------------------------------------------------------------------

local function Fdr_StatDD_SetText ()

	if (not Atr_Finder_StatDD or not UIDropDownMenu_SetText) then return; end

	local n = #gFdr_SelectedStats;

	if (n == 0) then
		UIDropDownMenu_SetText (Atr_Finder_StatDD, FT("Stats..."));
	elseif (n == 1) then
		UIDropDownMenu_SetText (Atr_Finder_StatDD, Fdr_StatDisplayName (gFdr_SelectedStats[1]));
	else
		UIDropDownMenu_SetText (Atr_Finder_StatDD, string.format (FT("Stats (%d)"), n));
	end
end

Fdr_StatDD_SetTextFwd = Fdr_StatDD_SetText;

local function Fdr_AfterStatChange ()

	-- if the current sort points at a stat column that no longer exists, reset
	local statIdx = gFdr_SortKey:match ("^stat(%d)$");
	if (statIdx and tonumber (statIdx) > Fdr_NumStatCols()) then
		gFdr_SortKey = "peritem";
		gFdr_SortAsc = true;
	end

	Fdr_StatDD_SetText ();
	Fdr_ApplyColumnLayout ();
	Fdr_UpdateHeaderArrows ();
	Atr_Finder_RebuildDisplay ();
	Fdr_SortAndRedisplay ();
end

-- global so it's testable and macro-able; toggles a stat in/out of the filter
function Atr_Finder_ToggleStat (key)

	if (key == nil) then					-- clear all
		gFdr_SelectedStats	= {};
		gFdr_SelectedSet	= {};
	elseif (gFdr_SelectedSet[key]) then
		gFdr_SelectedSet[key] = nil;
		local i;
		for i = #gFdr_SelectedStats, 1, -1 do
			if (gFdr_SelectedStats[i] == key) then
				table.remove (gFdr_SelectedStats, i);
			end
		end
	else
		gFdr_SelectedSet[key] = true;
		tinsert (gFdr_SelectedStats, key);
	end

	Fdr_AfterStatChange ();
end

local function Fdr_StatDD_Initialize ()

	local info;

	info = UIDropDownMenu_CreateInfo and UIDropDownMenu_CreateInfo() or {};
	info.text			= FT("(clear all)");
	info.func			= function() Atr_Finder_ToggleStat (nil); CloseDropDownMenus(); end;
	info.notCheckable	= true;
	UIDropDownMenu_AddButton (info);

	local i;
	for i = 1, #gFdr_StatKeys do
		local key = gFdr_StatKeys[i];

		info = UIDropDownMenu_CreateInfo and UIDropDownMenu_CreateInfo() or {};
		info.text				= Fdr_StatDisplayName (key);
		info.func				= function() Atr_Finder_ToggleStat (key); end;
		info.checked			= (gFdr_SelectedSet[key] == true);
		info.keepShownOnClick	= 1;
		UIDropDownMenu_AddButton (info);
	end
end

-------------------------------------------------------------------------------
-- UI construction
-------------------------------------------------------------------------------

local function Fdr_MakeHeader (parent, key, text, width, xoff)

	local btn = CreateFrame ("Button", "Atr_Finder_Head_"..key, parent);
	btn:SetSize (width, 19);
	btn:SetPoint ("TOPLEFT", xoff, -74);

	local label = btn:CreateFontString (nil, "ARTWORK", "GameFontNormalSmall");
	label:SetPoint ("LEFT", 2, 0);
	label:SetText (text);
	btn.label = label;

	local arrow = btn:CreateFontString (nil, "ARTWORK", "GameFontNormalSmall");
	arrow:SetPoint ("LEFT", label, "RIGHT", 3, 0);
	btn.arrow = arrow;

	local tex = btn:CreateTexture (nil, "BACKGROUND");
	tex:SetAllPoints ();
	tex:SetTexture (1, 1, 1, 0.06);

	btn:SetScript ("OnClick",	function() Fdr_HeaderClick (key); end);
	btn:SetScript ("OnEnter",	function(self) tex:SetTexture (1, 1, 1, 0.15); end);
	btn:SetScript ("OnLeave",	function(self) tex:SetTexture (1, 1, 1, 0.06); end);

	gFdr_Headers[key] = btn;

	return btn;
end

function Atr_Finder_Init ()

	if (Atr_Finder_Panel) then
		return;
	end

	local panel = CreateFrame ("Frame", "Atr_Finder_Panel", AuctionFrame);
	panel:SetSize (738, 447);
	panel:SetPoint ("TOPLEFT", 10, 0);
	panel:Hide();

	-- backdrop over the sidebar art; right edge pinned to the real frame edge
	local bg = panel:CreateTexture ("Atr_Finder_ResultsBG", "BACKGROUND");
	bg:SetTexture (0, 0, 0, 0.85);
	bg:SetPoint ("TOPLEFT", 14, -70);
	bg:SetPoint ("BOTTOMRIGHT", AuctionFrame, "BOTTOMRIGHT", -12, 28);

	local title = panel:CreateFontString ("Atr_Finder_Title", "BACKGROUND", "GameFontNormal");
	title:SetPoint ("TOP", -10, -18);
	title:SetText ("Auctionator - "..FT("Finder"));

	-- search controls ------------------------------------------------------

	local nameLabel = panel:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
	nameLabel:SetPoint ("TOPLEFT", 68, -38);
	nameLabel:SetText (FT("Name"));

	local searchBox = CreateFrame ("EditBox", "Atr_Finder_SearchBox", panel, "InputBoxTemplate");
	searchBox:SetSize (100, 20);
	searchBox:SetPoint ("TOPLEFT", 72, -50);
	searchBox:SetAutoFocus (false);
	searchBox:SetMaxBytes (64);
	searchBox:SetScript ("OnEnterPressed", function (self)
		self:ClearFocus();
		Atr_Finder_StartSearch();
	end);
	searchBox:SetScript ("OnEscapePressed", function (self) self:ClearFocus(); end);

	local catBtn = CreateFrame ("Button", "Atr_Finder_CatButton", panel, "UIPanelButtonTemplate");
	catBtn:SetSize (92, 22);
	catBtn:SetPoint ("TOPLEFT", 178, -49);
	catBtn:SetText (FT("Categories"));

	if (UIDropDownMenu_Initialize) then
		local catDD = CreateFrame ("Frame", "Atr_Finder_CatDDMenu", panel, "UIDropDownMenuTemplate");
		catDD:Hide();
		UIDropDownMenu_Initialize (catDD, Fdr_CatMenu_Init, "MENU");
		catBtn:SetScript ("OnClick", function (self)
			ToggleDropDownMenu (1, nil, catDD, self, 0, 0);
		end);
	end

	local levLabel = panel:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
	levLabel:SetPoint ("TOPLEFT", 276, -38);
	levLabel:SetText (FT("Level Range"));

	local minBox = CreateFrame ("EditBox", "Atr_Finder_MinLevel", panel, "InputBoxTemplate");
	minBox:SetSize (30, 20);
	minBox:SetPoint ("TOPLEFT", 280, -50);
	minBox:SetAutoFocus (false);
	minBox:SetNumeric (true);
	minBox:SetMaxLetters (3);
	minBox:SetScript ("OnEnterPressed", function (self) self:ClearFocus(); Atr_Finder_StartSearch(); end);
	minBox:SetScript ("OnEscapePressed", function (self) self:ClearFocus(); end);

	local dash = panel:CreateFontString (nil, "ARTWORK", "GameFontHighlight");
	dash:SetPoint ("TOPLEFT", 314, -54);
	dash:SetText ("-");

	local maxBox = CreateFrame ("EditBox", "Atr_Finder_MaxLevel", panel, "InputBoxTemplate");
	maxBox:SetSize (30, 20);
	maxBox:SetPoint ("TOPLEFT", 326, -50);
	maxBox:SetAutoFocus (false);
	maxBox:SetNumeric (true);
	maxBox:SetMaxLetters (3);
	maxBox:SetScript ("OnEnterPressed", function (self) self:ClearFocus(); Atr_Finder_StartSearch(); end);
	maxBox:SetScript ("OnEscapePressed", function (self) self:ClearFocus(); end);

	local usable = CreateFrame ("CheckButton", "Atr_Finder_UsableCheck", panel, "UICheckButtonTemplate");
	usable:SetSize (24, 24);
	usable:SetPoint ("TOPLEFT", 356, -48);
	_G["Atr_Finder_UsableCheckText"]:SetText (FT("Usable"));

	AUCTIONATOR_FINDER_SETTINGS = AUCTIONATOR_FINDER_SETTINGS or {};

	local reqchk = CreateFrame ("CheckButton", "Atr_Finder_ReqCheck", panel, "UICheckButtonTemplate");
	reqchk:SetSize (24, 24);
	reqchk:SetPoint ("TOPLEFT", 424, -48);
	reqchk:SetChecked (AUCTIONATOR_FINDER_SETTINGS.reqOnly and true or nil);
	_G["Atr_Finder_ReqCheckText"]:SetText (FT("My Lvl"));
	reqchk:SetScript ("OnClick", function (self)
		AUCTIONATOR_FINDER_SETTINGS.reqOnly = self:GetChecked() and true or false;
		Atr_Finder_RebuildDisplay ();
		Atr_Finder_Redisplay ();
	end);
	reqchk:SetScript ("OnEnter", function (self)
		GameTooltip:SetOwner (self, "ANCHOR_TOPLEFT");
		GameTooltip:SetText (FT("My level only"), 1, 1, 1);
		GameTooltip:AddLine (FT("Hide items whose required level (Lvl column) is above your character's level. On Ascension, the Usable filter does not do this."), nil, nil, nil, true);
		GameTooltip:Show();
	end);
	reqchk:SetScript ("OnLeave", function () GameTooltip:Hide(); end);

	local searchBtn = CreateFrame ("Button", "Atr_Finder_SearchButton", panel, "UIPanelButtonTemplate");
	searchBtn:SetSize (70, 22);
	searchBtn:SetPoint ("TOPRIGHT", AuctionFrame, "TOPRIGHT", -18, -49);
	searchBtn:SetText (FT("Search"));
	searchBtn:SetScript ("OnClick", Atr_Finder_StartSearch);

	local group = CreateFrame ("CheckButton", "Atr_Finder_GroupCheck", panel, "UICheckButtonTemplate");
	group:SetSize (24, 24);
	group:SetPoint ("TOPLEFT", 494, -48);
	group:SetChecked (true);
	_G["Atr_Finder_GroupCheckText"]:SetText (FT("Group"));
	group:SetScript ("OnClick", function ()
		Atr_Finder_RebuildDisplay ();
		Fdr_SortAndRedisplay ();
	end);

	-- stat dropdown (only if the client has the dropdown library loaded)
	if (UIDropDownMenu_Initialize) then
		local dd = CreateFrame ("Frame", "Atr_Finder_StatDD", panel, "UIDropDownMenuTemplate");
		dd:SetPoint ("TOPLEFT", 556, -44);
		UIDropDownMenu_SetWidth (dd, 80);
		UIDropDownMenu_Initialize (dd, Fdr_StatDD_Initialize);
		Fdr_StatDD_SetText ();
	end

	local clearBtn = CreateFrame ("Button", "Atr_Finder_ClearButton", panel, "UIPanelButtonTemplate");
	clearBtn:SetSize (56, 22);
	clearBtn:SetPoint ("RIGHT", Atr_Finder_SearchButton, "LEFT", -6, 0);
	clearBtn:SetText (FT("Clear"));
	clearBtn:SetScript ("OnClick", Atr_Finder_ClearFilters);

	-- persisted settings (stored by the Auctionator_Finder_Debug stub addon)
	AUCTIONATOR_FINDER_SETTINGS = AUCTIONATOR_FINDER_SETTINGS or {};

	-- toolbar toggle for the large-search warning, next to Clear
	local nowarn = CreateFrame ("CheckButton", "Atr_Finder_NoWarnCheck", panel, "UICheckButtonTemplate");
	nowarn:SetSize (20, 20);
	nowarn:SetPoint ("BOTTOMRIGHT", AuctionFrame, "BOTTOMRIGHT", -75, 8);
	nowarn:SetChecked (AUCTIONATOR_FINDER_SETTINGS.ignoreLargeWarn and true or nil);
	_G["Atr_Finder_NoWarnCheckText"]:SetText (FT("No Warn"));
	nowarn:SetScript ("OnClick", function (self)
		Atr_Finder_SetIgnoreWarn (self:GetChecked());
	end);
	nowarn:SetScript ("OnEnter", function (self)
		GameTooltip:SetOwner (self, "ANCHOR_TOPLEFT");
		GameTooltip:SetText (FT("Large search warning"), 1, 1, 1);
		GameTooltip:AddLine (string.format (FT("When unchecked, searches larger than %d pages ask for confirmation before scanning. Check to skip the prompt."), 25), nil, nil, nil, true);
		GameTooltip:Show();
	end);
	nowarn:SetScript ("OnLeave", function () GameTooltip:Hide(); end);

	-- auto compare-tooltip toggle (equivalent of holding Shift while hovering)
	local cmp = CreateFrame ("CheckButton", "Atr_Finder_CompareCheck", panel, "UICheckButtonTemplate");
	cmp:SetSize (20, 20);
	cmp:SetPoint ("BOTTOMRIGHT", AuctionFrame, "BOTTOMRIGHT", -148, 8);
	cmp:SetChecked (AUCTIONATOR_FINDER_SETTINGS.autoCompare and true or nil);
	_G["Atr_Finder_CompareCheckText"]:SetText (FT("Compare"));
	cmp:SetScript ("OnClick", function (self)
		AUCTIONATOR_FINDER_SETTINGS.autoCompare = self:GetChecked() and true or false;
	end);
	cmp:SetScript ("OnEnter", function (self)
		GameTooltip:SetOwner (self, "ANCHOR_TOPLEFT");
		GameTooltip:SetText (FT("Auto compare"), 1, 1, 1);
		GameTooltip:AddLine (FT("Show your equipped item next to the tooltip when hovering gear, without holding Shift."), nil, nil, nil, true);
		GameTooltip:Show();
	end);
	cmp:SetScript ("OnLeave", function () GameTooltip:Hide(); end);

	-- Display on Character: update the dressing room while hovering rows
	local dress = CreateFrame ("CheckButton", "Atr_Finder_DressCheck", panel, "UICheckButtonTemplate");
	dress:SetSize (20, 20);
	dress:SetPoint ("BOTTOMRIGHT", AuctionFrame, "BOTTOMRIGHT", -230, 8);
	dress:SetChecked (AUCTIONATOR_FINDER_SETTINGS.dressHover and true or nil);
	_G["Atr_Finder_DressCheckText"]:SetText (FT("Dress"));
	dress:SetScript ("OnClick", function (self)
		AUCTIONATOR_FINDER_SETTINGS.dressHover = self:GetChecked() and true or false;
	end);
	dress:SetScript ("OnEnter", function (self)
		GameTooltip:SetOwner (self, "ANCHOR_TOPLEFT");
		GameTooltip:SetText (FT("Display on Character"), 1, 1, 1);
		GameTooltip:AddLine (FT("Show hovered gear on your character in the dressing room preview (rows are click-to-buy, so this updates on hover)."), nil, nil, nil, true);
		GameTooltip:Show();
	end);
	dress:SetScript ("OnLeave", function () GameTooltip:Hide(); end);

	-- large-search confirmation dialog
	local warn = CreateFrame ("Frame", "Atr_Finder_WarnFrame", panel);
	warn:SetSize (340, 130);
	warn:SetPoint ("CENTER", panel, "CENTER", 0, 40);
	warn:SetFrameStrata ("DIALOG");
	Fdr_StyleDialog (warn);
	warn:EnableMouse (true);
	warn:Hide();

	warn.text = warn:CreateFontString (nil, "ARTWORK", "GameFontHighlight");
	warn.text:SetPoint ("TOP", 0, -18);
	warn.text:SetWidth (300);
	warn.text:SetJustifyH ("CENTER");

	local wIgnore = CreateFrame ("CheckButton", "Atr_Finder_WarnIgnoreCheck", warn, "UICheckButtonTemplate");
	wIgnore:SetSize (22, 22);
	wIgnore:SetPoint ("BOTTOMLEFT", 22, 40);
	_G["Atr_Finder_WarnIgnoreCheckText"]:SetText (FT("Don't warn about large searches"));
	wIgnore:SetScript ("OnClick", function (self)
		Atr_Finder_SetIgnoreWarn (self:GetChecked());
	end);

	warn.continueBtn = CreateFrame ("Button", "Atr_Finder_WarnContinue", warn, "UIPanelButtonTemplate");
	warn.continueBtn:SetSize (90, 22);
	warn.continueBtn:SetPoint ("BOTTOMLEFT", 60, 12);
	warn.continueBtn:SetText (FT("Continue"));
	warn.continueBtn:SetScript ("OnClick", function ()
		warn:Hide();
		if (gFdr_State == FDR_PAUSED) then
			Fdr_HarvestPage ();		-- resume with the page we already received
		end
	end);

	warn.cancelBtn = CreateFrame ("Button", "Atr_Finder_WarnCancel", warn, "UIPanelButtonTemplate");
	warn.cancelBtn:SetSize (90, 22);
	warn.cancelBtn:SetPoint ("BOTTOMRIGHT", -60, 12);
	warn.cancelBtn:SetText (FT("Cancel"));
	warn.cancelBtn:SetScript ("OnClick", function ()
		Atr_Finder_CancelSearch (true);
	end);

	-- direct-buy confirmation dialog
	local buyf = CreateFrame ("Frame", "Atr_Finder_BuyFrame", panel);
	buyf:SetSize (390, 150);
	buyf:SetPoint ("CENTER", panel, "CENTER", 0, 40);
	buyf:SetFrameStrata ("DIALOG");
	Fdr_StyleDialog (buyf);
	buyf:EnableMouse (true);
	buyf:Hide();

	-- hidden tooltip used to read the server's per-listing data
	CreateFrame ("GameTooltip", "Atr_FinderScanTT", UIParent, "GameTooltipTemplate");

	buyf.itemname = buyf:CreateFontString (nil, "ARTWORK", "GameFontNormal");
	buyf.itemname:SetPoint ("TOP", 0, -18);
	buyf.itemname:SetWidth (290);

	buyf.details = buyf:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
	buyf.details:SetPoint ("TOP", 0, -40);
	buyf.details:SetWidth (290);
	buyf.details:SetJustifyH ("CENTER");

	buyf.price = buyf:CreateFontString (nil, "ARTWORK", "GameFontNormal");
	buyf.price:SetPoint ("TOP", 0, -84);

	buyf.buyBtn = CreateFrame ("Button", "Atr_Finder_BuyConfirm", buyf, "UIPanelButtonTemplate");
	buyf.buyBtn:SetSize (86, 22);
	buyf.buyBtn:SetPoint ("BOTTOMLEFT", 24, 14);
	buyf.buyBtn:SetText (FT("Buyout"));
	buyf.buyBtn:SetScript ("OnClick", function ()
		if (gFdrBuy_State == FDRBUY_CONFIRM) then
			FdrBuy_EnterFinal ("buyout");
		elseif (gFdrBuy_State == FDRBUY_FINAL) then
			FdrBuy_ConfirmPurchase ();
		end
	end);

	buyf.bidBtn = CreateFrame ("Button", "Atr_Finder_BuyBid", buyf, "UIPanelButtonTemplate");
	buyf.bidBtn:SetSize (86, 22);
	buyf.bidBtn:SetPoint ("BOTTOM", 0, 14);
	buyf.bidBtn:SetText (FT("Bid"));
	buyf.bidBtn:SetScript ("OnClick", function ()
		if (gFdrBuy_State == FDRBUY_CONFIRM) then
			FdrBuy_EnterFinal ("bid");
		end
	end);

	buyf.cancelBtn = CreateFrame ("Button", "Atr_Finder_BuyCancel", buyf, "UIPanelButtonTemplate");
	buyf.cancelBtn:SetSize (86, 22);
	buyf.cancelBtn:SetPoint ("BOTTOMRIGHT", -24, 14);
	buyf.cancelBtn:SetText (FT("Cancel"));
	buyf.cancelBtn:SetScript ("OnClick", function ()
		if (gFdrBuy_State == FDRBUY_FINAL) then
			FdrBuy_ShowConfirmView ();		-- Back to the choice step
		else
			Atr_Finder_CancelBuy ();
		end
	end);

	buyf.buyoutLabel = buyf:CreateFontString (nil, "ARTWORK", "GameFontNormalSmall");
	buyf.buyoutLabel:SetPoint ("BOTTOM", buyf.buyBtn, "TOP", 0, 4);

	buyf.bidLabel = buyf:CreateFontString (nil, "ARTWORK", "GameFontNormalSmall");
	buyf.bidLabel:SetPoint ("BOTTOM", buyf.bidBtn, "TOP", 0, 4);

	if (MoneyInputFrame_SetCopper) then
		local mi = CreateFrame ("Frame", "Atr_Finder_BidInput", buyf, "MoneyInputFrameTemplate");
		mi:SetPoint ("BOTTOM", buyf.bidBtn, "TOP", 32, 6);
		mi:Hide();
		buyf.bidInput = mi;
	end

	-- embedded preview tooltip: parented to the dialog so nothing steals it
	CreateFrame ("GameTooltip", "Atr_Finder_PreviewTT", buyf, "GameTooltipTemplate");

	function Atr_Finder_GetDisplay ()
		return gFdr_Display;
	end

	function Atr_Finder_ShowLargeWarn (pages, total, label)
		local what = (label and label ~= "") and (" "..FT("for").." "..label) or "";
		warn.text:SetText (string.format (
			FT("This search%s spans ~%d pages (~%d auctions) and may take a while.\n\nRefining categories, level range or name may be faster."),
			what, pages, total));
		wIgnore:SetChecked (Fdr_IgnoreWarn() and true or nil);
		warn:Show();
	end

	-- status message: bottom strip of the results area
	local msg = panel:CreateFontString ("Atr_Finder_Message", "ARTWORK", "GameFontNormal");
	msg:SetPoint ("TOPLEFT", 24, -398);
	msg:SetJustifyH ("LEFT");

	-- The "Prices" and "Research" toggles used to sit on this strip, at
	-- BOTTOMRIGHT -400 and -75.  They are settings, not per-search controls,
	-- so they moved to Interface > AddOns > Auctionator > Scanning - see the
	-- "scanning options rows" block at the end of this file.  Dress, Compare
	-- and No Warn each shifted one slot right so the strip still ends flush
	-- with the frame's right edge instead of leaving a hole where Research
	-- was.

	-- Verify button: only visible while greyed (scaled) rows are listed
	local verify = CreateFrame ("Button", "Atr_Finder_VerifyButton", panel, "UIPanelButtonTemplate");
	verify:SetSize (90, 22);
	verify:SetPoint ("BOTTOMRIGHT", AuctionFrame, "BOTTOMRIGHT", -70, 32);
	verify:SetText (FT("Verify"));
	verify:Hide();
	verify:SetScript ("OnClick", Atr_Finder_StartVerify);
	verify:SetScript ("OnEnter", function (self)
		GameTooltip:SetOwner (self, "ANCHOR_TOPLEFT");
		GameTooltip:SetText (FT("Verify greyed listings"), 1, 1, 1);
		GameTooltip:AddLine (FT("Reads each greyed (scaled) listing's server tooltip to fill in its true item level and DPS, and removes listings that are no longer on the auction house."), nil, nil, nil, true);
		GameTooltip:Show();
	end);
	verify:SetScript ("OnLeave", function () GameTooltip:Hide(); end);

	-- column headers -------------------------------------------------------

	Fdr_MakeHeader (panel, "name",		FT("Item"),			280,  20);
	Fdr_MakeHeader (panel, "ilvl",		FT("iLvl"),			 40, 302);
	Fdr_MakeHeader (panel, "level",		FT("Lvl"),			 36, 346);
	Fdr_MakeHeader (panel, "qty",		FT("Qty"),			 36, 386);
	Fdr_MakeHeader (panel, "timeleft",	FT("Time"),			 42, 426);
	Fdr_MakeHeader (panel, "dps",		FT("DPS"),			 46, 418);
	Fdr_MakeHeader (panel, "stat1",		"",					 46, 418);
	Fdr_MakeHeader (panel, "stat2",		"",					 46, 418);
	Fdr_MakeHeader (panel, "stat3",		"",					 46, 418);
	Fdr_MakeHeader (panel, "buyout",	FT("Buyout"),		120, 470);
	Fdr_MakeHeader (panel, "peritem",	FT("Per Item"),		 96, 592);

	-- scroll frame + rows --------------------------------------------------

	local scroll = CreateFrame ("ScrollFrame", "Atr_Finder_ScrollFrame", panel, "FauxScrollFrameTemplate");
	scroll:SetSize (690, FDR_NUM_ROWS * FDR_ROW_HEIGHT);
	scroll:SetPoint ("TOPLEFT", 20, -94);
	scroll:SetScript ("OnVerticalScroll", function (self, offset)
		FauxScrollFrame_OnVerticalScroll (self, offset, FDR_ROW_HEIGHT, Atr_Finder_Redisplay);
	end);

	local sbar = _G["Atr_Finder_ScrollFrameScrollBar"];
	if (sbar) then
		sbar:ClearAllPoints();
		sbar:SetPoint ("TOPRIGHT",    AuctionFrame, "TOPRIGHT",    -18, -110);
		sbar:SetPoint ("BOTTOMRIGHT", AuctionFrame, "BOTTOMRIGHT", -18,  69);
	end

	local i;
	for i = 1, FDR_NUM_ROWS do

		local row = CreateFrame ("Button", "Atr_Finder_Row"..i, panel);
		row:SetSize (690, FDR_ROW_HEIGHT);
		row:SetPoint ("TOPLEFT", 20, -94 - (i-1) * FDR_ROW_HEIGHT);

		row:SetHighlightTexture ("Interface\\QuestFrame\\UI-QuestTitleHighlight");

		row.icon = row:CreateTexture (nil, "ARTWORK");
		row.icon:SetSize (16, 16);
		row.icon:SetPoint ("LEFT", 2, 0);

		row.cells = {};

		local function cell (justify)
			local fs = row:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
			fs:SetHeight (FDR_ROW_HEIGHT);
			fs:SetJustifyH (justify);
			return fs;
		end

		row.cells.name		= cell ("LEFT");
		row.cells.ilvl		= cell ("RIGHT");
		row.cells.level		= cell ("RIGHT");
		row.cells.qty		= cell ("RIGHT");
		row.cells.timeleft	= cell ("CENTER");
		row.cells.dps		= cell ("RIGHT");
		row.cells.stat1		= cell ("RIGHT");
		row.cells.stat2		= cell ("RIGHT");
		row.cells.stat3		= cell ("RIGHT");
		row.cells.buyout	= cell ("RIGHT");
		row.cells.peritem	= cell ("RIGHT");

		row:RegisterForClicks ("LeftButtonUp", "RightButtonUp");
		row:SetScript ("OnEnter",		Fdr_Row_OnEnter);
		row:SetScript ("OnLeave",		Fdr_Row_OnLeave);
		row:SetScript ("OnClick",		Fdr_Row_OnClick);

		row:Hide();

		gFdr_Rows[i] = row;
	end

	Fdr_ApplyColumnLayout ();
	Fdr_UpdateHeaderArrows ();
	Fdr_SetMessage (FT("Enter a search and press Search"));

	-- "Back to Finder" on the Buy tab: PRESENT only when the Buy tab was
	-- reached from a Finder row, exactly as the Bazaar's own "Back to Bazaar"
	-- behaves.  Until 2026-07 this hung off a gFdr_JumpPending flag that
	-- nothing ever set -- the jump it was written for was never built -- so
	-- the button sat on the Buy tab permanently greyed out and did nothing.
	-- Atr_Finder_JumpToBuy now raises that flag.
	if (Atr_Buy1_Button and hooksecurefunc) then

		local back = CreateFrame ("Button", "Atr_Finder_BackButton", Atr_Buy1_Button:GetParent() or AuctionFrame, "UIPanelButtonTemplate");
		back:SetSize (120, 24);
		back:SetPoint ("RIGHT", Atr_Buy1_Button, "LEFT", -45, 0);
		back:SetText (FT("Back to Finder"));
		back:Hide();
		back:SetScript ("OnClick", function ()
			Atr_SelectPane (ATR_FINDER_TAB);
		end);

		hooksecurefunc ("Atr_AuctionFrameTab_OnClick", function ()

			if (not Atr_Finder_BackButton) then return; end

			local onBuy = Atr_IsTabSelected and Atr_IsTabSelected (ATR_BUY_TAB or 3);

			if (onBuy and gFdr_JumpPending) then
				gFdr_BackEnabled = true;
			elseif (not onBuy) then
				-- left the Buy tab: the offer to go back expires with it
				gFdr_BackEnabled = false;
			end
			gFdr_JumpPending = false;

			if (onBuy and gFdr_BackEnabled) then
				Atr_Finder_BackButton:Enable();
				Atr_Finder_BackButton:Show();
			else
				Atr_Finder_BackButton:Hide();
			end

			-- The Bazaar parks its own "Back to Bazaar" to the LEFT of this
			-- button so the two cannot collide when both jumps are pending.
			-- That anchor was chosen when this button was always on screen;
			-- now that it is usually hidden it would leave a hole, so re-seat
			-- the Bazaar's button against whichever neighbour is actually
			-- visible.  Safe to read here: Atr_Bz_OnTabClick runs from the TOP
			-- of Atr_AuctionFrameTab_OnClick and this is a post-hook, so the
			-- Bazaar's own show/hide has already settled.
			if (Atr_Bz_BuyBackButton and Atr_Bz_BuyBackButton:IsShown()) then
				Atr_Bz_BuyBackButton:ClearAllPoints();
				if (Atr_Finder_BackButton:IsShown()) then
					Atr_Bz_BuyBackButton:SetPoint ("RIGHT", Atr_Finder_BackButton, "LEFT", -6, 0);
				else
					Atr_Bz_BuyBackButton:SetPoint ("RIGHT", Atr_Buy1_Button, "LEFT", -45, 0);
				end
			end
		end);
	end
end


-- ===========================================================================
-- FINDER_TAB begin: full scan replacement
--
-- Upstream's Full Scan is dead on this server, twice over:
--   * Atr_FullScanStart calls QueryAuctionItems(..., getAll=true), which
--     Ascension disables; and
--   * Atr_UpdateFullScanFrame DISABLES the Start button whenever
--     CanSendAuctionQuery's second return is false, which here it always is.
-- So the button is greyed out before it can even fail.  Upstream's paged
-- alternative was abandoned mid-wiring (Atr_FullScan_Slow is commented out
-- in Auctionator.xml, and Atr_FullScanStart reads a local that is always
-- false).
--
-- This replaces all three entry points -- Atr_ShowFullScanFrame,
-- Atr_UpdateFullScanFrame and Atr_FullScanStart -- by REDEFINING the
-- globals.  The toc loads AuctionatorFinder.lua after AuctionatorScan.lua,
-- so the later definition wins and neither AuctionatorScan.lua nor
-- Auctionator.xml needs editing.
--
-- The dialog is reused rather than replaced: Atr_FullScanFrame already has
-- the item-count readout, the last-scan line, a status line and a Done
-- button.  Only Atr_FullScanHTML (the explanation blob, 405x300 at 27,-175)
-- is hidden, and the category picker is built in Lua in exactly that space.
--
-- WHY GEAR IS EXCLUDED, and why it is not merely unticked but absent:
-- gAtr_ScanDB is keyed by item NAME.  On Ascension one name covers many
-- scaled instances at different item levels, so a single stored price would
-- stand in for every variant and be wrong for all but one.  Rule 2 of the
-- price feed already refuses scaled equipment, so including gear would burn
-- an enormous amount of scan time to store almost nothing.  The Finder tab
-- reads each listing's REAL required level and is the right tool for gear.
--
-- MEMORY: categories run ONE AT A TIME and the price feed flushes after
-- each.  A single Trade Goods sweep on this realm is ~37k records; holding
-- Consumables, Recipes, Glyphs and Gems simultaneously would be far worse.
-- Sequential also means a cancel keeps everything already priced.
-- ===========================================================================

local FS_WEAPON_CLASS	= 1;		-- GetAuctionItemClasses indices, stable in 3.3.5
local FS_ARMOR_CLASS	= 2;

-- Ammunition and quivers are two tiny classes that nobody thinks of as
-- separate shopping trips, so they are folded into Miscellaneous: one
-- checkbox, three server scans.  Keyed by CLASS NAME rather than index
-- because Ascension's class list is not stock (it appends "Quest"), and a
-- name lookup degrades to "no merge" instead of merging the wrong thing.
local FS_MERGE_INTO = {
	["Projectile"]	= "Miscellaneous",
	["Quiver"]		= "Miscellaneous",
};

local gFS_Queue		= nil;		-- selected classes for the run in progress
local gFS_Index		= 0;
local gFS_Added		= 0;
local gFS_Updated	= 0;
local gFS_Skipped	= 0;
local gFS_Bazaar	= false;
local gFS_Built		= false;
local gFS_Cancelling = false;	-- re-entrancy guard: the cancel path is mutual



function Fdr_FS_IsGearClass (ci)
	return (ci == FS_WEAPON_CLASS or ci == FS_ARMOR_CLASS);
end


-- Every auction class, gear flagged rather than dropped: the picker shows the
-- gear rows greyed so the exclusion is visible and explained, not silent.
function Fdr_FS_Classes ()

	local names;
	if (Atr_GetAuctionClasses) then
		names = Atr_GetAuctionClasses ();
	elseif (GetAuctionItemClasses) then
		names = { GetAuctionItemClasses () };
	else
		names = {};
	end

	-- index the merge targets first, so a member can be attached to its host
	-- wherever the two happen to sit in the list
	local hostOf, byName = {}, {};
	local i;
	for i = 1, #names do byName[names[i]] = i; end
	for i = 1, #names do
		local into = FS_MERGE_INTO[names[i]];
		if (into and byName[into]) then hostOf[i] = byName[into]; end
	end

	local out, slot = {}, {};
	for i = 1, #names do
		if (hostOf[i] == nil) then
			out[#out + 1] = { ci = i, name = names[i], gear = Fdr_FS_IsGearClass (i),
							  members = { i } };
			slot[i] = out[#out];
		end
	end

	-- attach each merged class to its host's member list
	for i = 1, #names do
		local host = hostOf[i];
		if (host and slot[host]) then
			tinsert (slot[host].members, i);
		end
	end

	return out;
end


function Fdr_FS_Store ()

	if (AUCTIONATOR_FINDER_SETTINGS == nil) then AUCTIONATOR_FINDER_SETTINGS = {}; end
	if (type (AUCTIONATOR_FINDER_SETTINGS.fullScanCats) ~= "table") then
		AUCTIONATOR_FINDER_SETTINGS.fullScanCats = {};
	end
	return AUCTIONATOR_FINDER_SETTINGS.fullScanCats;
end


-- Gear is refused HERE as well as in the UI, so a hand-edited SavedVariables
-- file cannot smuggle Armor into a run.
function Fdr_FS_IsSelected (ci)

	if (Fdr_FS_IsGearClass (ci)) then return false; end

	local v = Fdr_FS_Store()[tostring (ci)];
	if (v == nil) then return true; end			-- default: every non-gear class
	return v and true or false;
end


function Fdr_FS_SetSelected (ci, on)

	if (Fdr_FS_IsGearClass (ci)) then return false; end

	Fdr_FS_Store()[tostring (ci)] = on and true or false;
	return true;
end


-- One entry per SERVER SCAN, not per checkbox: ticking Miscellaneous yields
-- Miscellaneous, Projectile and Quiver.  Everything downstream -- the queue,
-- the "n of m" counter and the readout on the dialog -- then counts the same
-- thing, so none of them can disagree.
function Fdr_FS_SelectedClasses ()

	local all, out = Fdr_FS_Classes (), {};
	local names = (Atr_GetAuctionClasses and Atr_GetAuctionClasses ()) or {};

	local i, j;
	for i = 1, #all do
		if (not all[i].gear and Fdr_FS_IsSelected (all[i].ci)) then
			local m = all[i].members or { all[i].ci };
			for j = 1, #m do
				out[#out + 1] = { ci = m[j], name = names[m[j]] or all[i].name };
			end
		end
	end
	return out;
end


function Fdr_FS_Running ()
	return gFS_Queue ~= nil;
end


function Fdr_FS_Status (s)
	if (Atr_FullScanStatus) then Atr_FullScanStatus:SetText (s or ""); end
end


-- Echo of the engine's own status line, prefixed with our position in the
-- queue.  The engine's text already names the category and carries
-- "page N / M", so this composes rather than duplicating.
function Fdr_FS_EchoProgress (msg)

	if (gFS_Queue == nil) then return; end
	if (type (msg) ~= "string" or msg == "") then return; end

	Fdr_FS_Status (string.format ("(%d/%d)  %s", gFS_Index, #gFS_Queue, msg));
end


function Fdr_FS_UpdateButtons ()

	if (Atr_FullScanStartButton) then
		Atr_FullScanStartButton:Enable();		-- never gated on canQueryAll: we do not use getAll
		Atr_FullScanStartButton:SetText (Fdr_FS_Running() and FT("Cancel") or FT("Scan Categories"));
	end

	if (Atr_FullScanDone) then
		if (Fdr_FS_Running()) then Atr_FullScanDone:Disable(); else Atr_FullScanDone:Enable(); end
	end
end


-- Atr_Finder_CancelSearch calls back into here, so the two guard each other
-- with gFS_Cancelling rather than one of them being careful about ordering.
-- Stopping the queue is NOT enough on its own: the Finder engine owns an
-- in-flight category scan and would keep paging (and then hold the engine so
-- the next run could not start at all).
function Fdr_FS_Cancel (quiet)

	if (gFS_Cancelling) then return; end
	gFS_Cancelling = true;

	local was = gFS_Queue;

	gFS_Queue = nil;
	gFS_Index = 0;

	Atr_Finder_SetFinishHook (nil);

	if (Atr_Finder_CancelSearch) then
		local a, u = Atr_Finder_CancelSearch (false);
		gFS_Added	= gFS_Added + (a or 0);		-- bank the partial flush
		gFS_Updated	= gFS_Updated + (u or 0);
	end
	if (Atr_Bz_CancelCategoryScan) then Atr_Bz_CancelCategoryScan (true); end

	gFS_Cancelling = false;

	if (was and not quiet) then
		Fdr_FS_Status (string.format (FT("Stopped - %d new, %d updated"), gFS_Added, gFS_Updated));
	end

	Fdr_FS_UpdateButtons ();
	if (Atr_UpdateFullScanFrame) then Atr_UpdateFullScanFrame (); end
end


-- Optional tail phase: price the Bazaar catalogue too.  Handed off to the
-- Bazaar's own sequential scanner, which already records per-item buyouts.
function Fdr_FS_StartBazaar ()

	if (not (gFS_Bazaar and Atr_Bz_StartCategoryScan)) then return false; end

	Fdr_FS_Status (FT("Pricing the Bazaar catalogue..."));
	return Atr_Bz_StartCategoryScan () and true or false;
end


function Fdr_FS_Done ()

	local n = gFS_Index - 1;

	gFS_Queue = nil;
	gFS_Index = 0;

	Atr_Finder_SetFinishHook (nil);

	Fdr_FS_StartBazaar ();

	Fdr_FS_Status (string.format (FT("Done: %d %s, %d new, %d updated"),
					n, (n == 1) and FT("category") or FT("categories"),
					gFS_Added, gFS_Updated));

	Fdr_FS_UpdateButtons ();
	if (Atr_UpdateFullScanFrame) then Atr_UpdateFullScanFrame (); end
end


function Fdr_FS_Next ()

	if (gFS_Queue == nil) then return; end

	gFS_Index = gFS_Index + 1;

	local entry = gFS_Queue[gFS_Index];
	if (entry == nil) then
		Fdr_FS_Done ();
		return;
	end

	Fdr_FS_Status (string.format (FT("Scanning %s (%d of %d)"),
					entry.name or "?", gFS_Index, #gFS_Queue));

	local spec = { class = entry.ci, subclass = nil, autoAccept = true, label = entry.name };

	local started = Atr_Finder_StartQueueScan ({ spec }, function (added, updated, skipped)
			gFS_Added	= gFS_Added + (added or 0);
			gFS_Updated	= gFS_Updated + (updated or 0);
			gFS_Skipped	= gFS_Skipped + (skipped or 0);
			if (Atr_UpdateFullScanFrame) then Atr_UpdateFullScanFrame (); end
			Fdr_FS_Next ();
		end);

	if (not started) then
		-- something else owns the engine; stop rather than spin
		Fdr_FS_Cancel (true);
		Fdr_FS_Status (FT("Finish or cancel the scan first"));
		Fdr_FS_UpdateButtons ();
	end
end


-- ---------------------------------------------------------------------------
-- the picker, built into the space Atr_FullScanHTML used to occupy
-- ---------------------------------------------------------------------------

function Fdr_FS_BuildPicker ()

	if (gFS_Built) then return true; end
	if (not (Atr_FullScanFrame and CreateFrame)) then return false; end

	local panel = CreateFrame ("Frame", "Atr_FS_Picker", Atr_FullScanFrame);
	panel:SetPoint ("TOPLEFT", 27, -175);
	panel:SetWidth (405);
	panel:SetHeight (300);

	local head = panel:CreateFontString ("Atr_FS_PickerHead", "ARTWORK", "GameFontNormal");
	head:SetPoint ("TOPLEFT", 0, 0);
	head:SetText (FT("Categories to scan"));

	local all = Fdr_FS_Classes ();

	-- balance the two columns instead of hardcoding a wrap: the class list is
	-- not stock here (Ascension appends "Quest") and merging shortens it again
	local perCol = math.ceil (#all / 2);
	if (perCol < 1) then perCol = 1; end

	local col, row = 0, 0;
	local i;

	for i = 1, #all do

		local e	  = all[i];
		local cb  = CreateFrame ("CheckButton", "Atr_FS_Cat"..e.ci, panel, "UICheckButtonTemplate");
		local txt = _G["Atr_FS_Cat"..e.ci.."Text"];

		cb:SetSize (20, 20);
		cb:SetPoint ("TOPLEFT", col * 200, -22 - (row * 22));

		-- a merged row says what it now covers, so the fold is not a surprise
		local label = e.name or ("#"..e.ci);
		if (e.members and #e.members > 1) then
			label = label.." |cff808080+|r";
		end

		if (txt) then txt:SetText (label); end

		if (e.gear) then
			-- present but refused: the exclusion has to be visible to be honest
			cb:SetChecked (nil);
			cb:Disable();
			if (txt) then txt:SetText ("|cff808080"..label.."|r"); end
		else
			cb:SetChecked (Fdr_FS_IsSelected (e.ci) and true or nil);
			cb:SetScript ("OnClick", function (self)
					Fdr_FS_SetSelected (e.ci, self:GetChecked() and true or false);
					if (Atr_UpdateFullScanFrame) then Atr_UpdateFullScanFrame (); end
				end);

			if (e.members and #e.members > 1 and GameTooltip) then
				local names = (Atr_GetAuctionClasses and Atr_GetAuctionClasses ()) or {};
				local parts, k = {}, nil;
				for k = 1, #e.members do parts[k] = names[e.members[k]] or "?"; end
				local tip = table.concat (parts, ", ");
				cb:SetScript ("OnEnter", function (self)
						GameTooltip:SetOwner (self, "ANCHOR_TOPLEFT");
						GameTooltip:SetText (FT("Scans: ")..tip, 1, 1, 1);
						GameTooltip:Show();
					end);
				cb:SetScript ("OnLeave", function () GameTooltip:Hide(); end);
			end
		end

		row = row + 1;
		if (row >= perCol) then row = 0; col = col + 1; end
	end

	local yBase = -22 - (perCol * 22) - 10;

	local bz = CreateFrame ("CheckButton", "Atr_FS_BazaarCheck", panel, "UICheckButtonTemplate");
	bz:SetSize (20, 20);
	bz:SetPoint ("TOPLEFT", 0, yBase);
	bz:SetChecked (nil);
	if (_G["Atr_FS_BazaarCheckText"]) then
		_G["Atr_FS_BazaarCheckText"]:SetText (FT("Also price the Bazaar catalogue"));
	end

	-- The exclusion, spelled out. 3.3.5 FontStrings wrap once a width is set
	-- and nothing clips them, so the width is fixed and the height is not.
	local why = panel:CreateFontString ("Atr_FS_WhyNoGear", "ARTWORK", "GameFontNormalSmall");
	why:SetPoint ("TOPLEFT", 0, yBase - 30);
	why:SetWidth (395);
	why:SetJustifyH ("LEFT");
	why:SetText ("|cffffcc00"..FT("Weapons and Armor are not scanned.").."|r  "
				..FT("Auctionator's price database is keyed by item NAME. On Ascension "
					.."one name covers many scaled versions at different item levels, so a "
					.."single stored price would stand in for every version and be wrong "
					.."for all but one. Use the Finder tab for gear."));

	gFS_Built = true;
	return true;
end


-- ---------------------------------------------------------------------------
-- the three upstream globals, replaced
-- ---------------------------------------------------------------------------

function Atr_ShowFullScanFrame ()

	if (not Atr_FullScanFrame) then return; end

	if (Atr_FullScanHTML)	 then Atr_FullScanHTML:Hide();	  end	-- the explanation blob
	if (Atr_FullScanResults) then Atr_FullScanResults:Hide(); end

	Fdr_FS_BuildPicker ();
	if (Atr_FS_Picker) then Atr_FS_Picker:Show(); end

	Atr_FullScanFrame:Show();
	Atr_FullScanFrame:SetBackdropColor (0, 0, 0, 100);

	Fdr_FS_Status ("");
	Atr_UpdateFullScanFrame ();
end


function Atr_UpdateFullScanFrame ()

	if (Atr_FullScanDBsize and Atr_GetDBsize) then
		Atr_FullScanDBsize:SetText (Atr_GetDBsize());
	end

	if (Atr_FullScanDBwhen) then
		if (AUCTIONATOR_LAST_SCAN_TIME and date) then
			Atr_FullScanDBwhen:SetText (date ("%A, %B %d at %I:%M %p", AUCTIONATOR_LAST_SCAN_TIME));
		else
			Atr_FullScanDBwhen:SetText (FT("Never"));
		end
	end

	-- Upstream showed a 15-minute countdown to the next getAll. We never call
	-- getAll, so that timer is meaningless; the useful number is how much has
	-- been asked for.
	if (Atr_FullScanNextLabel) then Atr_FullScanNextLabel:SetText (FT("Scans to run:")); end
	if (Atr_FullScanNext) then
		Atr_FullScanNext:SetText (tostring (#Fdr_FS_SelectedClasses ()));
	end

	Fdr_FS_UpdateButtons ();
end


function Atr_FullScanStart ()

	if (Fdr_FS_Running ()) then
		Fdr_FS_Cancel (false);
		return;
	end

	local sel = Fdr_FS_SelectedClasses ();

	if (#sel == 0) then
		Fdr_FS_Status (FT("Select at least one category."));
		return;
	end

	gFS_Queue	= sel;
	gFS_Index	= 0;
	gFS_Added	= 0;
	gFS_Updated	= 0;
	gFS_Skipped	= 0;
	gFS_Bazaar	= (Atr_FS_BazaarCheck and Atr_FS_BazaarCheck:GetChecked()) and true or false;

	Fdr_FS_UpdateButtons ();
	Fdr_FS_Next ();
end


-- "Full Scan..." is a misnomer once gear is excluded and the scan is
-- category-driven, so relabel the More... entry to match what it does.
if (Atr_FullScanButton and Atr_FullScanButton.SetText) then
	Atr_FullScanButton:SetText (FT("Scan Categories..."));
end
-- FINDER_TAB end: full scan replacement


-- ===========================================================================
-- FINDER_TAB begin: scanning options rows
--
-- Two Finder settings live in Interface > AddOns > Auctionator > Scanning,
-- under the quality floor that governs the same price feed:
--   * Prices   - AUCTIONATOR_FINDER_SETTINGS.feedPriceDB   (default ON)
--   * Research - AUCTIONATOR_FINDER_SETTINGS.researchDump  (default OFF)
-- Both were checkboxes on the Finder tab's bottom strip until 2026-07.
--
-- TWO TRAPS, both specific to Auctionator's options plumbing:
--   1. Atr_LoadOptionsSubPanel copies the save function into f.okay BY VALUE
--      at XML OnLoad (`f.okay = _G[frameName.."_Save"]`), and Blizzard calls
--      that captured field.  hooksecurefunc on the global name is therefore
--      INERT for the Okay path - the panel's own okay/cancel fields have to
--      be wrapped instead.  AuctionatorConfig.xml is the last file in the
--      toc, so the field is always set before PLAYER_LOGIN gets here.
--   2. Blizzard calls okay() on EVERY registered category when Okay is
--      pressed, whether or not that panel was ever displayed.  So the rows
--      must exist and be in sync from login, not from first display, or the
--      first Okay writes whatever an uninitialised checkbox happened to say.
--
-- Everything is guarded: a build without this panel degrades to "no rows",
-- never to an error, and /atrprices on|off and /atrresearch on|off remain as
-- the fallback path to the same two settings.
-- ===========================================================================

local gFdr_OptRows = nil;

-- Creates the rows once.  Returns the widget table, or nil when this build
-- has no Scanning panel to hang them on.
function Fdr_Options_Ensure ()

	if (gFdr_OptRows) then return gFdr_OptRows; end

	local panel = _G["Atr_ScanningOptionsFrame"];
	if (panel == nil or CreateFrame == nil or panel.CreateFontString == nil) then return nil; end

	-- The panel's own content ends at the quality-floor dropdown (y -60,
	-- ~32 tall), so -110 down is free.
	local head = panel:CreateFontString (nil, "ARTWORK", "GameFontNormal");
	head:SetPoint ("TOPLEFT", panel, "TOPLEFT", 18, -110);
	head:SetText (FT("Finder scans"));

	local function row (name, y, label, tipTitle, tipLines)

		local cb = CreateFrame ("CheckButton", name, panel, "UICheckButtonTemplate");
		cb:SetWidth (24);
		cb:SetHeight (24);
		cb:SetPoint ("TOPLEFT", panel, "TOPLEFT", 20, y);

		local t = _G[name.."Text"];
		if (t) then t:SetText (" "..label); end

		cb:SetScript ("OnEnter", function (self)
			if (GameTooltip == nil) then return; end
			GameTooltip:SetOwner (self, "ANCHOR_TOPLEFT");
			GameTooltip:SetText (tipTitle, 1, 1, 1);
			local i;
			for i = 1, #tipLines do
				local ln = tipLines[i];
				if (type (ln) == "table") then
					GameTooltip:AddLine (ln[1], ln[2], ln[3], ln[4]);
				else
					GameTooltip:AddLine (ln, nil, nil, nil, true);
				end
			end
			GameTooltip:Show();
		end);
		cb:SetScript ("OnLeave", function () if (GameTooltip) then GameTooltip:Hide(); end end);

		return cb;
	end

	gFdr_OptRows = {};

	gFdr_OptRows.prices = row ("Atr_Finder_Opt_Prices_CB", -134,
		FT("Update Auctionator prices from Finder scans"),
		FT("Update Auctionator prices"),
		{ FT("Feeds this scan's lowest buyouts into Auctionator's own price database, so the Buy and Sell tabs stay current without a Full Scan. Scaled gear is excluded (that database is keyed by name, which cannot tell scaled variants apart) and nothing is ever deleted. Skipped entirely when a scan hits the result cap, because a truncated scan's lowest prices are too high.") });

	gFdr_OptRows.research = row ("Atr_Finder_Opt_Research_CB", -160,
		FT("Save Finder research data for upload"),
		FT("Research capture"),
		{ FT("When checked, each completed scan's item data (names, links, stats, prices) is saved to:"),
		  { "SavedVariables\\Auctionator_Finder_Debug.lua", 0.5, 0.8, 1.0 },
		  FT("Writes the last scan's raw rows AND the ranked vendor-price research targets for offline analysis. The target ledger itself is always collected - this only controls the upload file. Written on /reload or logout; requires the Auctionator_Finder_Debug addon folder. In game use /atrtarget.") });

	gFdr_OptRows.gearjump = row ("Atr_Finder_Opt_GearJump_CB", -186,
		FT("Open weapons and armor on the Finder tab"),
		FT("Gear opens on the Finder tab"),
		{ FT("Picking a weapon or a piece of armor on the Buy tab searches it here instead. The Buy tab groups a scan by item name and shows one cached version for all of it, which on this realm can be a different item than the one you buy; this tab reads each listing's own required level and verifies its real item level. Everything that is not gear still opens on the Buy tab. Searching the same item a second time stays there."),
		  FT("In game use /atrgear.") });

	return gFdr_OptRows;
end


-- settings -> widgets.  Global: the slash fallbacks call it too, so a toggle
-- made from chat shows up on an already-open panel.
function Fdr_Options_Sync ()

	local r = Fdr_Options_Ensure ();
	if (r == nil) then return; end

	r.prices:SetChecked (Fdr_PriceDB_Enabled () and true or nil);
	r.research:SetChecked (Fdr_ResearchDump_Enabled () and true or nil);
	r.gearjump:SetChecked (Fdr_BuyRedirect_Enabled () and true or nil);
end


-- widgets -> settings.  Only ever called from the wrapped okay, and only
-- writes when the rows actually exist.
function Fdr_Options_Apply ()

	if (gFdr_OptRows == nil) then return; end

	AUCTIONATOR_FINDER_SETTINGS = AUCTIONATOR_FINDER_SETTINGS or {};
	AUCTIONATOR_FINDER_SETTINGS.feedPriceDB   = gFdr_OptRows.prices:GetChecked() and true or false;
	AUCTIONATOR_FINDER_SETTINGS.researchDump  = gFdr_OptRows.research:GetChecked() and true or false;
	AUCTIONATOR_FINDER_SETTINGS.gearToFinder  = gFdr_OptRows.gearjump:GetChecked() and true or false;
end


-- Wraps the panel's okay/cancel (see trap 1) and builds the rows (trap 2).
-- Idempotent, so a second call - or another addon's - cannot double-wrap.
function Fdr_Options_Init ()

	local panel = _G["Atr_ScanningOptionsFrame"];
	if (panel == nil or panel.fdrOptionsWrapped) then return false; end
	panel.fdrOptionsWrapped = true;

	local prevOkay		= panel.okay;
	local prevCancel	= panel.cancel;

	panel.okay = function (...)
		if (prevOkay) then prevOkay (...); end
		Fdr_Options_Apply ();
	end

	panel.cancel = function (...)
		if (prevCancel) then prevCancel (...); end
		Fdr_Options_Sync ();			-- discard our edits along with theirs
	end

	if (panel.HookScript) then
		panel:HookScript ("OnShow", Fdr_Options_Sync);
	end

	Fdr_Options_Sync ();				-- create + fill NOW, not on first display
	return true;
end


-- Chat fallback for both settings, and the only route on a build whose
-- Scanning panel we could not find.  /atrprices carries the price feed's.
if (SlashCmdList) then
	SLASH_ATRRESEARCHDUMP1 = "/atrresearch";
	SlashCmdList["ATRRESEARCHDUMP"] = function (msg)

		local arg = tostring (msg or ""):lower():match ("%a+");
		if (arg == "on" or arg == "off") then
			AUCTIONATOR_FINDER_SETTINGS = AUCTIONATOR_FINDER_SETTINGS or {};
			AUCTIONATOR_FINDER_SETTINGS.researchDump = (arg == "on");
			Fdr_Options_Sync ();
		end

		local s = "Finder research capture: "..(Fdr_ResearchDump_Enabled () and
					"|cff40ff40ON|r - dumps written on /reload" or
					"|cffff4040OFF|r (Auctionator options > Scanning)");
		if (zc and zc.msg_atr) then zc.msg_atr (s);
		elseif (DEFAULT_CHAT_FRAME) then DEFAULT_CHAT_FRAME:AddMessage (s); end
	end

	SLASH_ATRVARIANTDB1 = "/atrahdb";
	SlashCmdList["ATRVARIANTDB"] = function (msg)

		local arg = string.lower (string.gsub (msg or "", "^%s*(.-)%s*$", "%1"));

		if (arg == "on" or arg == "off") then
			AUCTIONATOR_FINDER_SETTINGS = AUCTIONATOR_FINDER_SETTINGS or {};
			AUCTIONATOR_FINDER_SETTINGS.ahVariant = (arg == "on");
			zc.msg_pink ("Verified auction prices on tooltips: "..(arg == "on" and "ON" or "OFF"));
			return;
		end

		local db = Atr_AHVariantDB and Atr_AHVariantDB ();
		zc.msg_pink ("Verified auction prices: "
			..((Atr_AHVariant_Enabled and Atr_AHVariant_Enabled ()) and "ON" or "OFF")
			.."  ·  "..tostring (db and db.c or 0).." variant(s) known"
			.."  ·  session "..tostring (db and db.s or 0));
		zc.msg_pink ("Use /atrahdb on|off.  Prices come from the Verify button; a '*' on the");
		zc.msg_pink ("Auction line means the price is for that exact scale-variant.");
	end

	SLASH_ATRGEARJUMP1 = "/atrgear";
	SlashCmdList["ATRGEARJUMP"] = function (msg)

		local arg = tostring (msg or ""):lower():match ("%a+");
		if (arg == "on" or arg == "off") then
			AUCTIONATOR_FINDER_SETTINGS = AUCTIONATOR_FINDER_SETTINGS or {};
			AUCTIONATOR_FINDER_SETTINGS.gearToFinder = (arg == "on");
			gFdr_Redir.skip = nil;			-- a deliberate toggle re-arms it
			Fdr_Options_Sync ();
		end

		local s = "Gear opens on the Finder tab: "..(Fdr_BuyRedirect_Enabled () and
					"|cff40ff40ON|r - weapons and armor picked on the Buy tab search here instead" or
					"|cffff4040OFF|r (Auctionator options > Scanning)");
		if (zc and zc.msg_atr) then zc.msg_atr (s);
		elseif (DEFAULT_CHAT_FRAME) then DEFAULT_CHAT_FRAME:AddMessage (s); end
	end
end


local gFdr_OptEventFrame = CreateFrame ("Frame", "Atr_Finder_OptionsEventFrame");
gFdr_OptEventFrame:RegisterEvent ("PLAYER_LOGIN");
gFdr_OptEventFrame:SetScript ("OnEvent", function ()
	Fdr_Options_Init ();
end);
-- FINDER_TAB end: scanning options rows
