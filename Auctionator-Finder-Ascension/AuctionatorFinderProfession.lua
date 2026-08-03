-- FINDER: profession (trade skill) scanning ------------------------------------
--
-- This file owns everything the Finder learns from a profession window: the
-- crafted-goods recipe harvest, the recipe-tooltip fallback, and the per-item
-- craft-cost lookup the SELL tab's Crafted Goods Margin filter reads.  It was
-- lifted out of the main Auctionator.lua so the profession code lives in one
-- place -- both to keep the scan gentle (see the event frame at the bottom) and
-- to give future profession features (filter/sort the most profitable recipes)
-- a home to grow in.
--
-- The 3.3.5 client cannot be asked "what reagents craft item X"; that data is
-- only reachable while a profession window is open (GetTradeSkill* APIs).  So
-- we HARVEST it into AUCTIONATOR_CRAFT_RECIPES (account-wide) from two sources:
--
--   1. Profession windows (Atr_Craft_Harvest): every craftable item the player
--      can make.  Keyed by the produced item's ID, reagents by ID, with the
--      exact yield.  This is the reliable source.
--   2. Recipe ITEM tooltips (Atr_Craft_HarvestRecipeTooltip): when the player
--      views a plan/formula/recipe/pattern/schematic they haven't necessarily
--      learned, we read the created item from the recipe's name ("Pattern:
--      Frostweave Bag" -> "Frostweave Bag") and scrape the reagent line from
--      the tooltip.  Keyed by the created item's NAME, reagents by NAME, yield
--      assumed 1.  Best-effort (English tooltip format), fills coverage the
--      profession windows miss.
--
-- The Crafted Goods Margin filter then knows the craft cost of anything from
-- either source.  Coverage grows as professions are opened and recipes viewed.

local function Atr_Craft_DB()
    AUCTIONATOR_CRAFT_RECIPES = AUCTIONATOR_CRAFT_RECIPES or {};
    return AUCTIONATOR_CRAFT_RECIPES;
end

