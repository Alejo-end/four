-- mplugin: four installs its own plugin.
--
-- The FourStretch plugin (ugen/: the stretch voices, THE ROOM, THE BUCKET
-- BRIGADE, THE CLOUD) is a binary for one kind of machine. The repo can ship
-- one built on a norns, in ignore/plugins/<what `uname -m` prints>/ (norns
-- compiles nothing under a folder named ignore; ugen/build_norns.sh builds it
-- and puts it there). At init, when the user Extensions folder has no
-- FourStretch.so, or has an older one with other bytes, this copies the
-- shipped one there and says SYSTEM > RESTART once, on screen and in maiden.
--
-- It copies that .so only. Never a class file: lib/FourStretch.sc is the only
-- copy, and a second copy of a class hangs every norns script on LOADING. It
-- writes nothing outside Extensions/FourStretch/, so a separately installed
-- mi-UGens stays as it is. scsynth loads its plugins only when it boots, so
-- a new binary waits for the RESTART; until then the engine keeps to its
-- stock voices (Engine_Four.bootPlug). With no binary for this machine it
-- does nothing and says nothing: four plays its stock voices, as before.

local M = {}

local NAME = "FourStretch.so"
local SERVERS = { "/usr/local/bin/scsynth", "/usr/bin/scsynth" }

-- a path in single quotes, for the shell
local function q(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function sh(cmd)
  local ok = os.execute(cmd)
  return ok == true or ok == 0
end

-- the ELF class (32 or 64 bit) and machine of a binary, as one string; nil
-- when the file is not an ELF binary
local function elf(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local h = f:read(20)
  f:close()
  if not h or #h < 20 or h:sub(1, 4) ~= "\127ELF" then return nil end
  return h:byte(5) .. "/" .. (h:byte(19) + 256 * h:byte(20))
end

-- Installs the shipped plugin when it is missing or out of date. Returns what
-- it did: "installed", "current" (what is installed stays), "none" (nothing
-- shipped for this machine), "foreign" (the shipped binary is not for this
-- scsynth), "failed", or "unknown" (not on a norns). `o` replaces what it
-- would ask the system, for the tests: home, dir (the script folder, with its
-- last slash), arch, servers (paths to try for scsynth).
function M.check(o)
  o = o or {}
  local cap = util and util.os_capture
  local home = o.home or (_path and _path.home) or os.getenv("HOME")
  local dir = o.dir or (norns and norns.state and norns.state.path)
  local arch = o.arch or (cap and cap("uname -m"))
  if not (home and dir and arch and util and util.file_exists) then return "unknown" end
  if not arch:match("^[%w_]+$") then return "unknown" end
  if dir:sub(-1) ~= "/" then dir = dir .. "/" end
  local src = dir .. "ignore/plugins/" .. arch .. "/" .. NAME
  if not util.file_exists(src) then return "none" end
  -- the binary must suit the server that would load it: the same ELF class
  -- and machine as scsynth. (A 64-bit kernel under a 32-bit system says
  -- aarch64 to uname, and still needs a 32-bit binary.)
  for _, p in ipairs(o.servers or SERVERS) do
    local want = util.file_exists(p) and elf(p)
    if want then
      if elf(src) ~= want then return "foreign" end
      break
    end
  end
  local ext = home .. "/.local/share/SuperCollider/Extensions/FourStretch"
  local dst = ext .. "/" .. NAME
  if util.file_exists(dst) and (not sh("[ " .. q(src) .. " -nt " .. q(dst) .. " ]")
      or sh("cmp -s " .. q(src) .. " " .. q(dst))) then
    return "current"
  end
  -- beside it first, then renamed over it: a running scsynth has the old file
  -- mapped, and writing into that file in place could crash it. (scsynth
  -- loads only files that end in .so, so the .tmp is never loaded.)
  local tmp = dst .. ".tmp"
  if not (sh("mkdir -p " .. q(ext)) and sh("cp " .. q(src) .. " " .. q(tmp))
      and sh("mv -f " .. q(tmp) .. " " .. q(dst))) then
    os.remove(tmp)
    print("four: could not install the FourStretch plugin into " .. ext)
    return "failed"
  end
  print("four: installed the FourStretch plugin for " .. arch .. " into " .. ext
    .. ". Do SYSTEM > RESTART to hear it. Until then four plays its stock voices.")
  return "installed"
end

return M
