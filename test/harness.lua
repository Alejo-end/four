-- harness.lua — what every offscreen harness shares: the assertions, the page
-- list exactly as the script declares it, and the summary that ends the run.
--
--   local T = dofile("test/harness.lua")
--   local ok, near = T.ok, T.near
--   ...
--   T.report("deck harness OK")

local H = { count = 0, fail = {} }

function H.ok(c, w)
  if c then H.count = H.count + 1 else H.fail[#H.fail + 1] = w end
end

function H.near(a, b, t, w)
  H.ok(type(a) == "number" and math.abs(a - b) <= t,
    string.format("%s (got %s, want %s +-%s)", w, tostring(a), tostring(b), tostring(t)))
end

-- the page names, in order, read out of the script's own `local PAGES = {...}`
-- (a hand-mirrored copy would drift and the renders would keep passing)
function H.pages(path)
  local names = {}
  local src = io.open(path or "four.lua"):read("a")
  for name in src:match("local PAGES = %{(.-)%}"):gmatch('"([%u%d]+)"') do
    names[#names + 1] = name
  end
  return names
end

-- go to a page the way a hand does: E1 hard left, then forward. Takes a page
-- NAME or an index; returns the index. Drives the script's global enc().
function H.goto_page(page)
  local i = page
  if type(page) == "string" then
    i = 1
    for k, v in ipairs(H.pages()) do if v == page then i = k end end
  end
  enc(1, -30)
  if i > 1 then enc(1, i - 1) end
  return i
end

-- a momentary param's press: up, then back down
function H.pulse(id) params:set(id, 1); params:set(id, 0) end

-- run a job to its end: a coroutine, or a function in a fresh one. Its error
-- is raised here. Returns how many resumes it took; nil runs nothing.
function H.finish(co)
  if not co then return 0 end
  if type(co) == "function" then co = coroutine.create(co) end
  local n = 0
  repeat
    local okr, err = coroutine.resume(co)
    if not okr then error(err) end
    n = n + 1
  until coroutine.status(co) == "dead"
  return n
end

-- write a PCM wav. `sample(i, c)` returns the INTEGER sample for frame i
-- (0-based) and channel c (1-based), at the file's bit depth (8-bit WAV is
-- unsigned, 0..255 centred on 128; every wider depth is signed).
function H.write_wav(path, sr, ch, bits, frames, sample)
  local bps = bits // 8
  local d = frames * ch * bps
  local f = assert(io.open(path, "wb"))
  f:write("RIFF", string.pack("<I4", 36 + d), "WAVE")
  f:write("fmt ", string.pack("<I4", 16), string.pack("<I2", 1), string.pack("<I2", ch),
    string.pack("<I4", sr), string.pack("<I4", sr * ch * bps),
    string.pack("<I2", ch * bps), string.pack("<I2", bits))
  f:write("data", string.pack("<I4", d))
  local code, b = bps == 1 and "<B" or ("<i" .. bps), {}
  for i = 0, frames - 1 do
    for c = 1, ch do b[#b + 1] = string.pack(code, sample(i, c)) end
  end
  f:write(table.concat(b))
  f:close()
end

-- the summary: the count, every failure by name, and a non-zero exit on any
function H.report(done_msg)
  -- an Exquis stand-in was attached (test/uisim/env.lua): whatever the harness
  -- did, every frame the driver sent it must be one the hardware accepts
  local X = rawget(_G, "FOUR_TEST_EXQUIS")
  if X then
    H.ok(#X.bad == 0, "every frame sent to the Exquis is well formed (" .. #X.bad
      .. " of " .. X.frames .. " are not; the first: " .. tostring(X.bad[1]) .. ")")
    if X.want then
      H.ok(X.first == X.want, "the Exquis that was there at the load starts in "
        .. X.want:upper() .. " (got " .. tostring(X.first) .. ")")
      H.ok(X.mirrors > 0, "the Exquis was held to the grid's frames")
      print("with an Exquis attached, " .. X.want:upper() .. ": " .. X.frames
        .. " frames sent to it, held to the grid over " .. X.mirrors .. " frames"
        .. (X.by_pad > 0 and (", " .. X.by_pad .. " grid presses made on its pads") or ""))
    end
  end
  print(string.format("\n%d assertions passed", H.count))
  if #H.fail > 0 then
    print(#H.fail .. " FAILED:")
    for _, f in ipairs(H.fail) do print("  x " .. f) end
    os.exit(1)
  end
  print(done_msg)
end

return H
