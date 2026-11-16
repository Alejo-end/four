-- test_plugin.lua: the plugin installer (lib/mplugin.lua and the script it runs,
-- lib/install_plugin.sh), over real files in a scratch folder, with the real shell. No norns: the home folder, the
-- script folder, the machine and scsynth are handed in.
--
--   lua test/test_plugin.lua        # from the repo root
--
-- The cases: nothing shipped, shipped and not installed, already installed,
-- a newer shipped binary, a newer installed one, a binary for another
-- machine, another arch, no norns. And always: only the .so is written, never
-- a class file, and a separately installed mi-UGens is not touched.

local T = dofile("test/harness.lua")
local ok = T.ok

util = { file_exists = function(p)
  local f = io.open(p, "rb")
  if f then f:close() end
  return f ~= nil
end }
local P = dofile("lib/mplugin.lua")

local function sh(cmd)
  local r = os.execute(cmd)
  return r == true or r == 0
end
local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function read(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end
local function write(p, s)
  sh("mkdir -p " .. q(p:match("^(.*)/")))
  local f = assert(io.open(p, "wb"))
  f:write(s)
  f:close()
end
-- an ELF header: class 1 (32 bit) or 2 (64 bit), machine 40 (ARM) or 183
-- (AArch64), then a body that tells two builds apart
local function elf(class, machine, body)
  return "\127ELF" .. string.char(class, 1, 1) .. string.rep("\0", 9)
    .. string.char(3, 0, machine % 256, machine // 256) .. body
end
local function files(dir)
  local p = io.popen("cd " .. q(dir) .. " 2>/dev/null && find . -type f | sort")
  local s = p:read("a")
  p:close()
  return s
end

-- the home folder has a quote in its name: every path goes to the shell quoted
local TMP = os.tmpname() .. "-plugin"
local HOME = TMP .. "/ho'me"
local DIR = TMP .. "/code/four/"
local SERVER = TMP .. "/bin/scsynth"
local EXT = HOME .. "/.local/share/SuperCollider/Extensions"
local SRC = DIR .. "ignore/plugins/armv7l/FourStretch.so"
local DST = EXT .. "/FourStretch/FourStretch.so"
local MI = EXT .. "/mi-UGens/MiClouds.so"
sh("rm -rf " .. q(TMP))
write(SERVER, elf(1, 40, "scsynth"))
write(MI, "mi-ugens, someone else's")
sh("touch -t 202001010000 " .. q(MI))
local REF = TMP .. "/ref"
write(REF, "")
sh("touch -t 202001010000 " .. q(REF))
local mi_before = files(EXT .. "/mi-UGens") .. read(MI)
local SCRIPT = "lib/install_plugin.sh"
local O = { home = HOME, dir = DIR, arch = "armv7l", servers = { TMP .. "/none", SERVER }, script = SCRIPT }

-- nothing shipped for this machine: nothing happens
ok(P.check(O) == "none", "nothing shipped: says none")
ok(not util.file_exists(DST), "nothing shipped: nothing installed")

-- shipped and not installed: installed, the .so alone
write(SRC, elf(1, 40, "build one"))
ok(P.check(O) == "installed", "shipped, not installed: says installed")
ok(read(DST) == read(SRC), "shipped, not installed: the same bytes installed")
ok(files(EXT .. "/FourStretch") == "./FourStretch.so\n",
  "the plugin folder holds the .so alone, no class file, no .tmp left")

-- already installed: stays
ok(P.check(O) == "current", "installed: says current")

-- the same bytes shipped again, newer by the clock (a fresh checkout): stays
sh("touch -t 203001010000 " .. q(SRC))
ok(P.check(O) == "current", "the same bytes, newer: says current")

-- a newer shipped build: replaces the installed one
write(SRC, elf(1, 40, "build two"))
sh("touch -t 203101010000 " .. q(SRC))
ok(P.check(O) == "installed", "a newer shipped build: says installed")
ok(read(DST) == read(SRC), "a newer shipped build: its bytes installed")

-- an installed build newer than the shipped one: stays
write(DST, elf(1, 40, "built by hand"))
sh("touch -t 203201010000 " .. q(DST))
ok(P.check(O) == "current", "a newer installed build: says current")
ok(read(DST):find("built by hand", 1, true) ~= nil, "a newer installed build: kept")

-- a binary for another machine in this machine's folder: not installed
sh("rm -rf " .. q(EXT .. "/FourStretch"))
write(SRC, elf(2, 183, "aarch64 build"))
ok(P.check(O) == "foreign", "a 64-bit binary for a 32-bit scsynth: says foreign")
ok(not util.file_exists(DST), "a 64-bit binary for a 32-bit scsynth: nothing installed")

-- another arch: its own folder is empty, nothing happens
write(SRC, elf(1, 40, "build three"))
local O2 = { home = HOME, dir = DIR, arch = "aarch64", servers = { SERVER }, script = SCRIPT }
ok(P.check(O2) == "none", "another arch, nothing shipped for it: says none")
ok(not util.file_exists(DST), "another arch: nothing installed")

-- no scsynth found: the folder name alone decides
local O3 = { home = HOME, dir = DIR, arch = "armv7l", servers = { TMP .. "/none" }, script = SCRIPT }
ok(P.check(O3) == "installed", "no scsynth to compare with: installs by the folder")

-- not on a norns (no script folder, no uname), or a strange machine name
ok(P.check({ home = HOME }) == "unknown", "no script folder: says unknown")
ok(P.check({ home = HOME, dir = DIR, arch = "x86_64; rm -rf /" }) == "unknown",
  "a machine name that is not a word: says unknown")

-- the startup's call (Engine_Four.installPlug): no arch given, so the script asks
-- uname, and off Linux it does nothing. On the Mac bench it must never write.
local function run(args)
  local p = io.popen("sh " .. SCRIPT .. " " .. args .. " 2>&1")
  local s = p:read("a")
  p:close()
  return s
end
sh("rm -rf " .. q(EXT .. "/FourStretch"))
local onlinux = run("x x ''") ~= "unknown\n"
local startup = run(q(HOME) .. " " .. q(DIR) .. " '' " .. q(SERVER))
if onlinux then
  ok(startup ~= "unknown\n", "startup call on Linux: asks uname and acts")
else
  ok(startup == "unknown\n", "startup call off Linux: says unknown")
  ok(not util.file_exists(DST), "startup call off Linux: nothing installed")
end
ok(run("") == "unknown\n" and run(q(HOME) .. " " .. q(DIR)) == "unknown\n",
  "too few arguments: says unknown")

-- mi-UGens never moved
ok(files(EXT .. "/mi-UGens") .. read(MI) == mi_before, "mi-UGens: untouched")
ok(not sh("[ " .. q(MI) .. " -nt " .. q(REF) .. " ]") and not sh("[ " .. q(REF) .. " -nt " .. q(MI) .. " ]"),
  "mi-UGens: its time untouched")
local p = io.popen("find " .. q(TMP) .. " -name '*.sc' | wc -l")
ok(tonumber(p:read("a")) == 0, "no class file anywhere")
p:close()

sh("rm -rf " .. q(TMP))
T.report("plugin harness OK")
