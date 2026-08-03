-------------------------------------------------------------------------------
-- AuctionatorFinderResearch.lua
--
-- The vendor-price research ledger: every Finder scan feeds a persistent
-- ledger of scaled-equipment variants, which is ranked into a shopping list of
-- the cheapest, most-available items at price points no confirmed sale has
-- mapped yet.  Hosts the /atrtarget shopping-list command and its copy window.
--
-- Split out of AuctionatorFinder.lua (was the "research targets" section).  It
-- exports globals (Fdr_Research_* / Fdr_ResearchItemID / the /atrtarget slash
-- command) that the core scan engine calls at runtime, and reads the live scan
-- results back through addonTable.Finder.GetResults when absorbing a scan.
-------------------------------------------------------------------------------

local addonName, addonTable = ...;
local zc = addonTable and addonTable.zc;
local F  = addonTable and addonTable.Finder;

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

	results = results or F.GetResults ();
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
