// mangler for Hydra, served by visuals/bridge.js at http://127.0.0.1:8080
// (index.html loads this file). Start `node visuals/bridge.js` first.
//
// m   = the latest value of every field the norns sends (see fields.json),
//       with a smoothed copy in s.
// a   = Hydra's own audio analysis. Set the browser's audio input to the
//       RETURN from the norns (see README.md), not to the Ableton output.
//
// The picture has two layers. The news video, worn like old tape with slow
// blobs through it, is the bed (o4). A reactive LOOK sits on top: its black is
// see-through. Which look is chosen by the norns param "visuals look"
// (PARAMS > visuals out). It is stored in presets and in scenes, so a scene
// can bring its own look. AUTO picks one by the page. A change of look is a
// dissolve.

const WS_URL = "ws://" + (location.host || "127.0.0.1:8080");   // the host that served the page
const m = { page: 1, page_name: "TAKE", scene: 1, look: 1, flash: 0, mode: 5, rec: 0, freeze: 0, beat: 0, tempo: 120,
  env: 0, lfo1: 0.5, lfo2: 0.5, morph: 0, in_l: 0, in_r: 0, out_l: 0, out_r: 0,
  play: 0, rec_phase: 0, win_start: 0, win_end: 1, size: 0.5, density: 0.5,
  spread: 0.5, jitter: 0, pitch: 0.5, cutoff: 1, resonance: 0, drive: 0,
  dry_wet: 0.5, delay_mix: 0, rev_mix: 0,
  // track 2 (mangler2 only; mangler never sends these, so the layer stays dark)
  t2_on: 0, t2_mode: 1, t2_level: 1, t2_play: 0, t2_win_start: 0, t2_win_end: 1,
  t2_size: 0.5, t2_density: 0.5, t2_pitch: 0.5, t2_cutoff: 1 };
const s = Object.assign({}, m);          // smoothed copy
let flash = 0, linked = false, lastMsg = 0;
// a page opened over the network has no audio input (the browser gives a
// microphone only to a secure page). The page on the computer with the norns
// return sends its four audio bands through the bridge, 20 times a second,
// and every other page reacts to those instead.
const HAS_AUDIO = window.isSecureContext;
const farFft = [0, 0, 0, 0];
let farAt = 0;
let otText = "", otAt = 0;                    // the last MIDI event, for the display
let sceneDir = 0, sceneAt = 0, pageAt = 0;   // for the display: FF, REW and the page name

// ---- the link, with its own reconnect --------------------------------------
let sock = null;
function connect() {
  const ws = new WebSocket(WS_URL);
  sock = ws;
  ws.onopen = () => { linked = true; };
  ws.onmessage = (e) => {
    lastMsg = Date.now();
    const j = JSON.parse(e.data);
    if (j.ev) { onEvent(j.ev, j.a || []); return; }
    if (j.fft) { if (!HAS_AUDIO) { for (let i = 0; i < 4; i++) farFft[i] = +j.fft[i] || 0; farAt = Date.now(); } return; }
    if (j.state) Object.assign(m, j.state);
    else if (j.k in m) {
      if (j.k === "scene" && j.v !== m.scene) {            // a scene change
        flash = 1; sceneDir = j.v > m.scene ? 1 : -1; sceneAt = Date.now();
      }
      if (j.k === "page" && j.v !== m.page) { flash = Math.max(flash, 0.5); pageAt = Date.now(); }
      m[j.k] = j.v;
    }
  };
  ws.onclose = () => { linked = false; setTimeout(connect, 1000); };
  ws.onerror = () => ws.close();
}
connect();

// solid(r, g, b, a) adds and multiplies all four channels, so a grey level
// is solid(x, x, x, 1), never solid(1, 1, 1, x)
const grey = (f) => solid(f, f, f, 1);
// Hydra makes no `a` when it detects no audio (a page opened over the
// network). Without this stand-in, a.setBins threw and the whole page stopped
// right here: connected to the bridge, drawing nothing.
if (typeof a === "undefined" || !a || !a.setBins) {
  window.a = { fft: [0, 0, 0, 0], setBins() {}, setSmooth() {}, setScale() {}, setCutoff() {} };
}
a.setBins(4); a.setSmooth(0.8); a.setScale(6); a.setCutoff(1);
// band i of the return audio: this page's own, or the one sent from the page
// that hears it (silence if that page has been quiet for a second)
const fftBand = (i) => HAS_AUDIO ? a.fft[i] : (Date.now() - farAt < 1000 ? farFft[i] : 0);
const hz = () => fftBand(0) + fftBand(1);       // low half of the return audio
if (HAS_AUDIO) setInterval(() => {
  if (sock && sock.readyState === 1)
    sock.send(JSON.stringify({ fft: [0, 1, 2, 3].map((i) => +(a.fft[i] || 0).toFixed(3)) }));
}, 50);

