-- check.lua — every offline check in one command, with one verdict at the end.
--
--   lua tools/check.lua                 # from the repo root
--
-- What it runs, in order:
--   1. a syntax check of the script, the modules and the single-file build
--   2. the six harnesses (each prints its assertion count; test_control
--      also fails on a stale single-file build)
--   3. the render suite over the source AND the single-file build, all four
--      variants, compared byte for byte (the build must draw what the source
--      draws)
--
-- norns runs Lua 5.3. When a 5.3 interpreter is available it is used for all
-- of it, because a newer luac accepts syntax 5.3 rejects. Point LUA53 at a
-- 5.3 `lua` binary (its `luac` is taken from the same folder), or put
-- `lua5.3` / `luac5.3` on PATH. Without one, the checks run on `lua` and say
-- so. Build one in two minutes: download lua-5.3.6 from lua.org, `make
-- macosx` (or `make linux`), and set LUA53 to its src/lua.

local function sh(cmd)
  local ok = os.execute(cmd)
  return ok == true or ok == 0
end

local function have(cmd)
  return sh("command -v " .. cmd .. " >/dev/null 2>&1")
end

local LUA, LUAC, is53 = "lua", "luac", false
local env53 = os.getenv("LUA53")
if env53 and env53 ~= "" then
  LUA, LUAC, is53 = env53, env53:gsub("lua$", "luac"), true
elseif have("lua5.3") and have("luac5.3") then
  LUA, LUAC, is53 = "lua5.3", "luac5.3", true
end

local failed = {}
local function step(name, okv)
  print(string.format("%-46s %s", name, okv and "ok" or "FAILED"))
  if not okv then failed[#failed + 1] = name end
end

print(is53 and ("checking with Lua 5.3 (" .. LUA .. ")")
  or "checking with `lua` (no Lua 5.3 found: set LUA53 for the norns version)")

-- 1. syntax. Whether dist/ is a fresh build is test_control's check, run below.
step("syntax: script, modules, single-file build",
  sh(LUAC .. " -p mangler.lua lib/*.lua dist/mangler_single.lua"))

-- 2. the harnesses
for _, t in ipairs({ "test_control", "test_deck", "test_wav",
                     "test_launchpad", "test_purity", "test_screen" }) do
  step("harness: " .. t, sh(LUA .. " tools/" .. t .. ".lua >/dev/null 2>&1"))
end

-- 3. the renders: source and build, four variants each, byte-compared
local tmp = os.tmpname()
os.remove(tmp)
local src_dir, dist_dir = tmp .. "-src", tmp .. "-dist"
sh("mkdir -p " .. src_dir .. " " .. dist_dir)
local rendered = true
for _, v in ipairs({ "base", "empty", "grain", "filter" }) do
  rendered = rendered
    and sh(LUA .. " tools/uisim/render_pages.lua mangler.lua " .. src_dir .. " "
      .. v .. " " .. v .. " >/dev/null 2>&1")
    and sh(LUA .. " tools/uisim/render_pages.lua dist/mangler_single.lua "
      .. dist_dir .. " " .. v .. " " .. v .. " >/dev/null 2>&1")
end
step("render suite runs (source and build)", rendered)
local same = rendered and sh("diff -rq " .. src_dir .. " " .. dist_dir .. " >/dev/null")
local p = io.popen("ls " .. src_dir .. " | grep -c pgm")
local shots = p and tonumber(p:read("a")) or 0
if p then p:close() end
step(string.format("the build draws what the source draws (%d shots)", shots), same)
sh("rm -rf " .. src_dir .. " " .. dist_dir)

print("")
if #failed > 0 then
  print(#failed .. " check(s) FAILED: " .. table.concat(failed, ", "))
  os.exit(1)
end
print("all checks passed" .. (is53 and " (Lua 5.3)" or " (NOT on Lua 5.3)"))
