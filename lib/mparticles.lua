-- mparticles: the pooled grain-cloud particle system (visual only).
--
-- particles are spawned at the playhead at ~density rate. x is buffer
-- position (playhead + jitter scatter), y is the grain's stereo seat
-- (pan + spread scatter, the engine's own per-grain pan law: L up,
-- R down), dot side and lifetime both step with grain size. slots are
-- pooled and kept in spawn order, so steady-state spawning never allocates.

local floor, log, random, max = math.floor, math.log, math.random, math.max

local PARTICLE_MAX = 32
local GRAIN_CY, GRAIN_CH = 31, 8  -- stereo axis: mono rail row + half-height
local SIZE_LOG_SPAN = log(50)     -- size spec is exp 0.01..0.5s: a 50x range
local particles = {}
local particles_n = 0
for i = 1, PARTICLE_MAX do
  particles[i] = { x = 0, y = 0, lvl = 0, decay = 0, sz = 1 }
end
local spawn_acc = 0

local C            -- shared ctx, bound at init
local pget, clamp, window_bounds, FPS

local M = { CY = GRAIN_CY, CH = GRAIN_CH }

function M.init(ctx)
  C = ctx
  pget, clamp, window_bounds, FPS = ctx.pget, ctx.clamp, ctx.window_bounds, ctx.FPS
end

function M.update()
  if not params.lookup["density"] then return end
  -- nothing moves that can't be heard: mode OFF frees the SC voice, and an
  -- empty buffer granulates silence — either way the cloud stops spawning
  -- (live particles still decay out)
  if pget("mode", 2) == 1 or not C.wave_any then
    spawn_acc = 0
  else
    spawn_acc = spawn_acc + pget("density", 20) / FPS
  end
  local lo, hi, span = window_bounds()
  local jit = pget("pos_jitter", 0)
  local size = pget("size", 0.1)
  local decay = 13 / max(size * FPS * 4, 2)
  -- grain size reads twice: lifetime (decay above) and dot side — 1..3 px
  -- stepped along the size spec's exp scale, fixed at spawn like the
  -- sounding grain (thresholds land near 27ms and 190ms)
  local sz = 1 + floor(clamp(log(size * 100) / SIZE_LOG_SPAN, 0, 1) * 2 + 0.5)
  local pan = pget("pan", 0)
  local spr = pget("spread", 0.5)
  local play_phase = C.play_phase
  while spawn_acc >= 1 do
    spawn_acc = spawn_acc - 1
    if particles_n < PARTICLE_MAX then
      local px = clamp(play_phase + (random() * 2 - 1) * jit * span, 0, 1)
      particles_n = particles_n + 1
      local p = particles[particles_n]
      p.x = px * 127
      -- y is the grain's stereo seat: pan + spread scatter, clipped the
      -- same way the engine clips per-grain pan — so cloud height IS
      -- stereo width, and hard pans pile up on the band edge
      p.y = clamp(GRAIN_CY + (pan + (random() * 2 - 1) * spr) * GRAIN_CH,
        GRAIN_CY - GRAIN_CH, GRAIN_CY + GRAIN_CH)
      p.lvl = 13
      p.decay = decay
      p.sz = sz
    else
      spawn_acc = 0
    end
  end
  -- decay + compact in place: live slots keep their order (draw order is
  -- part of the picture), dead slots swap to the tail for reuse
  local w = 0
  for i = 1, particles_n do
    local p = particles[i]
    p.lvl = p.lvl - p.decay
    if p.lvl >= 1 then
      w = w + 1
      if w ~= i then
        particles[w], particles[i] = p, particles[w]
      end
    end
  end
  particles_n = w
end

function M.draw()
  -- level varies per particle and overlaps must layer in spawn order, so
  -- the fill stays per-particle (32 max); dots center on their stereo seat
  for i = 1, particles_n do
    local p = particles[i]
    local off = (p.sz - 1) * 0.5
    screen.level(floor(p.lvl))
    screen.rect(p.x - off, p.y - off, p.sz, p.sz)
    screen.fill()
  end
end

return M
