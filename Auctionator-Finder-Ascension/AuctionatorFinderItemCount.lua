-- FINDER: item quantity + bag locations on tooltips ---------------------------
--
-- Adds a "Qty: N" line to item tooltips telling you how many of that item you
-- own, and -- when a modifier is held -- WHERE they are (which character, and
-- whether the stack is in bags or the bank).  Kept in its own file so the
-- tooltip/pricing code in AuctionatorHints.lua does not grow another feature.
--
-- Why a cache, and why account-wide.  The client can only READ a container's
-- contents while that container's window is open: away from a bank, the bank
-- slots read back nil.  So we cannot ask "how many do I own" on the fly -- we
-- have to REMEMBER what each container held the last time we saw it.  Each
-- character records its own bags (always readable, kept fresh off BAG_UPDATE)
-- and its bank (snapshotted whenever the bank frame is open) into an
-- account-wide saved variable, so a tooltip can total the item across every
-- one of your characters from anywhere.
--
--   AUCTIONATOR_ITEM_LOCATIONS = {
--       ["Realm-Charname"] = {
--           name=, realm=, class=, faction=, updated=,
--           bags = { [itemID] = count },   -- backpack (bags 0..NUM_BAG_SLOTS)
--           bank = { [itemID] = count },   -- character bank (-1 + bank bags)
--       },
--   }
--
-- PHASE 1 covers the backpack and the character bank.  Ascension's web-shop
-- "personal" / "realm" banks and the guild bank (all of which render under the
-- guild-bank frame) come in a follow-up once their API surface is confirmed --
-- see Atr_ItemCount_ProbeGuildBank below, a diagnostic for exactly that.

local addonName, addonTable = ...;
local zc = addonTable and addonTable.zc or _G.zc;

-- Visibility modes shared by both dropdowns, matching AUCTIONATOR_DE_DETAILS_TIPS:
--   1 = when SHIFT held, 2 = when CTRL held, 3 = when ALT held, 4 = never, 5 = always
local function ModeVisible (mode)
	if (mode == 5) then return true;  end
	if (mode == 4) then return false; end
	if (mode == 1) then return IsShiftKeyDown();   end
	if (mode == 2) then return IsControlKeyDown(); end
	if (mode == 3) then return IsAltKeyDown();     end
	return true;		-- unknown/unset -> visible, never hide silently
end

-----------------------------------------
-- Cache: keys, structure, scanning

local gBankOpen = false;		-- true only between BANKFRAME_OPENED and _CLOSED

local function CharKey ()
	local name  = UnitName ("player") or "?";
	local realm = GetRealmName () or "";
	return realm.."-"..name, name, realm;
end

local function EnsureDB ()
	if (type (AUCTIONATOR_ITEM_LOCATIONS) ~= "table") then
		AUCTIONATOR_ITEM_LOCATIONS = {};
	end
	return AUCTIONATOR_ITEM_LOCATIONS;
end

local function EnsureChar ()
	local db = EnsureDB ();
	local key, name, realm = CharKey ();
	local e = db[key];
	if (type (e) ~= "table") then e = {}; db[key] = e; end
	e.name  = name;
	e.realm = realm;
	local _, class = UnitClass ("player");
	e.class   = class;
	e.faction = UnitFactionGroup ("player");
	if (type (e.bags) ~= "table") then e.bags = {}; end
	if (type (e.bank) ~= "table") then e.bank = {}; end
	return e;
end