// the news picture, or a stand-in when there is none
const vid = document.getElementById("news");
const HAVE_VIDEO = !!(vid && vid.dataset.on === "1");
if (HAVE_VIDEO) s0.init({ src: vid });
const newsPic = () => HAVE_VIDEO ? src(s0) : osc(8, 0.05, 1).color(0.6, 0.6, 0.75);

// ---- the looks --------------------------------------------------------------
// Each takes the buffer it will be drawn into (for feedback) and returns a
// chain. Index = the option number of "visuals look" on the norns, in this
// order. AUTO is 1 and is not a look of its own.
const NAMES = ["AUTO", "BARS", "FILTER", "SHAPES", "RINGS", "MOSAIC", "TUNNEL", "WAVES", "FACETS"];
const AUTO_BY_PAGE = { TAKE: 5, VOICE: 2, TAPE: 5, LAYERS: 5, PADS: 2,
  FILTER: 3, MIX: 3, DELAY: 7, REVERB: 7, MOTION: 8, SCENE: 4,
  TRACK2: 2, TRACKS: 4 };   // mangler2: its track pages

const LOOKS = {
  // BARS: size and density of the grains. density = how many, size = how
  // thick, jitter = how unsteady.
  2: (self) => src(self).scale(1.002).brightness(-0.02).blend(
    osc(() => 6 + s.density * 90, 0.02, 0)
      .thresh(() => 0.45 + (1 - s.size) * 0.4, 0.05)
      .modulate(noise(() => 2 + s.jitter * 12, () => 0.1 + s.spread), () => s.jitter * 0.3)
      .color(() => 0.6 + s.pitch * 0.4, 0.5, () => 1 - s.pitch)
      .scale(() => 1 + hz() * 0.2),
    0.15),

  // FILTER: a scanning beam at the playhead. The cutoff opens its width, the
  // resonance brightens its core, the delay mix lengthens the trail it leaves.
  3: (self) => src(self)
    .mult(grey(() => 0.88 + s.delay_mix * 0.1))
    .add(shape(4, 0.5, 0.35)
      .scale(1, () => 0.02 + s.cutoff * 0.12, 4)
      .scrollX(() => (s.play - 0.5) * 1.6)
      .color(0.9, () => 0.3 + s.resonance * 0.6, () => 0.5 + (1 - s.cutoff) * 0.6), 0.09),

  // SHAPES: the scene number picks the hue and the sides, the morph the size,
  // the lfos the wobble. A scene change flashes.
  4: () => shape(() => 3 + s.scene, () => 0.3 + s.morph * 0.5, 0.01)
    .repeat(() => 2 + s.lfo1 * 4, () => 2 + s.lfo2 * 4)
    .rotate(() => s.lfo1 * 6.28)
    .color(() => (s.scene * 0.17) % 1, () => 0.4, () => 1 - ((s.scene * 0.17) % 1))
    .add(grey(() => flash * 0.6)),

  // RINGS: concentric rings that breathe with the input. density = how many,
  // size = how thick, pitch = colour.
  5: () => osc(() => 6 + s.density * 40, 0.02, 0)
    .kaleid(200)
    .thresh(() => 0.35 + (1 - s.size) * 0.45, 0.04)
    .scale(() => 0.7 + s.size * 0.5 + s.env * 0.4)
    .color(() => 0.5 + s.pitch * 0.5, () => 0.8 - s.pitch * 0.4, 1)
    .rotate(() => s.lfo1 * 0.3),

  // MOSAIC: the news itself, in coarse blocks. density = the block size, the
  // low end of the return audio flickers the brightness.
  6: () => newsPic()
    .pixelate(() => 6 + s.density * 70, () => 4 + s.density * 45)
    .contrast(1.15)
    .saturate(1.2)
    .rotate(() => (s.lfo1 - 0.5) * 0.2)
    .brightness(() => hz() * 0.2 - 0.15),

  // TUNNEL: feedback that falls inwards. The lfos steer the zoom and the
  // turn, the kaleidoscope seed grows with density.
  7: (self) => src(self)
    .scale(() => 1.01 + s.lfo1 * 0.02)
    .rotate(() => (s.lfo2 - 0.5) * 0.06)
    .hue(0.003)
    .blend(osc(() => 6 + s.size * 30, 0.1, 1)
      .thresh(0.7, 0.1)
      .kaleid(() => 3 + Math.floor(s.density * 6)), 0.12)
    .blend(newsPic().luma(0.5, 0.2), 0.08)
    .brightness(-0.01),

  // WAVES: thin lines that ripple like a scope. The input envelope bends them,
  // the playhead scrolls them, the cutoff tints them.
  8: () => osc(() => 30 + s.density * 80, 0.1, 0)
    .rotate(1.5708)
    .modulate(osc(3, 0, 0).rotate(1.5708), () => 0.08 + s.env * 0.5)
    .modulate(noise(2, 0.1), () => 0.03 + s.jitter * 0.2)
    .thresh(0.84, 0.04)
    .scrollY(() => s.play)
    .color(() => 0.4 + s.cutoff * 0.6, 0.8, 1),

  // FACETS: the news as flat shards, like a low-poly model of the picture.
  // density = how many shards, size = how far they slide apart, the second
  // lfo = how fast they drift. Few colours, hard edges.
  9: () => newsPic()
    .modulate(voronoi(() => 4 + s.density * 10, () => 0.03 + s.lfo2 * 0.15, 0), () => 0.04 + s.size * 0.18)
    .posterize(() => 7 - s.size * 3, 0.9)
    .saturate(1.3)
    .contrast(1.15)
    .brightness(() => hz() * 0.1 - 0.05),
};

