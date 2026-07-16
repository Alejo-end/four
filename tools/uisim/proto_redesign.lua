-- proto_redesign.lua — static pixel mockups of doc/redesign.md
-- ============================================================
-- Renders HANDCRAFTED states (not live script state) of the redesigned
-- chrome + all nine stations through the same 128x64
-- screen stub and 4x5 pixel font the real render suite uses, so the look
-- can be judged in the true medium before any restructuring happens.
--
-- usage:  lua tools/uisim/proto_redesign.lua <outdir>     (from repo root)
-- then:   python3 tools/uisim/pgm2png.py <outdir>/<shot>.pgm <out>.png 4
--
-- Deterministic: no math.random, hash() only — same PNGs every run.

local OUTDIR = arg[1] or "."

local floor, abs, sin, cos, exp, pi = math.floor, math.abs, math.sin,
  math.cos, math.exp, math.pi
local max, min = math.max, math.min

-- ============================================================================
-- framebuffer + the render suite's screen stub (mfont draws through it)
-- ============================================================================

local W, H = 128, 64
local buf = {}
for y = 1, H do buf[y] = {} for x = 1, W do buf[y][x] = 0 end end

local function px(x, y, l)
  x, y = floor(x), floor(y)
  if x >= 0 and x < W and y >= 0 and y < H then buf[y + 1][x + 1] = l end
end

local function draw_seg(x0, y0, x1, y1, l)
  x0, y0 = floor(x0), floor(y0)
  x1, y1 = floor(x1), floor(y1)
  local dx, dy = abs(x1 - x0), -abs(y1 - y0)
  local sx = x0 < x1 and 1 or -1
  local sy = y0 < y1 and 1 or -1
  local err = dx + dy
  while true do
    px(x0, y0, l)
    if x0 == x1 and y0 == y1 then break end
    local e2 = 2 * err
    if e2 >= dy then err = err + dy x0 = x0 + sx end
    if e2 <= dx then err = err + dx y0 = y0 + sy end
  end
end

local cur_level = 15
local cx, cy = 0, 0
local path
local function reset_path() path = { rects = {}, lines = {} } end
reset_path()

screen = {}
function screen.clear()
  for y = 1, H do for x = 1, W do buf[y][x] = 0 end end
  reset_path()
