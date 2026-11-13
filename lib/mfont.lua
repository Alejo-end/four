-- mfont: the 4x5 pixel font and every routine that sets type with it.
--
-- the font comes from the bitmap mockups and is drawn rect-by-rect so the
-- device renders exactly what the bitmaps promised. rows top->bottom,
-- '1' = lit.

local floor = math.floor
local sbyte = string.byte

local FONT = {
  A = { "0110", "1001", "1111", "1001", "1001" },
  B = { "1110", "1001", "1110", "1001", "1110" },
  C = { "0111", "1000", "1000", "1000", "0111" },
  D = { "1110", "1001", "1001", "1001", "1110" },
  E = { "1111", "1000", "1110", "1000", "1111" },
  F = { "1111", "1000", "1110", "1000", "1000" },
  G = { "0111", "1000", "1011", "1001", "0111" },
  H = { "1001", "1001", "1111", "1001", "1001" },
  I = { "111", "010", "010", "010", "111" },
  J = { "0011", "0001", "0001", "1001", "0110" },
  K = { "1001", "1010", "1100", "1010", "1001" },
  L = { "1000", "1000", "1000", "1000", "1111" },
  M = { "10001", "11011", "10101", "10001", "10001" },
  N = { "1001", "1101", "1011", "1001", "1001" },
  O = { "0110", "1001", "1001", "1001", "0110" },
  P = { "1110", "1001", "1110", "1000", "1000" },
  Q = { "0110", "1001", "1001", "1010", "0101" },
  R = { "1110", "1001", "1110", "1010", "1001" },
  S = { "0111", "1000", "0110", "0001", "1110" },
  T = { "111", "010", "010", "010", "010" },
  U = { "1001", "1001", "1001", "1001", "0110" },
  V = { "101", "101", "101", "101", "010" },
  W = { "10001", "10001", "10101", "11011", "10001" },
  X = { "101", "101", "010", "101", "101" },
  Y = { "101", "101", "010", "010", "010" },
  Z = { "1111", "0001", "0110", "1000", "1111" },
  ["0"] = { "0110", "1001", "1011", "1101", "0110" },
  ["1"] = { "010", "110", "010", "010", "111" },
  ["2"] = { "1110", "0001", "0110", "1000", "1111" },
  ["3"] = { "1110", "0001", "0110", "0001", "1110" },
  ["4"] = { "1001", "1001", "1111", "0001", "0001" },
  ["5"] = { "1111", "1000", "1110", "0001", "1110" },
  ["6"] = { "0111", "1000", "1110", "1001", "0110" },
  ["7"] = { "1111", "0001", "0010", "0100", "0100" },
  ["8"] = { "0110", "1001", "0110", "1001", "0110" },
  ["9"] = { "0110", "1001", "0111", "0001", "1110" },
  ["."] = { "0", "0", "0", "0", "1" },
  ["-"] = { "000", "000", "111", "000", "000" },
  ["+"] = { "000", "010", "111", "010", "000" },
  ["="] = { "000", "111", "000", "111", "000" },
  [":"] = { "0", "1", "0", "1", "0" },
  ["/"] = { "001", "001", "010", "100", "100" },
  ["%"] = { "11001", "11010", "00100", "01011", "10011" },
  ["<"] = { "001", "010", "100", "010", "001" },
  [">"] = { "100", "010", "001", "010", "100" },
  -- the sharp of a note name (the RESON effect's note: C#3)
  ["#"] = { "01010", "11111", "01010", "11111", "01010" },
  [" "] = { "00", "00", "00", "00", "00" },
}

-- byte-indexed glyph + advance tables, built once: text draws every frame,
-- and a byte walk allocates nothing (per-char gmatch/sub costs an iterator
-- or a string per call). lua patterns are byte-based, so bytes match them.
local FONT_B, FONT_ADV = {}, {}
for b = 0, 255 do
  local ch = string.char(b)
  local g = FONT[ch] or FONT[ch:upper()] or FONT[" "]
  FONT_B[b] = g
  FONT_ADV[b] = #g[1] + 1
end

local function text_w(str, sc)
  local w = 0
  for i = 1, #str do w = w + FONT_ADV[sbyte(str, i)] * sc end
  return w - sc
end

-- draw a pixel-font string at (x,y) top-left, scale sc, brightness lvl
local function ptext(str, x, y, sc, lvl)
  screen.level(lvl)
  local cx = x
  for i = 1, #str do
    local b = sbyte(str, i)
    local g = FONT_B[b]
    for r = 1, 5 do
      local row = g[r]
      for c = 1, #row do
        if sbyte(row, c) == 49 then  -- 49 = "1"
          screen.rect(cx + (c - 1) * sc, y + (r - 1) * sc, sc, sc)
        end
      end
    end
    cx = cx + FONT_ADV[b] * sc
  end
  screen.fill()
  return cx - x - sc
end

local function ptext_c(str, cx, y, sc, lvl)
  ptext(str, floor(cx - text_w(str, sc) / 2 + 0.5), y, sc, lvl)
end

local function ptext_r(str, rx, y, sc, lvl)
  ptext(str, rx - text_w(str, sc), y, sc, lvl)
end

-- inverted chip (the ALT tag / mode badge from the mockups)
local function chip(str, x, y)
  local w = text_w(str, 1) + 5
  screen.level(15)
  screen.rect(x, y, w, 9)
  screen.fill()
  ptext(str, x + 3, y + 2, 1, 0)
  return w
end

return {
  text_w = text_w,
  ptext = ptext,
  ptext_c = ptext_c,
  ptext_r = ptext_r,
  chip = chip,
}