const nowLook = () => m.look > 1 ? Math.round(m.look) : (AUTO_BY_PAGE[m.page_name] ?? 5);

// two buffers, one showing and one filling: a change of look is built into
// the idle one and dissolved in
const bufs = [o1, o2];
const wb = [1, 0];
let ci = 0, curLook = nowLook(), trans = null;
const build = (i, look) => (LOOKS[look] || LOOKS[5])(bufs[i]).out(bufs[i]);
build(0, curLook);

const PAGE_ID = Math.random().toString(36).slice(2, 8);
let frames = 0;
update = () => {
  frames++;
  for (const k in s) if (typeof m[k] === "number") s[k] += (m[k] - s[k]) * 0.15;
  const want = nowLook();
  if (!trans && want !== curLook) {
    build(1 - ci, want);
    trans = { to: want, t: 0 };
  }
  if (trans) {
    trans.t = Math.min(1, trans.t + 0.04);
    wb[ci] = 1 - trans.t;
    wb[1 - ci] = trans.t;
    if (trans.t >= 1) { ci = 1 - ci; curLook = trans.to; trans = null; }
  }
  flash *= 0.92;
  if (m.flash > 0.5) flash = Math.min(1.5, flash + 0.25);   // the FLASH pad on the grid: held, it keeps hitting
};

// the looks go to o5, each buffer scaled by its weight
src(o1).mult(grey(() => wb[0]))
  .add(src(o2).mult(grey(() => wb[1])))
  // a recording tints the picture red; a freeze zooms it a little
  .add(solid(() => m.rec ? 0.08 : 0, 0, 0, 1))
  .scale(() => 1 - m.freeze * 0.03)
  .out(o5);

// track 2's layer, in o7 (mangler2): a second voice gets a second mark. A
// cold blue column stands where track 2's head plays; its width is track 2's
// window, its grain is its density and size, its tint its cutoff. It fades in
// when track 2 sounds and out when it stops, over the look and under the display.
src(o7).mult(grey(0.82))
  .add(osc(() => 12 + s.t2_density * 70, 0.04, 0)
    .thresh(() => 0.45 + (1 - s.t2_size) * 0.4, 0.06)
    .modulate(noise(() => 2 + s.t2_pitch * 8, 0.15), () => 0.04 + s.t2_pitch * 0.12)
    .mult(shape(4, 1, 0.25)
      .scale(1, () => 0.03 + Math.max(0, s.t2_win_end - s.t2_win_start) * 0.35, 4)
      .scrollX(() => (s.t2_play - 0.5) * 1.6))
    .color(() => 0.25 + (1 - s.t2_cutoff) * 0.3, () => 0.55 + s.t2_cutoff * 0.35, 1)
    .mult(grey(() => s.t2_on * Math.min(1, s.t2_level) * 0.9)), 0.35)
  .out(o7);