-- The backpack: bag 0 plus the four (NUM_BAG_SLOTS) equipped bags.
local function BackpackBags ()
	local t = {};
	for b = 0, (NUM_BAG_SLOTS or 4) do t[#t+1] = b; end
	return t;
end

-- The character bank: the 28-slot base container (BANK_CONTAINER = -1) plus the
-- purchased bank bags (NUM_BANKBAGSLOTS of them, sitting just past the backpack).
local function BankBags ()
	local t = { -1 };		-- BANK_CONTAINER
	local first = (NUM_BAG_SLOTS or 4) + 1;
	local last  = (NUM_BAG_SLOTS or 4) + (NUM_BANKBAGSLOTS or 7);
	for b = first, last do t[#t+1] = b; end
	return t;
end

-- Walk a list of container ids, returning a fresh { [itemID] = count } map.
local function ScanContainers (bagList)
	local counts = {};
	for _, bag in ipairs (bagList) do
		local slots = (GetContainerNumSlots and GetContainerNumSlots (bag)) or 0;
		for slot = 1, slots do
			local link = GetContainerItemLink (bag, slot);
			if (link) then
				local id = zc and zc.ItemIDfromLink (link);
				id = tonumber (id);
				if (id) then
					local _, cnt = GetContainerItemInfo (bag, slot);
					counts[id] = (counts[id] or 0) + (tonumber (cnt) or 1);
				end
			end
		end
	end
	return counts;
end

function Atr_ItemCount_ScanBags ()
	local e = EnsureChar ();
	e.bags    = ScanContainers (BackpackBags ());
	e.updated = time ();
end

function Atr_ItemCount_ScanBank ()
	if (not gBankOpen) then return; end		-- bank slots read nil when the window is shut
	local e = EnsureChar ();
	e.bank    = ScanContainers (BankBags ());
	e.updated = time ();
end

-----------------------------------------
-- Query + rendering

-- Total the item across every cached character, returning the grand total and a
-- per-character breakdown sorted current-character-first, then largest holding.
function Atr_ItemCount_Query (itemID)
	itemID = tonumber (itemID);
	if (not itemID) then return 0, {}; end

	local db     = EnsureDB ();
	local curKey = CharKey ();
	local total  = 0;
	local list   = {};

	for key, e in pairs (db) do
		if (type (e) == "table") then
			local b = (type (e.bags) == "table" and e.bags[itemID]) or 0;
			local k = (type (e.bank) == "table" and e.bank[itemID]) or 0;
			if (b + k > 0) then
				total = total + b + k;
				list[#list+1] = {
					name = e.name or key, realm = e.realm, class = e.class,
					bags = b, bank = k, isCurrent = (key == curKey),
				};
			end
		end
	end

	table.sort (list, function (a, c)
		if (a.isCurrent ~= c.isCurrent) then return a.isCurrent; end
		local at, ct = a.bags + a.bank, c.bags + c.bank;
		if (at ~= ct) then return at > ct; end
		return (a.name or "") < (c.name or "");
	end);

	return total, list;
end

-- Class-coloured character name for the location lines.
local function ColorName (c)
	local name = c.name or "?";
	if (c.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[c.class]) then
		local col = RAID_CLASS_COLORS[c.class];
		return string.format ("|cff%02x%02x%02x%s|r",
			(col.r or 1) * 255, (col.g or 1) * 255, (col.b or 1) * 255, name);
	end
	return "|cFFFFFFFF"..name.."|r";
end

-- Public entry point, called once from ShowTipWithPricing.  Adds nothing unless
-- the quantity mode is visible and the item is actually held somewhere.
function Atr_ItemCount_AddToTip (tip, itemID)
	if (tip == nil or itemID == nil) then return; end
	if (not ModeVisible (AUCTIONATOR_QTY_TIPS or 5)) then return; end

	local total, list = Atr_ItemCount_Query (itemID);
	if (total <= 0) then return; end

	tip:AddDoubleLine (ZT ("Qty"), "|cFFFFFFFF"..total.."|r");

	local locMode = AUCTIONATOR_QTY_LOC_TIPS or 3;
	if (ModeVisible (locMode)) then
		for _, c in ipairs (list) do
			local parts = {};
			if (c.bags and c.bags > 0) then parts[#parts+1] = c.bags.." "..ZT ("bags"); end
			if (c.bank and c.bank > 0) then parts[#parts+1] = c.bank.." "..ZT ("bank"); end
			tip:AddDoubleLine ("  "..ColorName (c), "|cFFCCCCCC"..table.concat (parts, ", ").."|r");
		end
	elseif (locMode == 1 or locMode == 2 or locMode == 3) then
		-- Faint breadcrumb so the hidden locations are discoverable.
		local keyName = (locMode == 1 and "SHIFT") or (locMode == 2 and "CTRL") or "ALT";
		tip:AddLine ("|cFF808080"..string.format (ZT ("Hold <%s> for locations"), keyName).."|r");
	end

	tip:Show ();
end

-----------------------------------------
-- Diagnostic (Phase 2 groundwork)
--
-- Ascension's personal/realm/guild banks all open under the guild-bank frame,
-- but nothing here tells a personal bank from a realm bank from a real guild
-- bank.  Run this with a web-shop bank (or the guild bank) OPEN to dump the
-- signals we could key off:  /run Atr_ItemCount_ProbeGuildBank()

function Atr_ItemCount_ProbeGuildBank ()
	local out = DEFAULT_CHAT_FRAME;
	local function p (s) if (out) then out:AddMessage ("|cff44ddffAtrItemCount|r "..tostring (s)); end end

	p ("--- guild-bank-family probe ---");
	p ("IsInGuild = "..tostring (IsInGuild and IsInGuild ()));
	p ("GetGuildInfo(player) = "..tostring (GetGuildInfo and GetGuildInfo ("player")));

	local title = _G["GuildBankFrameTitleText"];
	p ("frame title = "..tostring (title and title.GetText and title:GetText ()));

	local nTabs = GetNumGuildBankTabs and GetNumGuildBankTabs () or 0;
	p ("GetNumGuildBankTabs = "..tostring (nTabs));
	p ("GetCurrentGuildBankTab = "..tostring (GetCurrentGuildBankTab and GetCurrentGuildBankTab ()));

	for t = 1, nTabs do
		local name, icon, view, deposit, withdraw = GetGuildBankTabInfo (t);
		p (string.format ("  tab %d: name=%s icon=%s canView=%s",
			t, tostring (name), tostring (icon), tostring (view)));
	end
end

-- Quick sanity dump of what the cache currently holds:  /run Atr_ItemCount_Dump()
function Atr_ItemCount_Dump ()
	local out = DEFAULT_CHAT_FRAME;
	local function p (s) if (out) then out:AddMessage ("|cff44ddffAtrItemCount|r "..tostring (s)); end end
	local db = EnsureDB ();
	local nChars = 0;
	for key, e in pairs (db) do
		nChars = nChars + 1;
		local nb, nk = 0, 0;
		for _ in pairs (e.bags or {}) do nb = nb + 1; end
		for _ in pairs (e.bank or {}) do nk = nk + 1; end
		p (string.format ("%s: %d bag-stacks, %d bank-stacks", key, nb, nk));
	end
	p ("cached characters: "..nChars.."   bankOpen="..tostring (gBankOpen));
end

-----------------------------------------
-- Event wiring: keep the cache fresh

if (type (CreateFrame) == "function") then

	local f = CreateFrame ("Frame", "Atr_Finder_ItemCountScan", UIParent);

	f:RegisterEvent ("PLAYER_LOGIN");
	f:RegisterEvent ("PLAYER_ENTERING_WORLD");
	f:RegisterEvent ("BAG_UPDATE");
	f:RegisterEvent ("BANKFRAME_OPENED");
	f:RegisterEvent ("BANKFRAME_CLOSED");
	f:RegisterEvent ("PLAYERBANKSLOTS_CHANGED");
	f:RegisterEvent ("PLAYERBANKBAGSLOTS_CHANGED");

	local DELAY   = 0.4;		-- debounce the BAG_UPDATE / bank-slot storms
	local elapsed = 0;
	local bagsDirty, bankDirty = false, false;

	f:Hide ();				-- OnUpdate only ticks while shown; idle until armed

	f:SetScript ("OnEvent", function (self, event)
		if (event == "BANKFRAME_OPENED") then
			gBankOpen = true; bankDirty = true; bagsDirty = true;
		elseif (event == "BANKFRAME_CLOSED") then
			gBankOpen = false;		-- last good snapshot stays in the saved var
		elseif (event == "PLAYERBANKSLOTS_CHANGED" or event == "PLAYERBANKBAGSLOTS_CHANGED") then
			if (gBankOpen) then bankDirty = true; end
		elseif (event == "BAG_UPDATE") then
			bagsDirty = true;
			if (gBankOpen) then bankDirty = true; end		-- bank bags report through BAG_UPDATE too
		else		-- PLAYER_LOGIN / PLAYER_ENTERING_WORLD
			bagsDirty = true;
		end
		elapsed = 0;
		self:Show ();
	end);

	f:SetScript ("OnUpdate", function (self, dt)
		elapsed = elapsed + (dt or 0);
		if (elapsed >= DELAY) then
			elapsed = 0;
			self:Hide ();		-- one-shot: stop ticking before scanning
			if (bagsDirty) then bagsDirty = false; pcall (Atr_ItemCount_ScanBags); end
			if (bankDirty) then bankDirty = false; pcall (Atr_ItemCount_ScanBank); end
		end
	end);
end
