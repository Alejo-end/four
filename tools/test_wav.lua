-- test_wav.lua — offline harness for lib/mpages.lua's wav layer.
--
-- The thing no eye can check: the 44.1k -> 48k conversion that stops a loaded
-- sample playing a semitone sharp. A rate error IS a pitch error, so these
-- assert the VALUE at a wall-clock position, not just the frame count.
--
--   lua tools/test_wav.lua        # from the repo root
--
-- It lifts the real functions out of lib/mpages.lua (no copies) and drives
-- them over real files, with no norns and no hardware.

-- lift riff_parse + wav_decoder + wav_rate + convert_sr out of mpages and
-- assert the conversion: a rate error IS a pitch error, so check the VALUE at
-- a wall-clock position, not just the frame count.
local ok_count, fail = 0, {}
local function ok(c, w) if c then ok_count = ok_count + 1 else fail[#fail+1] = w end end
local function near(a,b,t,w) ok(math.abs(a-b) <= t,
  string.format("%s (got %s, want %s +-%s)", w, tostring(a), tostring(b), tostring(t))) end

local src = io.open("lib/mpages.lua"):read("a")
local rp = src:match("(local function riff_parse.-\nend)\n")
local dc = src:match("(local DECODE = .-\n})\n")
local wd = src:match("(function M%.wav_decoder.-\nend)\n")
local wr = src:match("(function M%.wav_rate.-\nend)\n")
local cu = src:match("(local function cubic.-\nend)\n")
local blk = src:match("(local SRC_BLOCK = .-\nlocal SRC_PACK = [^\n]*)\n")
local cs = src:match("(function M%.convert_sr.-\n  return true, written / sr\nend)")
assert(rp and dc and wd and wr and cu and blk and cs, "lift failed")
local env = setmetatable({ floor=math.floor, min=math.min, max=math.max }, {__index=_G})
local M = load(rp.."\n"..dc.."\n"..cu.."\n"..blk.."\nlocal M={}\n"..wd.."\n"..wr.."\n"..cs.."\nreturn M",
  "mp","t",env)()

local TMP = "/tmp/main-srtest/"
os.execute("rm -rf "..TMP.."; mkdir -p "..TMP)
local function ramp(path, secs, sr, ch)
  local n = math.floor(sr*secs); local f = assert(io.open(path,"wb")); local d = n*ch*2
  f:write("RIFF", string.pack("<I4",36+d), "WAVE")
  f:write("fmt ", string.pack("<I4",16), string.pack("<I2",1), string.pack("<I2",ch),
    string.pack("<I4",sr), string.pack("<I4",sr*ch*2), string.pack("<I2",ch*2), string.pack("<I2",16))
  f:write("data", string.pack("<I4",d))
  local b={} for i=0,n-1 do local v=math.floor((i/n)*30000)
    for _=1,ch do b[#b+1]=string.pack("<i2",v) end end
  f:write(table.concat(b)); f:close(); return n
end
local function read_wav(path)
  local f=io.open(path,"rb"); if not f then return nil end
  local s=f:read("a"); f:close()
  if s:sub(1,4)~="RIFF" then return nil end
  local ch=string.unpack("<I2",s,23); local sr=string.unpack("<I4",s,25)
  local dl=string.unpack("<I4",s,41)
  return { ch=ch, sr=sr, frames=dl//(ch*2),
    sample=function(i,c) return string.unpack("<i2",s,45+(i*ch+(c-1))*2)/32768 end }
end

ramp(TMP.."a441.wav", 2.0, 44100, 2)
ok(M.wav_rate(TMP.."a441.wav") == 44100, "wav_rate reads the declared rate")
local conv, secs = M.convert_sr(TMP.."a441.wav", TMP.."a48.wav", 48000, nil)
ok(conv == true, "a 44.1k file converts")
near(secs, 2.0, 0.01, "...and keeps its DURATION (same pitch, the whole point)")
local w = read_wav(TMP.."a48.wav")
ok(w ~= nil, "the conversion wrote a file")
w = w or { sr=0, frames=0, sample=function() return 0 end }
ok(w.sr == 48000, "the converted file declares the server rate")
ok(w.ch == 2, "...and is stereo")
near(w.frames, 2.0*48000, 4, "...with 2 seconds of 48k frames")
local TOP = 30000/32768
for _, t in ipairs({0.25, 0.5, 0.75, 1.5}) do
  near(w.sample(math.floor(t*48000), 1), (t/2.0)*TOP, 0.01,
    string.format("the ramp is %.0f%% up at %.2fs", (t/2)*100, t))
end
-- a mono source must come back on BOTH channels
ramp(TMP.."m441.wav", 1.0, 44100, 1)
ok(M.convert_sr(TMP.."m441.wav", TMP.."m48.wav", 48000, nil) == true, "a MONO 44.1k file converts")
local mw = read_wav(TMP.."m48.wav")
ok(mw and mw.ch == 2, "...to stereo")
ok(mw and math.abs(mw.sample(24000,1) - mw.sample(24000,2)) < 1e-9,
  "...with the same signal on both sides")
-- already at rate: no work, no file
ramp(TMP.."a48src.wav", 1.0, 48000, 2)
local same = M.convert_sr(TMP.."a48src.wav", TMP.."unused.wav", 48000, nil)
ok(same == false, "a 48k file reports 'no conversion needed'")
ok(io.open(TMP.."unused.wav","rb") == nil, "...and writes nothing")
-- garbage refuses
local b=io.open(TMP.."bad.wav","wb"); b:write("nope"); b:close()
ok(M.convert_sr(TMP.."bad.wav", TMP.."x.wav", 48000, nil) == nil,
  "an unreadable file refuses (the caller falls back to a raw load)")

-- ---- param-list drift ------------------------------------------------------
-- The three hand-maintained lists (MOTION_IDS here, SCENE_RECALL_IDS and
-- SWITCH_IDS in mscenes) have drifted from the param declarations more than
-- once; a lane whose id has no SHORT label draws the raw id and overruns the
-- gutter into the automation curve. Cheap to check, so check it.
do
  local mm = io.open("lib/mmotion.lua"):read("a")
  local mp = io.open("lib/mpages.lua"):read("a")
  local list = mm:match("local MOTION_IDS = %{(.-)\n%}")
  local short = mp:match("local SHORT = %{(.-)\n%}")
  ok(list ~= nil and short ~= nil, "MOTION_IDS and SHORT are both readable")
  local have = {}
  for k in (short or ""):gmatch("([%w_]+)%s*=%s*\"") do have[k] = true end
  local missing = {}
  for id in (list or ""):gmatch("\"([%w_]+)\"") do
    if not have[id] then missing[#missing + 1] = id end
  end
  ok(#missing == 0,
    "every MOTION_IDS entry has a SHORT label (missing: "
      .. table.concat(missing, ", ") .. ")")
end

print(string.format("\n%d assertions passed", ok_count))
if #fail > 0 then print(#fail.." FAILED:"); for _,f in ipairs(fail) do print("  x "..f) end; os.exit(1) end
print("main resampler OK")