-- Walk the currently-open trade skill and store every recipe we can read.
-- Returns  stored, complete  where `complete` is false if any recipe row's item
-- link was still cold (data streaming in): the caller uses that to decide
-- whether this pass is final, so a cold-cache harvest is not mistaken for a
-- finished one and re-runs when the cache warms.
function Atr_Craft_Harvest()
    if (type(GetNumTradeSkills) ~= "function") then return 0, false; end
    local n = GetNumTradeSkills() or 0;
    if (n <= 0) then return 0, false; end

    local db = Atr_Craft_DB();
    local ItemID = (zc and zc.ItemIDfromLink) or nil;

    local stored, cold = 0, 0;
    for i = 1, n do
        local _, skillType = GetTradeSkillInfo(i);
        if (skillType and skillType ~= "header") then
            local madeLink = GetTradeSkillItemLink and GetTradeSkillItemLink(i) or nil;
            if (madeLink == nil) then
                cold = cold + 1;   -- recipe row present but its item data is still streaming
            else
                local madeID = ItemID and tonumber((ItemID(madeLink))) or nil;   -- extra parens: ItemID returns 3 values
                if (madeID) then
                    local made = 1;
                    if (GetTradeSkillNumMade) then
                        local lo = GetTradeSkillNumMade(i);
                        made = tonumber(lo) or 1;
                        if (made < 1) then made = 1; end
                    end

                    local reagents = {};
                    local numR = GetTradeSkillNumReagents and GetTradeSkillNumReagents(i) or 0;
                    for j = 1, numR do
                        local _, _, rcount = GetTradeSkillReagentInfo(i, j);
                        local rlink = GetTradeSkillReagentItemLink and GetTradeSkillReagentItemLink(i, j) or nil;
                        local rid   = rlink and ItemID and tonumber((ItemID(rlink))) or nil;   -- extra parens: ItemID returns 3 values
                        if (rid) then
                            table.insert(reagents, { id = rid, count = tonumber(rcount) or 1 });
                        end
                    end

                    if (#reagents > 0) then
                        db[madeID] = { made = made, reagents = reagents };
                        stored = stored + 1;
                    end
                end
            end
        end
    end

    return stored, (cold == 0);
end

-- Per-item cost, in copper, to buy the reagents and craft the item, or nil when
-- it isn't a harvested recipe or a reagent price is missing.  Looks up the
-- recipe by produced-item ID (profession-window source) first, then by name
-- (recipe-tooltip source).  Reagent price is Auctionator's auction price (the
-- price DB is name-keyed, so ID- and name-based reagents both resolve); when a
-- reagent has no auction price (e.g. it is vendor-bought) we fall back to its
-- vendor value as a rough floor.  If even that is unavailable (item not cached)
-- the total is unknown, so we return nil and the caller leaves it unfiltered.
function Atr_Craft_GetCraftCost(link, name)
    if (AUCTIONATOR_CRAFT_RECIPES == nil) then return nil; end

    local rec;

    local itemID;
    if (type(link) == "number") then
        itemID = link;
    elseif (link and zc and zc.ItemIDfromLink) then
        itemID = tonumber((zc.ItemIDfromLink(link)));   -- extra parens: ItemIDfromLink returns 3 values
    end
    if (itemID) then rec = AUCTIONATOR_CRAFT_RECIPES[itemID]; end

    if (rec == nil) then
        if (name == nil and link and type(link) ~= "number" and GetItemInfo) then
            name = GetItemInfo(link);
        end
        if (name) then rec = AUCTIONATOR_CRAFT_RECIPES[name]; end
    end

    if (rec == nil or rec.reagents == nil) then return nil; end

    local total = 0;
    for _, r in ipairs(rec.reagents) do
        local key = r.id or r.name;   -- ID from window harvest, name from tooltip harvest

        -- NPC-sold reagent (vial, thread, flux, ...): its real cost is the fixed
        -- NPC price, so use that and ignore whatever it's relisted for on the AH.
        local price = (r.id and Atr_GetNPCPrice) and tonumber(Atr_GetNPCPrice(r.id)) or nil;

        if (price == nil or price <= 0) then
            price = (key and Atr_GetAuctionPrice) and tonumber(Atr_GetAuctionPrice(key)) or nil;
        end
        if (price == nil or price <= 0) then
            price = (key and Atr_GetSellValue) and tonumber(Atr_GetSellValue(key)) or nil;   -- vendor-value floor
        end
        if (price == nil or price <= 0) then
            return nil;   -- a reagent we can't price -> craft cost unknown
        end
        total = total + (price * (r.count or 1));
    end

    local made = rec.made or 1;
    if (made < 1) then made = 1; end
    return math.floor(total / made);
end

-- Split a tooltip line into reagent {name, count} pairs, or nil if the line is
-- not a reagent list.  Recipe tooltips end with a line like
-- "Frostweave Cloth (4), Infinite Dust (1)"; every comma-segment is
-- "<name> (<count>)".  The "Requires <Profession> (<skill>)" line also carries
-- a parenthesised number, so lines starting with "Requires"/"Use:" are rejected.
local function Atr_Craft_ParseReagentLine(text)
    if (type(text) ~= "string" or text == "") then return nil; end
    if (text:find("^Requires") or text:find("^Use:")) then return nil; end

    local reagents = {};
    for seg in string.gmatch(text .. ",", "%s*(.-)%s*,") do
        local rname, rcount = seg:match("^(.-)%s*%((%d+)%)$");
        if (not rname or rname == "") then return nil; end   -- a non-reagent segment: not a reagent line
        table.insert(reagents, { name = rname, count = tonumber(rcount) or 1 });
    end
    if (#reagents == 0) then return nil; end
    return reagents;
end

-- Harvest a recipe from the tooltip currently showing for a Recipe-class item.
-- `itemName` is the recipe item's name ("Pattern: Frostweave Bag"); the created
-- item's name is whatever follows the "<Prefix>: " (that is the item the player
-- would have in their bags).  The reagent list is scraped from the tooltip's
-- bottom line.  Yield is not shown on recipe tooltips, so it is assumed 1 --
-- for multi-yield recipes this overestimates per-item cost (holds more), which
-- is the safe direction.  Best-effort, English tooltip format.
function Atr_Craft_HarvestRecipeTooltip(tip, itemName)
    if (tip == nil or type(itemName) ~= "string") then return; end

    local created = itemName:match("^%a+:%s+(.+)$");   -- strip Plans:/Pattern:/Recipe:/Formula:/...
    if (created == nil or created == "") then return; end

    local getName = tip.GetName and tip:GetName() or nil;
    if (getName == nil) then return; end
    local n = (tip.NumLines and tip:NumLines()) or 0;

    local reagents;
    for i = 2, n do
        local fs = _G[getName .. "TextLeft" .. i];
        local txt = fs and fs.GetText and fs:GetText() or nil;
        local parsed = Atr_Craft_ParseReagentLine(txt);
        if (parsed) then reagents = parsed; end   -- keep the last match (reagents sit at the bottom)
    end

    if (reagents) then
        local db = Atr_Craft_DB();
        -- Don't shadow a precise profession-window entry: only the name key is
        -- written here, and the cost lookup prefers the ID key.
        db[created] = { made = 1, reagents = reagents, byTooltip = true };
    end
