-- mplugin: four installs its own plugin.
--
-- The FourStretch plugin (ugen/: the stretch voices, THE ROOM, THE BUCKET
-- BRIGADE, THE CLOUD) is a binary for one kind of machine. The repo ships one
-- built on a norns, in ignore/plugins/<what `uname -m` prints>/ (norns
-- compiles nothing under a folder named ignore; ugen/build_norns.sh builds it
-- and puts it there).
--
-- lib/install_plugin.sh holds the rule: it copies the shipped .so into the
-- user Extensions folder when none is there, or when the shipped one is newer
-- with other bytes. The engine class runs it while sclang starts, before the
-- server boots, so the RESTART after `;install` already brings the plugin in.
-- This runs the same script when four loads, as a fallback: when it does
-- install (the startup could not, or the repo was updated without a restart),
-- four says SYSTEM > RESTART once, on screen and in maiden.
--
-- The script copies that .so only. Never a class file: lib/FourStretch.sc is
-- the only copy, and a second copy of a class hangs every norns script on
-- LOADING. It writes nothing outside Extensions/FourStretch/, so a separately
-- installed mi-UGens stays as it is. scsynth loads its plugins only when it
-- boots, so a new binary waits for the RESTART; until then the engine keeps
-- to its stock voices (Engine_Four.bootPlug). With no binary for this
-- machine it does nothing and says nothing: four plays its stock voices.

local M = {}

local SERVERS = { "/usr/local/bin/scsynth", "/usr/bin/scsynth" }

-- a path in single quotes, for the shell
local function q(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Installs the shipped plugin when it is missing or out of date. Returns what
-- the script did: "installed", "current" (what is installed stays), "none"
-- (nothing shipped for this machine), "foreign" (the shipped binary is not for
-- this scsynth), "failed", or "unknown" (not on a norns). `o` replaces what it
-- would ask the system, for the tests: home, dir (the script folder), arch,
-- servers (paths to try for scsynth), script (the path of install_plugin.sh).
function M.check(o)
  o = o or {}
  local cap = util and util.os_capture
  local home = o.home or (_path and _path.home) or os.getenv("HOME")
  local dir = o.dir or (norns and norns.state and norns.state.path)
  local arch = o.arch or (cap and cap("uname -m"))
  if not (home and dir and arch) then return "unknown" end
  if not arch:match("^[%w_]+$") then return "unknown" end
  if dir:sub(-1) ~= "/" then dir = dir .. "/" end
  local cmd = { "sh", q(o.script or (dir .. "lib/install_plugin.sh")), q(home), q(dir), q(arch) }
  for _, p in ipairs(o.servers or SERVERS) do cmd[#cmd + 1] = q(p) end
  local p = io.popen(table.concat(cmd, " ") .. " 2>/dev/null")
  local said = p and p:read("a") or ""
  if p then p:close() end
  local word = said:match("^%s*(%a+)%s*$") or "failed"
  if word == "installed" then
    print("four: installed the FourStretch plugin for " .. arch .. " into " .. home
      .. "/.local/share/SuperCollider/Extensions/FourStretch. Do SYSTEM > RESTART to hear it."
      .. " Until then four plays its stock voices.")
  elseif word == "failed" then
    print("four: could not install the FourStretch plugin (lib/install_plugin.sh)")
  end
  return word
end

return M