// the bed, in o4: the news worn like old tape (low resolution, faded warm
// colour, a slow wobble, scanlines, grain, a smear of the last frame) with
// slow blobs through it. Without a picture the blobs stand alone.
const blobs = voronoi(() => 3 + s.density * 7, () => 0.08 + s.lfo2 * 0.25, 0.7)
  .modulate(noise(1.5, 0.05), 0.15)
  .color(0.5, 0.8, 1.6)
  .hue(() => (s.scene * 0.13 + s.lfo1 * 0.2) % 1)
  .saturate(1.8)
  .contrast(1.2)
  .brightness(0.08)
  .scale(() => 1 + hz() * 0.1);
const tape = src(s0)
  .pixelate(360, 240)
  .saturate(0.55)
  .color(1.0, 0.92, 0.78)
  .contrast(1.1)
  .brightness(() => -0.03 + hz() * 0.05)
  .modulate(noise(2.5, 0.04), () => 0.002 + s.lfo1 * 0.006)
  .scrollY(() => Math.sin(time * 0.4) * 0.002)
  .mult(osc(240, 0, 0).rotate(1.5708).color(0.12, 0.12, 0.12).add(solid(0.88, 0.88, 0.88, 1)))
  .add(noise(420, 1.2).color(0.05, 0.05, 0.05))
  .blend(src(o4), 0.35);
(HAVE_VIDEO ? tape.blend(blobs, () => 0.08 + s.density * 0.1) : blobs).out(o4);

// ---- the tape's own marks ----------------------------------------------------
// The on-screen display of a VCR, drawn on a canvas and used as a texture:
// PLAY, a tape counter, the date, what the norns is doing, the news source,
// and a REC dot while the norns records.
const osd = document.createElement("canvas");
osd.width = 960; osd.height = 540;
const ox = osd.getContext("2d");
const t0 = Date.now();
const MODES = ["OFF", "GRAIN", "WARP", "PV", "PLAY", "CLOUD"];
const pad2 = (n) => String(n).padStart(2, "0");
const MONTHS = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"];
function drawOsd() {
  ox.clearRect(0, 0, 960, 540);
  ox.font = "bold 30px 'Courier New', monospace";
  ox.textBaseline = "top";
  const put = (txt, x, y, align) => {
    ox.textAlign = align || "left";
    ox.fillStyle = "rgba(0,0,0,0.6)"; ox.fillText(txt, x + 2, y + 2);
    ox.fillStyle = "#e8f4e8"; ox.fillText(txt, x, y);
  };
  const el = Math.floor((Date.now() - t0) / 1000);
  const blink = Math.floor(Date.now() / 600) % 2 === 0;
  const d = new Date();
  const recent = Date.now() - sceneAt < 1400;
  if (m.rec) { if (blink) { ox.fillStyle = "#ff3030"; ox.beginPath(); ox.arc(50, 56, 11, 0, 6.3); ox.fill(); } put("REC", 72, 40); }
  else if (m.freeze) put("\u2590\u2590 PAUSE", 40, 40);
  else if (recent && sceneDir > 0) put("\u25B6\u25B6 FF", 40, 40);
  else if (recent && sceneDir < 0) put("\u25C0\u25C0 REW", 40, 40);
  else put("\u25B6 PLAY", 40, 40);
  if (Date.now() - pageAt < 1500) put(String(m.page_name), 480, 440, "center");
  if (Date.now() - otAt < 1600) put(otText, 480, 400, "center");
  put("SP " + Math.floor(el / 3600) + ":" + pad2(Math.floor(el / 60) % 60) + ":" + pad2(el % 60), 920, 40, "right");
  put(NAMES[(m.look > 1 ? Math.round(m.look) : (AUTO_BY_PAGE[m.page_name] ?? 5)) - 1] + "  SC" + m.scene + "  " +
    (MODES[Math.round(m.mode) - 1] || "") +
    (m.t2_on ? "  T2 " + (MODES[Math.round(m.t2_mode) - 1] || "") : ""), 40, 470);
  put(((window.NEWS && window.NEWS.name) || "") + "  " + MONTHS[d.getMonth()] + " " + pad2(d.getDate()) + " " + d.getFullYear(), 920, 470, "right");
  // the link: only when something is wrong
  if (Date.now() - lastMsg > 4000) put(linked ? "WAITING FOR THE NORNS" : "NO BRIDGE", 480, 250, "center");
}
drawOsd();
setInterval(drawOsd, 250);
s1.init({ src: osd, dynamic: true });

