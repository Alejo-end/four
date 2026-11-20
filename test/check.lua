-- check.lua — every offline check in one command, with one verdict at the end.
--
--   lua test/check.lua                 # from the repo root
--
-- What it runs, in order:
--   1. a syntax check of the script, the modules and the single-file build
--   2. the eight harnesses (each prints its assertion count; test_control
--      also fails on a stale single-file build)
--   3. the harnesses that run the script, again, with an Exquis attached: once
--      beside the grid (KEYS) and once in PADS, where every grid press that
--      the Exquis carries is made on its pads. The stand-in (test/uisim/env.lua)
--      checks every frame it is sent and holds its LEDs to the grid's.
--   4. the render suite over the source AND the single-file build, all five
--      variants, compared byte for byte (the build must draw what the source
--      draws), and the source again with an Exquis attached (the screen must
--      not change)
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

-- a plain run has no Exquis, whatever the caller's environment says
local PLAIN = "FOUR_EXQUIS= "

local failed = {}
local function step(name, okv)
  print(string.format("%-46s %s", name, okv and "ok" or "FAILED"))
  if not okv then failed[#failed + 1] = name end
end

print(is53 and ("checking with Lua 5.3 (" .. LUA .. ")")
  or "checking with `lua` (no Lua 5.3 found: set LUA53 for the norns version)")

-- 1. syntax. Whether dist/ is a fresh build is test_control's check, run below.
step("syntax: script, modules, single-file build",
  sh(LUAC .. " -p four.lua lib/*.lua dist/four_single.lua"))

-- 2. the harnesses
local HARNESSES = { "test_control", "test_deck", "test_wav",
                    "test_launchpad", "test_exquis", "test_purity", "test_screen",
                    "test_plugin" }
for _, t in ipairs(HARNESSES) do
  step("harness: " .. t, sh(PLAIN .. LUA .. " test/" .. t .. ".lua >/dev/null 2>&1"))
end

-- 3. with an Exquis attached. Only a harness that loads the script in the
-- offscreen norns sees it, and not one that plugs in its own (`exquis = false`).
-- Read from the harnesses themselves, so a new one joins without a list here.
local EX_MODES = { "keys", "pads" }
local with_exquis = {}
for _, t in ipairs(HARNESSES) do
  local f = assert(io.open("test/" .. t .. ".lua"))
  local src = f:read("a")
  f:close()
  local call = src:match("env%.install(%b{})")
  if call and not call:find("exquis%s*=%s*false") then with_exquis[#with_exquis + 1] = t end
end
step("harnesses that take an Exquis: " .. #with_exquis, #with_exquis > 0)
for _, mode in ipairs(EX_MODES) do
  for _, t in ipairs(with_exquis) do
    step("harness: " .. t .. ", Exquis in " .. mode:upper(),
      sh("FOUR_EXQUIS=" .. mode .. " " .. LUA .. " test/" .. t .. ".lua >/dev/null 2>&1"))
  end
end

-- 4. the renders: source and build, five variants each, byte-compared
local tmp = os.tmpname()
os.remove(tmp)
local src_dir, dist_dir = tmp .. "-src", tmp .. "-dist"
sh("mkdir -p " .. src_dir .. " " .. dist_dir)
for _, mode in ipairs(EX_MODES) do sh("mkdir -p " .. tmp .. "-" .. mode) end
local rendered, rendered_ex = true, true
for _, v in ipairs({ "base", "empty", "grain", "filter", "track2" }) do
  rendered = rendered
    and sh(PLAIN .. LUA .. " test/uisim/render_pages.lua four.lua " .. src_dir .. " "
      .. v .. " " .. v .. " >/dev/null 2>&1")
    and sh(PLAIN .. LUA .. " test/uisim/render_pages.lua dist/four_single.lua "
      .. dist_dir .. " " .. v .. " " .. v .. " >/dev/null 2>&1")
  for _, mode in ipairs(EX_MODES) do
    rendered_ex = rendered_ex
      and sh("FOUR_EXQUIS=" .. mode .. " " .. LUA .. " test/uisim/render_pages.lua four.lua "
        .. tmp .. "-" .. mode .. " " .. v .. " " .. v .. " >/dev/null 2>&1")
  end
end
step("render suite runs (source and build)", rendered)
local same = rendered and sh("diff -rq " .. src_dir .. " " .. dist_dir .. " >/dev/null")
local p = io.popen("ls " .. src_dir .. " | grep -c pgm")
local shots = p and tonumber(p:read("a")) or 0
if p then p:close() end
step(string.format("the build draws what the source draws (%d shots)", shots), same)
local same_ex = rendered and rendered_ex
for _, mode in ipairs(EX_MODES) do
  same_ex = same_ex and sh("diff -rq " .. src_dir .. " " .. tmp .. "-" .. mode .. " >/dev/null")
end
step("an attached Exquis leaves the screen as it is", same_ex)
sh("rm -rf " .. src_dir .. " " .. dist_dir)
for _, mode in ipairs(EX_MODES) do sh("rm -rf " .. tmp .. "-" .. mode) end

print("")
if #failed > 0 then
  print(#failed .. " check(s) FAILED: " .. table.concat(failed, ", "))
  os.exit(1)
end
print("all checks passed" .. (is53 and " (Lua 5.3)" or " (NOT on Lua 5.3)"))