end
function screen.level(l) cur_level = floor(l) end
function screen.move(x, y) cx, cy = x, y end
function screen.line(x, y)
  path.lines[#path.lines + 1] = { cx, cy, x, y }
  cx, cy = x, y
end
function screen.rect(x, y, w, h) path.rects[#path.rects + 1] = { x, y, w, h } end
function screen.fill()
  for _, r in ipairs(path.rects) do
    local x0, y0 = floor(r[1]), floor(r[2])
    local w = max(floor(r[3] + 0.5), 1)
    local h = max(floor(r[4] + 0.5), 1)
    for yy = y0, y0 + h - 1 do
      for xx = x0, x0 + w - 1 do px(xx, yy, cur_level) end
    end
  end
  reset_path()
end
function screen.stroke()
  for _, L in ipairs(path.lines) do draw_seg(L[1], L[2], L[3], L[4], cur_level) end
  reset_path()
end
function screen.update() end

-- pixel font (draws via the screen stub above)
local ok, F = pcall(dofile, "lib/mfont.lua")
if not ok then
  local dir = arg[0]:match("^(.*)/[^/]+$") or "."
  F = dofile(dir .. "/../../lib/mfont.lua")
end

local function export(name)
  local f = assert(io.open(OUTDIR .. "/" .. name .. ".pgm", "w"))
  f:write("P2\n", W, " ", H, "\n255\n")
  for y = 1, H do
    local row = {}
    for x = 1, W do row[x] = buf[y][x] * 17 end
    f:write(table.concat(row, " "), "\n")
  end
  f:close()
  print("wrote " .. name .. ".pgm")
end

-- ============================================================================
-- drawing helpers
-- ============================================================================

local function hline(x0, x1, y, l) for x = x0, x1 do px(x, y, l) end end
local function vline(x, y0, y1, l) for y = y0, y1 do px(x, y, l) end end
local function rect_f(x, y, w, h, l)
  for yy = y, y + h - 1 do hline(x, x + w - 1, yy, l) end
end
local function rect_o(x, y, w, h, l)
  hline(x, x + w - 1, y, l) hline(x, x + w - 1, y + h - 1, l)
  vline(x, y, y + h - 1, l) vline(x + w - 1, y, y + h - 1, l)
end
local function dots_h(x0, x1, y, step, l) for x = x0, x1, step do px(x, y, l) end end
local function hash(i) return (sin(i * 127.1 + 311.7) * 43758.5453) % 1 end

-- ============================================================================
-- CHROME — header (title · pure mark · flags · path dots) + footer
-- ============================================================================

local PAGE_N = 9

local function path_dots(cur)
  local x = 87
  for i = 1, PAGE_N do
    if i == cur then rect_f(x - 1, 1, 3, 3, 15) else rect_f(x, 2, 2, 2, 3) end
    x = x + 4
    if i == 3 or i == 5 or i == 6 then x = x + 2 end -- family gaps 3-2-1-3
  end
end

-- the purity mark: lit ONLY when output == the take, verbatim
local function diamond(x, y, l)
  px(x + 2, y, l) px(x + 1, y + 1, l) px(x + 3, y + 1, l)
  px(x, y + 2, l) px(x + 4, y + 2, l)
  px(x + 1, y + 3, l) px(x + 3, y + 3, l) px(x + 2, y + 4, l)
end

local function header(title, o)
  o = o or {}
  local x
  if o.stop then                       -- STOP latched: the title chip inverts
    local w = F.text_w(title, 1)
    rect_f(0, 0, w + 5, 8, 15)
    F.ptext(title, 2, 2, 1, 0)
    x = w + 9
  else
    F.ptext(title, 2, 1, 1, 8)
    x = 2 + F.text_w(title, 1) + 4
  end
  if o.pure then diamond(x, 0, 15) x = x + 8 end
  if o.rec then                        -- writing: fast blink (drawn ON)
    rect_f(x, 1, 3, 3, 15)
    F.ptext("R", x + 5, 1, 1, 15)
    x = x + 12
  end
  if o.t then                          -- tape writing
    rect_f(x, 1, 3, 3, 15)
    F.ptext("T", x + 5, 1, 1, 15)
    x = x + 11
  end
  if o.m then                          -- motion writing
    rect_f(x, 1, 3, 3, 15)
    F.ptext("M", x + 5, 1, 1, 15)
    x = x + 13
  end
  if o.run then                        -- seq running: steady triangle
    vline(x, 1, 5, 10) vline(x + 1, 2, 4, 10) px(x + 2, 3, 10)
    x = x + 6
  end
  if o.fz then F.ptext("FZ", x, 1, 1, 10) x = x + 12 end
  path_dots(o.page or 1)
end

local FY = 58  -- footer text row

local function fkey(str, x, on, lvl)   -- key word: rest / latched-inverted
  local w = F.text_w(str, 1)
  if on then
    rect_f(x - 2, 56, w + 5, 8, 15)
    F.ptext(str, x, 58, 1, 0)
  else
    F.ptext(str, x, FY, 1, lvl or 6)
  end
  return w
end

-- encoder slot, right-anchored: WORD·  (value appears only while turning)
local function flabel_r(str, rx, lvl, val)
  local total = F.text_w(str, 1) + 3 + (val and F.text_w(val, 1) or 0)
  local x = rx - total
  F.ptext(str, x, FY, 1, lvl)
  local dx = x + F.text_w(str, 1) + 1
  px(dx, FY + 2, lvl)
  if val then F.ptext(val, dx + 2, FY, 1, lvl) end
  return x
end

-- o: shift, k2on, k3on, k3lvl, arc (0..1 erase progress),
--    e2lvl/e2val, e3lvl/e3val
local function footer(k2, k3, e2, e3, o)
  o = o or {}
  local x = 2
  if o.shift then rect_f(0, 57, 2, 6, 15) x = 5 end
  local w = fkey(k2, x, o.k2on)
  x = x + w + 9
  w = fkey(k3, x, o.k3on, o.k3lvl)
  if o.arc then                        -- the 1s erase hold-arc
    local ax, ay = x + w + 8, FY + 2
    for a = 0, 2 * pi, 0.22 do px(ax + cos(a) * 3.2, ay + sin(a) * 3.2, 4) end
    local a = -pi / 2
    while a < -pi / 2 + 2 * pi * o.arc do
      px(ax + cos(a) * 3.2, ay + sin(a) * 3.2, 15)
      a = a + 0.1
    end
  end
  local e3x = flabel_r(e3, 126, o.e3lvl or 6, o.e3val)
  flabel_r(e2, e3x - 9, o.e2lvl or 6, o.e2val)
end

-- ============================================================================
-- TAKE — the material (one strip: recorded bright, unwritten dotted,
--        window brackets inside, hairline = take within the 60s buffer)
-- ============================================================================

local SCY = 28

local function take_env(x)
  local base = 2 + 6.5 * abs(sin(x * 0.113 + 0.6))
    * (0.5 + 0.5 * sin(x * 0.029 + 1.2)) ^ 0.7
  return min(8, base * (0.55 + 0.55 * hash(x * 1.7)))  -- per-column texture
end

local function take_material(x0, x1, lvl_fn)
  for x = x0, x1 do
    local a = take_env(x)
    vline(x, floor(SCY - a), floor(SCY + a), lvl_fn(x))
  end
end

local function bracket_l(x, l)
  vline(x, 19, 37, l)
  px(x + 1, 19, l) px(x + 2, 19, l) px(x + 1, 37, l) px(x + 2, 37, l)
end
local function bracket_r(x, l)
  vline(x, 19, 37, l)
  px(x - 1, 19, l) px(x - 2, 19, l) px(x - 1, 37, l) px(x - 2, 37, l)
end

local function buffer_hairline(frac)
  hline(2, 125, 41, 2)
  hline(2, 2 + floor(frac * 123), 41, 9)
end

local function shot_take_empty()
  header("TAKE", { page = 1 })
  dots_h(3, 124, SCY, 3, 3)
  F.ptext_c("EMPTY - K2 REC", 64, 23, 1, 10)
  F.ptext_c("OR PARAMS > LOAD", 64, 33, 1, 4)
  footer("REC", "SNAP", "ST", "EN")
  export("proto_01_take_empty")
end

local function shot_take_rec()
  header("TAKE", { page = 1, rec = true })
  rect_o(0, 17, 128, 23, 15)             -- armed frame (fast blink, ON phase)
  local hx = 64
  take_material(3, hx, function(x)       -- hot afterglow behind the head
    local d = hx - x
    if d < 12 then return 15 - floor(d / 3) else return 11 end
  end)
  dots_h(hx + 3, 124, SCY, 3, 3)
  vline(hx, 18, 38, 15)                  -- write head
  F.ptext("3.8S", 88, 44, 2, 15)         -- the one number that matters
  F.ptext("IN", 2, 49, 1, 5)             -- input meter + record-ready bracket
  rect_f(12, 50, 55, 5, 1)
  rect_f(12, 50, 34, 5, 11)
  rect_f(47, 50, 2, 5, 15)
  hline(41, 57, 48, 8) vline(41, 47, 48, 8) vline(57, 47, 48, 8)
  footer("REC", "SNAP", "ST", "EN", { k2on = true })
  export("proto_02_take_rec")
end

local function shot_take_framed()
  header("TAKE", { page = 1, pure = true })
  take_material(3, 96, function(x)
    return (x >= 14 and x <= 80) and 13 or 5   -- outside the window: dim
  end)
  dots_h(99, 124, SCY, 3, 3)
  bracket_l(14, 15) bracket_r(80, 15)
  vline(46, 20, 36, 15)                  -- playhead, looping the window
  buffer_hairline(0.14)
  footer("REC", "SNAP", "ST", "EN")
  export("proto_03_take_framed")
end

local function shot_take_erase()
  header("TAKE", { page = 1 })
  for x = 3, 96 do                       -- danger hatch: material marked
    local a = take_env(x)
    local dim = (x >= 14 and x <= 80) and 4 or 2
    for y = floor(SCY - a), floor(SCY + a) do
      px(x, y, (x + y) % 4 == 0 and 11 or dim)
    end
  end
  bracket_l(14, 5) bracket_r(80, 5)
  buffer_hairline(0.14)
  footer("STOP", "ERASE", "MOV", "JIT",
    { shift = true, k3lvl = 15, arc = 0.65 })
  export("proto_04_take_erase")
end

-- ============================================================================
-- VOICE — how the take plays (mode rail + the mode's own texture)
-- ============================================================================

local MODES = { "PLAY", "GRAIN", "WARP", "PV" }

local function mode_rail(active, dim)
  local x = 4
  for i, m in ipairs(MODES) do
    local w = F.text_w(m, 1)
    if i == active and not dim then
      rect_f(x - 2, 8, w + 5, 9, 15)
      F.ptext(m, x, 10, 1, 0)
    else
      F.ptext(m, x, 10, 1, dim and 3 or 5)
    end
    x = x + w + 10
  end
end

local function shot_voice_play()
  header("VOICE", { page = 2, pure = true })
  mode_rail(1)
  local prev                              -- clean loop: one unbroken wave
  for x = 3, 124 do
    local a = 3 + 9 * abs(sin(x * 0.021 + 0.9))
    local y = 37 - sin(x * 0.19) * a
    if prev then draw_seg(x - 1, prev, x, y, 13) end
    prev = y
  end
  footer("FRZ", "MODE", "SPEED", "PITCH")
  export("proto_05_voice_play")
end

local function shot_voice_grain()
  header("VOICE", { page = 2 })
  mode_rail(2)
  dots_h(3, 124, 37, 4, 2)
  for i = 1, 72 do
    local gx = 4 + hash(i * 3.7) * 119
    local gy = 23 + hash(i * 7.1) * 29
    local s = hash(i * 11.3) < 0.28 and 2 or 1
    local band = 1 - abs(gy - 37) / 15
    local l = max(3, min(14, floor(3 + band * 9 + hash(i * 13.9) * 3)))
    rect_f(floor(gx), floor(gy), s, s, l)
  end
  footer("FRZ", "MODE", "SIZE", "DENS")
  export("proto_06_voice_grain")
end

local function shot_voice_warp()
  header("VOICE", { page = 2 })
  mode_rail(3)
  for k = 0, 8 do                         -- overlapping stretch windows
    local x0 = 3 + k * 14
    local lvl = 5 + (k % 3) * 4
    local ytop = 24 + (k % 2) * 4
    local prev
    for t = 0, 28 do
      local h
      if t < 8 then h = t / 8 elseif t > 20 then h = (28 - t) / 8 else h = 1 end
      local x = x0 + t
      if x <= 124 then
        local y = 50 - h * (50 - ytop)
        if prev then draw_seg(x - 1, prev, x, y, lvl) end
        prev = y
      end
    end
  end
  footer("FRZ", "MODE", "WIN", "RAND")
  export("proto_07_voice_warp")
end

local function shot_voice_pv_frz()
  header("VOICE", { page = 2, fz = true })
  mode_rail(4)
  for x = 6, 122, 5 do                    -- spectral columns, frozen
    local band = exp(-((x - 58) / 40) ^ 2)
    local h = min(32, (3 + band * 26) * (0.45 + hash(x * 1.3) * 0.75))
    local l = max(3, min(13, floor(3 + band * 7 + hash(x * 2.7) * 4)))
    rect_f(x, floor(52 - h), 3, floor(h) + 1, l)
  end
  footer("FRZ", "MODE", "SPEED", "PITCH", { k2on = true })
  export("proto_08_voice_pv_frz")
end

local function shot_voice_stop()
  header("VOICE", { page = 2, stop = true })
  mode_rail(1, true)                      -- body collapses to skeletons...
  hline(3, 124, 37, 3)
  footer("FRZ", "MODE", "SPEED", "PITCH") -- ...controls stay in place
  export("proto_09_voice_stop")
end

-- ============================================================================
-- SPACE — the time-smear (onset · echo taps · reverb tail · shimmer motes)
-- ============================================================================

-- o: dry, A/tau (tail), fb (tap decay), inf, motes, wash
local function scape(o)
  hline(4, 124, 50, o.dry and 3 or 4)
  if o.dry then
    vline(8, 45, 50, 4) px(9, 50, 4)      -- dormant: a stub of an onset
    return
  end
  for _, tx in ipairs({ 57, 106 }) do     -- time rails: 1 s and 2 s
    for y = 16, 49, 2 do px(tx, y, 2) end
  end
  local A, tau = o.A or 14, o.tau or 26
  for x = 9, 124 do                       -- the tail
    local h = A * exp(-(x - 8) / tau)
    if h >= 1 then
      vline(x, floor(50 - h), 49, 3)
      px(x, floor(50 - h), 7)
    end
  end
  rect_f(8, 16, 2, 35, 15)                -- the onset
  for k = 1, 6 do                         -- echo taps
    local x = 8 + 17 * k
    local h, l
    if o.inf then h, l = 30, 12
    else
      h = 33 * ((o.fb or 0.62) ^ k)
      l = max(4, 14 - 2 * k)
    end
    if h >= 1.5 then rect_f(x, floor(50 - h), 2, floor(h), l) end
  end
  for i = 1, (o.motes or 0) do            -- shimmer climbs off the tail
    local mx = 12 + hash(i * 4.9) * 105
    local th = A * exp(-(mx - 8) / tau)
    local my = 50 - th - 2 - hash(i * 8.3) * (10 + ((o.motes or 0) > 12 and 8 or 0))
    if my > 15 then px(floor(mx), floor(my), 3 + floor(hash(i * 2.2) * 7)) end
  end
  if o.wash then                          -- "this will not stop soon"
    for y = 16, 50 do
      for x = 125, 127 do if (x + y) % 3 == 0 then px(x, y, 9) end end
    end
  end
  F.ptext("1S", 56, 52, 1, 3)
  F.ptext("2S", 105, 52, 1, 3)
end

local function shot_space_dry()
  header("SPACE", { page = 5, pure = true })
  scape({ dry = true })
  footer("INF", "BLOOM", "ECHO", "VERB")
  export("proto_15_space_dry")
end

local function shot_space_active()
  header("SPACE", { page = 5 })
  scape({ A = 14, tau = 26, fb = 0.62, motes = 7 })
  footer("INF", "BLOOM", "ECHO", "VERB", { e2lvl = 15, e2val = "35" })
  export("proto_16_space_active")
end

local function shot_space_inf()
  header("SPACE", { page = 5 })
  scape({ A = 10, tau = 22, inf = true, motes = 5 })
  footer("INF", "BLOOM", "ECHO", "VERB", { k2on = true })
  export("proto_17_space_inf")
end

local function shot_space_wash()
  header("SPACE", { page = 5 })
  scape({ A = 18, tau = 90, fb = 0.8, motes = 20, wash = true })
  footer("INF", "BLOOM", "ECHO", "VERB", { e3lvl = 15, e3val = "72" })
  export("proto_18_space_wash")
end

local function shot_space_shift()
  header("SPACE", { page = 5 })
  scape({ A = 14, tau = 26, fb = 0.62, motes = 7 })
  footer("STOP", "DRY", "TIME", "DECAY", { shift = true })
  export("proto_19_space_shift")
end

-- ============================================================================
-- TAPE — the second deck: the BELT (user-picked over ring/strip candidates,
-- feedback round 1). A literal tape loop: material rides the top run, the
-- return run carries the circulation arrow, rate sits inside the loop.
-- ============================================================================

-- o: hx (head x on the top run), dir (+1/-1), fresh (punch-in glow), rate
local function belt(o)
  local x0, x1, yt, yb, r = 22, 106, 24, 42, 9
  local yc = (yt + yb) / 2
  for t = -pi / 2, pi / 2, 0.04 do px(x1 + cos(t) * r, yc + sin(t) * r, 4) end
  for t = pi / 2, 3 * pi / 2, 0.04 do px(x0 + cos(t) * r, yc + sin(t) * r, 4) end
  hline(x0, x1, yb, 4)                    -- the return run
  local ax = 62                           -- circulation arrow on the return
  local s = o.dir > 0 and 1 or -1
  px(ax + 2 * s, yb - 2, 7) px(ax + s, yb - 1, 7) px(ax, yb, 7)
  px(ax + s, yb + 1, 7) px(ax + 2 * s, yb + 2, 7)
  for x = x0, x1 do                       -- material on the top run
    local a = take_env(x) * 0.45
    local l = 10
    if o.fresh and ((o.dir > 0 and x <= o.hx and x > o.hx - 20) or
                    (o.dir < 0 and x >= o.hx and x < o.hx + 20)) then
      l = 15                              -- punch-in: fresh material glows
    end
    vline(x, floor(yt - a), floor(yt + a), l)
  end
  for k = 1, 3 do                         -- quarter-position ticks
    vline(x0 + floor((x1 - x0) * k / 4), yt - 7, yt - 6, 3)
  end
  for k = 8, 1, -1 do                     -- trail = direction
    local tx = o.hx - o.dir * k
    if tx >= x0 and tx <= x1 then vline(tx, yt - 5, yt + 5, max(5, 14 - k)) end
  end
  vline(o.hx, yt - 6, yt + 6, 15)         -- the head
  F.ptext(o.rate or "X1.0", 54, yc - 3, 1, 8)
end

local function shot_tape_loop()
  header("TAPE", { page = 3 })
  belt({ hx = 78, dir = 1 })
  F.ptext_r("3.2S", 124, 12, 1, 5)
  footer("REC", "REV", "RATE", "LOOP")
  export("proto_10_tape_loop")
end

local function shot_tape_overdub()
  header("TAPE", { page = 3, t = true })
  belt({ hx = 66, dir = 1, fresh = true })
  F.ptext_r("3.2S", 124, 12, 1, 5)
  footer("REC", "REV", "RATE", "LOOP", { k2on = true })
  export("proto_11_tape_overdub")
end

local function shot_tape_rev()
  header("TAPE", { page = 3 })
  belt({ hx = 60, dir = -1, rate = "X-1.0" })
  F.ptext_r("3.2S", 124, 12, 1, 5)
  footer("REC", "REV", "RATE", "LOOP", { k3on = true })
  export("proto_12_tape_rev")
end

-- ============================================================================
-- FILTER — tone (the real curve; drive = grit on the line, not a number)
-- ============================================================================

-- o: cut (x of cutoff), res (bump 0..1), drive (0..1), open
local function filt_curve(o)
  -- measurement rails: 100 Hz / 1 kHz / 10 kHz on the log-f axis
  for _, fx in ipairs({ 32, 72, 112 }) do
    for y = 18, 46, 2 do px(fx, y, 2) end
  end
  F.ptext("100", 27, 49, 1, 3)
  F.ptext("1K", 69, 49, 1, 3)
  F.ptext("10K", 106, 49, 1, 3)
  local prev
  for x = 4, 124 do
    local mag
    if o.open then mag = 1
    elseif x <= o.cut then
      mag = 1 + (o.res or 0) * exp(-((x - o.cut) / 7) ^ 2)
    else
      mag = exp(-(x - o.cut) / 12) * (1 + (o.res or 0))
    end
    local y = 47 - mag * 20
    if not o.open then vline(x, floor(y) + 1, 46, 3) end  -- filled passband
    if prev then draw_seg(x - 1, prev, x, y, o.open and 8 or 12) end
    if (o.drive or 0) > 0 and hash(x * 5.1) < o.drive * 0.35 then
      px(x, y - 2 - hash(x * 9.7) * 2, 7)                 -- drive grit
    end
    prev = y
  end
  dots_h(4, 124, 27, 4, 2)                                -- 0 dB rail
  local ycut = o.open and 27 or (47 - (1 + (o.res or 0)) * 20)
  local nx = o.open and 122 or o.cut
  rect_f(nx - 1, floor(ycut) - 1, 3, 3, 15)               -- the node
end

local function shot_filter_carved()
  header("FILTER", { page = 4 })
  filt_curve({ cut = 74, res = 0.35, drive = 0.5 })
  footer("OPEN", "TYPE", "CUT", "RES")
  export("proto_13_filter_carved")
end

local function shot_filter_open()
  header("FILTER", { page = 4, pure = true })
  filt_curve({ open = true })
  footer("OPEN", "TYPE", "CUT", "RES", { k2on = true })
  export("proto_14_filter_open")
end

-- ============================================================================
-- MIX — the console (in meter · two deck lanes at REAL gain · master VU)
-- ============================================================================

local function mix_body(o)
  F.ptext("IN", 4, 12, 1, 5)
  rect_o(3, 18, 8, 31, 3)
  if not o.stop then
    rect_f(5, 30, 4, 17, 11)
    rect_f(5, 27, 4, 2, 15)
  end
  F.ptext("ENG", 18, 13, 1, 5)
  for x = 18, 104 do                       -- engine lane (bright = sounding)
    if o.stop then px(x, 23, 3)
    else
      local a = take_env(x) * 0.5
      vline(x, floor(23 - a), floor(23 + a), 12)
    end
  end
  hline(18, 104, 32, 4)                    -- crossfade rail
  rect_f(56, 30, 3, 5, 15)                 -- the tick stays put in STOP
  for x = 18, 104 do                       -- tape lane (quieter deck)
    if o.stop then px(x, 41, 3)
    else
      local a = 1 + 3 * hash(floor(x / 3) * 2.1)
      vline(x, floor(41 - a), floor(41 + a), 6)
    end
  end
  F.ptext("TAPE", 18, 48, 1, 5)
  rect_o(112, 18, 8, 31, 3)                -- master VU
  if not o.stop then
    rect_f(114, 28, 4, 19, 11)
    rect_f(114, 25, 4, 2, 15)
  end
end

local function shot_mix_live()
  header("MIX", { page = 6 })
  mix_body({})
  footer("ENG", "TAPE", "MIX", "OUT")
  export("proto_20_mix_live")
end

local function shot_mix_stop()
  header("MIX", { page = 6, stop = true })
  mix_body({ stop = true })
  footer("ENG", "TAPE", "MIX", "OUT")
  export("proto_21_mix_stop")
end

-- ============================================================================
-- PADS — the take chopped and sequenced (cause above, rhythm below)
-- ============================================================================

-- o: pattern (16 bools), playhead (0-15 or -1), fired (selected slice pulses)
local function pads_body(o)
  for x = 4, 123 do                        -- the take, thin
    local a = take_env(x) * 0.4
    vline(x, floor(16 - a), floor(16 + a), 8)
  end
  for i = 1, 7 do vline(4 + i * 15, 12, 20, 3) end
  for i = 0, 7 do                          -- slice cells, aligned under it
    local x = 4 + i * 15
    local sel = (i == 2)
    if o.fired and sel then
      rect_f(x, 23, 14, 12, 11)
      F.ptext_c(tostring(i + 1), x + 7, 27, 1, 0)
    else
      rect_o(x, 23, 14, 12, 4)
      F.ptext_c(tostring(i + 1), x + 7, 27, 1, 5)
    end
    if sel then                            -- cursor brackets
      hline(x - 1, x + 2, 22, 15) hline(x + 11, x + 14, 22, 15)
      hline(x - 1, x + 2, 36, 15) hline(x + 11, x + 14, 36, 15)
      vline(x - 1, 22, 25, 15) vline(x + 14, 22, 25, 15)
      vline(x - 1, 33, 36, 15) vline(x + 14, 33, 36, 15)
    end
  end
  local pat = o.pattern or {}
  for s = 0, 15 do                         -- the 16-step row
    local x = floor(4 + s * 7.5)
    if o.playhead == s then rect_f(x, 41, 6, 7, 15)
    elseif pat[s + 1] then rect_f(x, 41, 6, 7, 9)
    else rect_o(x, 41, 6, 7, 3) end
  end
end

local function shot_pads_run()
  header("PADS", { page = 7, run = true })
  local E = { true, false, false, true, false, true, false, false,
              true, false, false, true, false, true, false, false }
  pads_body({ pattern = E, playhead = 8, fired = true })
  footer("PAD", "RUN", "SLICE", "HITS",
    { k3on = true, e2val = "3", e2lvl = 6 })
  export("proto_22_pads_run")
end

local function shot_pads_empty()
  header("PADS", { page = 7 })
  pads_body({ pattern = {}, playhead = -1 })
  F.ptext_c("TURN E3 - OR TAP GRID", 64, 50, 1, 6)
  footer("PAD", "RUN", "SLICE", "HITS", { e2val = "3", e2lvl = 6 })
  export("proto_23_pads_empty")
end

-- ============================================================================
-- MOTION — the gesture loop (timeline + lanes; hatch = being re-written)
-- ============================================================================

local function motion_body(o)
  -- lanes are DYNAMIC: one appears per param you actually recorded, from
  -- ANY page — named with the owning page's own footer word. Three here to
  -- pose that: SPEED (VOICE) · CUTOFF (FILTER) · ECHO (SPACE).
  local gx0, gx1 = 33, 124
  for k = 0, 4 do                          -- quarter rails through the loop
    local x = gx0 + floor((gx1 - gx0) * k / 4)
    for y = 14, 51, 2 do px(x, y, k == 0 and 3 or 2) end
  end
  local hx = gx0 + floor((gx1 - gx0) * (o.pos or 0.45))
  local lanes = {
    { name = "SPEED",  y0 = 15, f1 = 0.045, f2 = 0.18, p = 0.4 },
    { name = "CUTOFF", y0 = 28, f1 = 0.055, f2 = 0.21, p = 1.0, sel = true },
    { name = "ECHO",   y0 = 41, f1 = 0.037, f2 = 0.15, p = 3.1,
      hatch = o.rec },
  }
  for _, ln in ipairs(lanes) do
    local yb = ln.y0 + 10
    F.ptext(ln.name, 3, ln.y0 + 3, 1, ln.sel and 11 or 5)
    if ln.sel then                         -- selected lane bracket
      vline(0, ln.y0, yb, 15) px(1, ln.y0, 15) px(1, yb, 15)
    end
    if ln.hatch then                       -- punch-replace, this pass
      for y = ln.y0, yb do
        for x = gx0, gx1 do if (x + y) % 3 == 0 then px(x, y, 6) end end
      end
    end
    local prev
    for x = gx0, gx1 do                    -- the recorded motion, as a curve
      local t = x - gx0
      local v = 0.5 + 0.38 * sin(t * ln.f1 + ln.p) + 0.1 * sin(t * ln.f2)
      v = max(0.05, min(0.95, v))
      local y = yb - v * 10
      if prev then
        draw_seg(x - 1, prev, x, y,
          ln.hatch and 12 or (ln.sel and 11 or 7))
      end
      prev = y
      if x == hx then                      -- the value sounding right now
        rect_f(hx - 1, floor(y) - 1, 3, 3, 15)
      end
    end
  end
  vline(hx, 13, 52, o.rec and 15 or 10)    -- one playhead crosses every lane
  if o.rec then                            -- armed frame = the fast blink
    rect_o(gx0 - 2, 12, gx1 - gx0 + 5, 42, 15)
  end
  F.ptext_r("LOOP 4.2S", 126, 6, 1, 4)     -- loop length, out of the lanes
end

local function shot_motion_play()
  header("MOTION", { page = 8 })
  motion_body({ pos = 0.45 })
  footer("REC", "PLAY", "LANE", "DPT",
    { k3on = true, e2val = "CUTOFF", e2lvl = 6 })
  export("proto_24_motion_play")
end

local function shot_motion_rec()
  header("MOTION", { page = 8, m = true })
  motion_body({ pos = 0.7, rec = true })
  footer("REC", "PLAY", "LANE", "DPT",
    { k2on = true, k3on = true, e2val = "CUTOFF", e2lvl = 6 })
  export("proto_25_motion_rec")
end

-- ============================================================================
-- SCENE — states and the way back (◄ undo cell · slots · the morph rail)
-- ============================================================================

local atan2 = math.atan2 or math.atan

local function pie(cx0, cy0, r, frac, l)   -- the queued-recall wedge
  for yy = -r, r do
    for xx = -r, r do
      if xx * xx + yy * yy <= r * r then
        local rel = (atan2(yy, xx) + pi / 2) % (2 * pi)
        if rel <= 2 * pi * frac then px(cx0 + xx, cy0 + yy, l) end
      end
    end
  end
end

local SLOT_FILLED = { [1] = true, [2] = true, [4] = true, [6] = true }

-- o: sel, here (slot matching the live sound), amt, queued, wfrac
local function scene_body(o)
  rect_o(3, 15, 10, 12, 3)                 -- the ◄ undo cell
  F.ptext("<", 6, 18, 1, 8)
  for i = 1, 8 do
    local x = 16 + (i - 1) * 13
    if SLOT_FILLED[i] then
      if o.queued == i then rect_f(x, 15, 11, 12, 13)     -- slow blink, ON
      else
        rect_f(x + 2, 17, 7, 8, 6)
        rect_o(x, 15, 11, 12, 5)
      end
    else                                   -- empty: dotted outline
      for xx = x, x + 10, 2 do px(xx, 15, 3) px(xx, 26, 3) end
      for yy = 15, 26, 2 do px(x, yy, 3) px(x + 10, yy, 3) end
    end
    if o.here == i then rect_f(x + 4, 19, 3, 3, o.queued == i and 0 or 15) end
    if o.sel == i then                     -- cursor brackets
      hline(x - 1, x + 2, 13, 15) hline(x + 8, x + 11, 13, 15)
      hline(x - 1, x + 2, 28, 15) hline(x + 8, x + 11, 28, 15)
      vline(x - 1, 13, 16, 15) vline(x + 11, 13, 16, 15)
      vline(x - 1, 25, 28, 15) vline(x + 11, 25, 28, 15)
    end
  end
  F.ptext("LIVE", 4, 40, 1, 6)             -- the morph rail
  local x0, x1 = 28, 108
  hline(x0, x1, 42, 3)
  local hx = x0 + floor((x1 - x0) * (o.amt or 0))
  hline(x0, hx, 42, 10)
  rect_f(x0 - 1, 41, 3, 3, 12)             -- origin: where the sweep departed
  rect_o(hx - 2, 40, 5, 5, 15) px(hx, 42, 0)   -- the handle
  F.ptext(tostring(o.sel or 4), 114, 40, 1, 8)
  if o.queued then pie(121, 20, 4, o.wfrac or 0.6, 12) end
end

local function shot_scene_morph()
  header("SCENE", { page = 9 })
  scene_body({ sel = 4, here = 2, amt = 0.65 })
  footer("RCL", "CAP", "SLOT", "MRF",
    { e2val = "4", e2lvl = 6, e3lvl = 15, e3val = "65" })
  export("proto_26_scene_morph")
end

local function shot_scene_queued()
  header("SCENE", { page = 9 })
  scene_body({ sel = 4, here = 2, amt = 0, queued = 4, wfrac = 0.6 })
  footer("RCL", "CAP", "SLOT", "MRF", { e2val = "4", e2lvl = 6 })
  export("proto_27_scene_queued")
end

local function shot_scene_peek()
  header("SCENE", { page = 9 })
  scene_body({ sel = 4, here = 4, amt = 1.0 })
  footer("RCL", "CAP", "SLOT", "MRF", { k2on = true, e2val = "4", e2lvl = 6 })
  export("proto_28_scene_peek")
end

-- ============================================================================
-- run
-- ============================================================================

local shots = {
  shot_take_empty, shot_take_rec, shot_take_framed, shot_take_erase,
  shot_voice_play, shot_voice_grain, shot_voice_warp, shot_voice_pv_frz,
  shot_voice_stop,
  shot_tape_loop,
  shot_tape_overdub, shot_tape_rev,
  shot_filter_carved, shot_filter_open,
  shot_space_dry, shot_space_active, shot_space_inf, shot_space_wash,
  shot_space_shift,
  shot_mix_live, shot_mix_stop,
  shot_pads_run, shot_pads_empty,
  shot_motion_play, shot_motion_rec,
  shot_scene_morph, shot_scene_queued, shot_scene_peek,
}

for _, s in ipairs(shots) do
  screen.clear()
  s()
end
print("done: " .. #shots .. " shots")