// ---- the doodles ---------------------------------------------------------------
// Slow, sparse drawings that draw themselves in and fade, and the words of a
// sampler's screen that type themselves out. The Octatrack (or any MIDI
// source on the norns) makes them: a note draws a shape (the track picks
// where and which), a program change types the pattern (A01 to H16), a CC types
// its number and value, start and stop type PLAY and STOP. With no MIDI, a
// few ambient ones appear on their own, so the picture is never still.
const dd = document.createElement("canvas");
dd.width = 960; dd.height = 540;
const dx = dd.getContext("2d");
const PHRASES = ["FUNC + BANK", "PTN 01", "TRK 5", "SCENE A", "SCENE B", "REC AB", "FX1: FILTER",
  "FX2: DELAY", "LFO", "SLICE 12", "FLEX", "CROSSFADER", "YES/SAVE", "LIVE SAMPLING",
  "THRU", "GRAIN", "FREEZE", "TAPE", "SEND", "RETURN"];
const actors = [];
let nextAmbient = 0;
const rnd = (a, b) => a + Math.random() * (b - a);
const pick = (list) => list[Math.floor(Math.random() * list.length)];
function addActor(a) {
  a.t = 0; a.pts = Array.from({ length: 14 }, () => [rnd(-90, 90), rnd(-90, 90)]);
  actors.push(a);
  if (actors.length > 40) actors.shift();
}
function doodle(kind, x, y, size, life) { addActor({ kind, x, y, size, life: life || 360 }); }
function phrase(text, x, y, size, life) { addActor({ kind: "text", x, y, size, life: life || 300, text }); }
const noteName = (n) => ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"][n % 12] + (Math.floor(n / 12) - 1);

function onEvent(name, a) {
  const now = Date.now();
  if (name === "note") {
    const ch = a[0] | 0, note = a[1] | 0, vel = a[2] | 0;
    const x = 80 + ((ch - 1) % 8) * 100 + rnd(-20, 20);       // the track picks the column
    const y = 540 - 60 - ((note % 48) / 48) * 400;            // the pitch picks the height
    doodle(["circle", "line", "scribble"][ch % 3], x, y, 40 + vel * 0.7, 300);
    if (Math.random() < 0.3) phrase("TRK " + ch + "  " + noteName(note), x, y - 30, 26, 200);
    flash = Math.max(flash, vel / 127 * 0.5);
    otText = "TRK " + ch; otAt = now;
  } else if (name === "pc") {
    const p = a[1] | 0;
    const pat = String.fromCharCode(65 + Math.floor(p / 16) % 8) + pad2(p % 16 + 1);
    phrase("PTN " + pat, rnd(120, 480), rnd(120, 360), 110, 420);
    flash = 1; sceneDir = 1; sceneAt = now;
    otText = "PTN " + pat; otAt = now;
  } else if (name === "cc") {
    const cc = a[1] | 0, val = a[2] | 0;
    if (Math.random() < 0.15) phrase("CC" + cc + " " + val, rnd(80, 760), rnd(80, 440), 30, 160);
    otText = "CC" + cc + "  " + val; otAt = now;
  } else if (name === "run") {
    phrase(a[0] ? "PLAY" : "STOP", 480, 270, 130, 300);
    otText = a[0] ? "PLAY" : "STOP"; otAt = now;
  }
}