end

-- A stable fingerprint of the open profession: its name plus its recipe count.
-- Same profession, same count -> same list, so once it has been harvested with
-- a warm cache we never need to walk it again this session.  Learning a new
-- recipe changes the count and re-arms one harvest.  Returns nil when no
-- profession is really open (GetTradeSkillLine reports "UNKNOWN" then), which
-- keeps the throttle from ever skipping a genuine window.
local function Atr_Craft_Signature()
    if (type(GetTradeSkillLine) ~= "function") then return nil; end
    local prof = GetTradeSkillLine();
    if (prof == nil or prof == "" or prof == "UNKNOWN") then return nil; end
    local n = (type(GetNumTradeSkills) == "function") and (GetNumTradeSkills() or 0) or 0;
    if (n <= 0) then return nil; end
    return prof .. "#" .. n;
end

-- The guarded harvest the timer actually calls: skip entirely if this exact
-- profession list was already fully harvested this session, otherwise harvest
-- and record it -- but only mark it done when the cache was warm, so a harvest
-- taken mid-stream is retried on the next quiet update instead of locked in.
local function Atr_Craft_HarvestGuarded()
    local sig = Atr_Craft_Signature();
    if (sig and type(Fdr_ScanThrottle_Seen) == "function" and Fdr_ScanThrottle_Seen(sig)) then
        return;   -- already learned this profession this session
    end

    local ok, _, complete = pcall(Atr_Craft_Harvest);   -- best-effort: a harvest error must never break the UI
    if (ok and complete and sig and type(Fdr_ScanThrottle_Mark) == "function") then
        Fdr_ScanThrottle_Mark(sig);
    end
end

-- Harvest whenever a profession window opens or refreshes.  A dedicated frame
-- keeps this off the core event dispatcher.
--
-- TRADE_SKILL_UPDATE does NOT fire once per open: Blizzard's own UI refires it
-- for every recipe whose item data is still streaming in from the server, so a
-- single profession-window open produces a BURST of the event -- a full storm
-- when the item cache is cold (e.g. right after a client repair wipes it).
-- Re-harvesting the entire skill list on every one of those events froze the
-- client on large Ascension professions.  So we DEBOUNCE: each event just arms
-- a short timer, and the harvest runs ONCE, a beat after the updates go quiet.
-- On top of that the harvest is GUARDED by the session throttle, so re-opening
-- a profession already learned this session costs only a signature compare, not
-- another walk.  The produced-item IDs come straight from the recipe links, so
-- one late pass reads exactly the same data the per-event passes would have.
if (type(CreateFrame) == "function") then
    local f = CreateFrame("Frame");
    f:RegisterEvent("TRADE_SKILL_SHOW");
    f:RegisterEvent("TRADE_SKILL_UPDATE");

    local DELAY   = 0.5;     -- seconds of quiet before harvesting
    local elapsed = 0;

    f:Hide();                -- OnUpdate only ticks while shown; stay idle until armed

    f:SetScript("OnEvent", function(self)
        elapsed = 0;
        self:Show();         -- (re)arm the timer; a fresh event pushes it back out
    end);

    f:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + (dt or 0);
        if (elapsed >= DELAY) then
            elapsed = 0;
            self:Hide();     -- stop ticking before harvesting (idempotent, one-shot)
            Atr_Craft_HarvestGuarded();
        end
    end);
end
