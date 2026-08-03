-- Static leak auditor for the AuctionatorFinder.lua file split.
--
-- When a section is peeled out of AuctionatorFinder.lua into its own file, any
-- symbol that was a FILE-LOCAL in the core file (e.g. the FT() localization
-- wrapper, the zc utility table, a gFdr_ state var) stops resolving in the new
-- file -- Lua file-locals do not cross files. In the client that former local
-- becomes an undefined GLOBAL: calling it (FT("...")) crashes; reading it
-- (zc.msg_atr) silently yields nil. Neither luac -p nor a mock-load test that
-- stubs every global will catch it, because the reference lives inside a
-- function body that only runs in-game.
--
-- This auditor is static: it lists AuctionatorFinder.lua's top-level locals,
-- then for each split file reports any it uses without defining locally (its
-- own local, a function parameter, or a for-loop variable all count as
-- defining/shadowing). A hit means "add a local for this, or share it through
-- addonTable.Finder". Exits non-zero if anything leaks.
--
-- Run:  lua5.1 tests/finder_split_leak_audit.lua

local DIR  = "Auctionator-Finder-Ascension/"
local CORE = DIR .. "AuctionatorFinder.lua"
-- every file split out of core; extend this as more slices land
local SPLITS = {
  DIR .. "AuctionatorFinderPriceDB.lua",
  DIR .. "AuctionatorFinderFullScan.lua",
  DIR .. "AuctionatorFinderOptions.lua",
}

local function read (p)
  local f = assert (io.open (p, "r"), "cannot open " .. p)
  local s = f:read ("*a"); f:close (); return s
end

-- Drop comments and string contents so identifiers inside them do not count.
local function strip (src)
  src = src:gsub ("%-%-%[%[.-%]%]", " ")   -- block comments
  src = src:gsub ("%-%-[^\n]*", " ")        -- line comments
  src = src:gsub ('"[^"\n]*"', '""')        -- double-quoted strings
  src = src:gsub ("'[^'\n]*'", "''")        -- single-quoted strings
  src = src:gsub ("%[%[.-%]%]", " ")        -- long strings
  return src
end

-- Top-level (column-0) locals declared in core.
local coreLocals = {}
for line in io.lines (CORE) do
  local body = line:match ("^local%s+(.*)")
  if body then
    body = body:gsub ("^function%s+", "")
    body = body:gsub ("%s*=.*$", "")   -- drop initializer
    body = body:gsub ("%(.*$", "")     -- drop function params
    for name in body:gmatch ("[A-Za-z_][A-Za-z0-9_]*") do coreLocals[name] = true end
  end
end

local function definedNames (code)
  local defined = {}
  for body in code:gmatch ("local%s+([^\n]*)") do
    body = body:gsub ("^function%s+", ""):gsub ("=.*$", "")
    for name in body:gmatch ("[A-Za-z_][A-Za-z0-9_]*") do defined[name] = true end
  end
  for params in code:gmatch ("function%s*[A-Za-z0-9_%.:]*%s*%(([^%)]*)%)") do
    for name in params:gmatch ("[A-Za-z_][A-Za-z0-9_]*") do defined[name] = true end
  end
  for vars in code:gmatch ("for%s+([A-Za-z_][A-Za-z0-9_,%s]*)%s+in%s") do
    for name in vars:gmatch ("[A-Za-z_][A-Za-z0-9_]*") do defined[name] = true end
  end
  for vars in code:gmatch ("for%s+([A-Za-z_][A-Za-z0-9_]*)%s*=") do
    defined[vars] = true
  end
  return defined
end

local failed = false
for _, path in ipairs (SPLITS) do
  local code    = strip (read (path))
  local defined = definedNames (code)
  local missing, seen = {}, {}
  for name in code:gmatch ("[A-Za-z_][A-Za-z0-9_]*") do
    if coreLocals[name] and not defined[name] and not seen[name] then
      seen[name] = true
      missing[#missing + 1] = name
    end
  end
  table.sort (missing)
  if #missing == 0 then
    print ("OK    " .. path .. "  (no undefined core-locals)")
  else
    failed = true
    print ("LEAK  " .. path)
    for _, n in ipairs (missing) do
      print ("        uses core file-local '" .. n .. "' without defining it")
    end
  end
end

if failed then
  print ("\nFAIL: fix by adding a local for each symbol, or share it via addonTable.Finder")
  os.exit (1)
end
print ("\nALL FINDER SPLIT LEAK CHECKS PASSED")