function drawDoodles() {
  // the old marks fade, they do not vanish
  dx.globalCompositeOperation = "destination-out";
  dx.fillStyle = "rgba(0,0,0,0.04)";
  dx.fillRect(0, 0, 960, 540);
  dx.globalCompositeOperation = "source-over";
  if (Date.now() > nextAmbient) {
    nextAmbient = Date.now() + rnd(3000, 7000);
    const x = rnd(60, 700), y = rnd(80, 460);
    if (Math.random() < 0.4) phrase(pick(PHRASES), x, y, rnd(40, 90), 300);
    else doodle(pick(["circle", "line", "scribble"]), x, y, rnd(60, 200), 360);
  }
  dx.lineCap = "round"; dx.lineJoin = "round";
  for (const d of actors) {
    d.t++;
    const p = Math.min(d.t / 100, 1);                         // the draw-in
    const breathe = 1 + 0.03 * Math.sin(d.t * 0.03);
    const fade = Math.min(1, (d.life - d.t) / 60);            // the fade out at the end
    dx.globalAlpha = Math.max(0, fade) * 0.85;
    dx.strokeStyle = dx.fillStyle = "#f0ead8";
    if (d.kind === "text") {
      dx.font = "bold " + Math.round(d.size) + "px 'Courier New', monospace";
      dx.textBaseline = "top";
      const n = Math.floor(p * d.text.length);
      dx.fillText(d.text.slice(0, n) + (d.t % 40 < 20 && p < 1 ? "_" : ""), d.x, d.y);
    } else if (d.kind === "circle") {
      dx.lineWidth = 3;
      dx.beginPath(); dx.arc(d.x, d.y, d.size * 0.5 * breathe, 0, p * Math.PI * 2); dx.stroke();
    } else if (d.kind === "line") {
      dx.lineWidth = 4;
      dx.beginPath(); dx.moveTo(d.x, d.y);
      dx.lineTo(d.x + d.pts[0][0] * 2 * p, d.y + d.pts[0][1] * 2 * p); dx.stroke();
    } else {
      dx.lineWidth = 2.5;
      dx.beginPath();
      const n = 2 + Math.floor(p * (d.pts.length - 2));
      for (let i = 0; i < n; i++) {
        const px = d.x + d.pts[i][0] * breathe * d.size / 100, py = d.y + d.pts[i][1] * breathe * d.size / 100;
        if (i === 0) dx.moveTo(px, py); else dx.lineTo(px, py);
      }
      dx.stroke();
    }
  }
  dx.globalAlpha = 1;
  for (let i = actors.length - 1; i >= 0; i--) if (actors[i].t >= actors[i].life) actors.splice(i, 1);
}
setInterval(drawDoodles, 33);
s2.init({ src: dd, dynamic: true });

// the pulse of the norns clock: 1 on the beat, falling away
const pulse = () => Math.pow(1 - (m.beat || 0), 5);

// ---- the picture, in three steps ------------------------------------------------
// o6: the bed, the look on top of it, track 2's column, and the display on top
src(o4).layer(src(o5).luma(0.04, 0.03)).layer(src(o7).luma(0.05, 0.03))
  .layer(src(s2)).layer(src(s1)).out(o6);

// o0: the tape's faults. The three colour channels slip apart a little (more
// when the input is loud), a tracking band rolls up the picture and tears it
// sideways, the corners fall into shadow, and the whole thing breathes on the beat.
// (a Hydra chain changes when you add to it, so every use builds its own)
const band = () => osc(1, 0, 0).rotate(1.5708).scrollY(() => time * 0.06).thresh(0.965, 0.01);
const grade = () => src(o6);
const slip = () => 0.002 + s.env * 0.004;
grade().color(1, 0, 0, 1).scrollX(() => slip())
  .add(grade().color(0, 1, 0, 1))
  .add(grade().color(0, 0, 1, 1).scrollX(() => -slip()))
  .modulateScrollX(band(), () => 0.015 + s.env * 0.03 + flash * 0.05 + m.freeze * 0.02)
  .scrollY(() => m.freeze * (Math.random() - 0.5) * 0.004)
  .add(band().mult(noise(220, 2)), 0.12)
  .brightness(() => pulse() * 0.04)
  .scale(() => 1 + pulse() * 0.004)
  .mult(shape(100, 1.15, 0.85).scale(1, 0.56, 1), 1)
  .out(o0);

render(o0);

// a report to the bridge every 5 seconds: what the picture and the sound are
// doing, so that doctor.command (and anyone looking at /status) can tell
// without seeing the screen
setInterval(() => {
  const v = document.getElementById("news");
  const rep = { id: PAGE_ID, t: Date.now(), visible: document.visibilityState === "visible", fps: Math.round(frames / 5), playing: !!(v && !v.paused && v.readyState > 2),
    muted: !!(v && v.muted), vt: v ? +v.currentTime.toFixed(1) : 0,
    src: (window.NEWS && window.NEWS.name) || "none", fails: window.NEWS ? window.NEWS.fails : 0,
    audio: +(fftBand(0) + fftBand(1) + fftBand(2) + fftBand(3)).toFixed(3), has_audio: HAS_AUDIO,
    look: m.look, scene: m.scene, page: m.page_name,
    heap_mb: performance.memory ? Math.round(performance.memory.usedJSHeapSize / 1048576) : null,
    up_s: Math.round((Date.now() - t0) / 1000) };
  frames = 0;
  if (sock && sock.readyState === 1) sock.send(JSON.stringify({ diag: rep }));
  // a page that has grown very large starts again (a few seconds of black)
  if (rep.heap_mb && rep.heap_mb > 700 && rep.up_s > 3600) location.reload();
}, 5000);
