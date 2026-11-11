#!/usr/bin/env node
// bridge.js: UDP OSC from the norns in, JSON over a WebSocket out, for Hydra.
// No packages to install. Needs Node 18 or newer.
//
//   node visuals/bridge.js [--osc-port 9000] [--ws-port 8080]
//
// The norns sends /mangler/<key> with one argument. Each message goes to every
// connected page as {"k":"size","v":0.42}. A page that connects gets the whole
// last-known state first as {"state":{...}}. The WebSocket listens on
// 127.0.0.1 only (unless MANGLER_LAN=1), so only this computer can read it.

const dgram = require("dgram");
const net = require("net");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

function argOf(name, dflt) {
  const i = process.argv.indexOf(name);
  return i > 0 && process.argv[i + 1] ? Number(process.argv[i + 1]) : dflt;
}
const OSC_PORT = argOf("--osc-port", 9000);
const WS_PORT = argOf("--ws-port", 8080);
const PREFIX = "/mangler/";
const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

// ---- OSC parsing (messages and bundles; i f s d T F N) -------------------
function readString(buf, at) {
  let end = at;
  while (end < buf.length && buf[end] !== 0) end++;
  const s = buf.toString("utf8", at, end);
  return [s, (end + 4) & ~3];   // the string and its NUL pad to 4 bytes
}

function parseMessage(buf) {
  let [path, at] = readString(buf, 0);
  if (at >= buf.length) return { path, args: [] };
  let tags;
  [tags, at] = readString(buf, at);
  const args = [];
  for (const t of tags.slice(1)) {
    if (t === "i") { args.push(buf.readInt32BE(at)); at += 4; }
    else if (t === "f") { args.push(buf.readFloatBE(at)); at += 4; }
    else if (t === "d") { args.push(buf.readDoubleBE(at)); at += 8; }
    else if (t === "s") { let s; [s, at] = readString(buf, at); args.push(s); }
    else if (t === "T") args.push(true);
    else if (t === "F") args.push(false);
    else if (t === "N") args.push(null);
    else throw new Error("unsupported OSC type " + t);
  }
  return { path, args };
}

function parsePacket(buf, out) {
  if (buf.toString("utf8", 0, 8) === "#bundle\0") {
    let at = 16;   // "#bundle" + 8 bytes of time tag
    while (at + 4 <= buf.length) {
      const size = buf.readInt32BE(at);
      at += 4;
      parsePacket(buf.subarray(at, at + size), out);
      at += size;
    }
  } else {
    out.push(parseMessage(buf));
  }
}

// ---- WebSocket server (text frames out, nothing needed in) ---------------
const clients = new Set();
const state = {};

function frame(text) {
  const body = Buffer.from(text, "utf8");
  let head;
  if (body.length < 126) head = Buffer.from([0x81, body.length]);
  else if (body.length < 65536) { head = Buffer.alloc(4); head[0] = 0x81; head[1] = 126; head.writeUInt16BE(body.length, 2); }
  else { head = Buffer.alloc(10); head[0] = 0x81; head[1] = 127; head.writeBigUInt64BE(BigInt(body.length), 2); }
  return Buffer.concat([head, body]);
}

function broadcast(text) {
  const f = frame(text);
  for (const c of clients) c.write(f);
}

// A plain GET serves the standalone page (index.html and hydra.js, from this
// folder), so Hydra can run from http://127.0.0.1 and the browser asks no
// permission to reach the bridge.
const PAGES = { "/": ["index.html", "text/html; charset=utf-8"], "/index.html": ["index.html", "text/html; charset=utf-8"],
  "/hydra.js": ["hydra.js", "text/javascript; charset=utf-8"] };
let rate = 0;                    // messages per second
const diags = new Map();         // page id -> its last report (each page sends its own)
// the report of the page that is drawing (the highest frame rate), or null
function bestDiag() {
  let best = null;
  for (const [id, d] of diags) {
    if (Date.now() - d.at > 15000) { diags.delete(id); continue; }
    if (!best || (d.r.fps || 0) > (best.r.fps || 0)) best = d;
  }
  return best;
}
function servePage(sock, head) {
  const m = /^GET (\S+)/.exec(head);
  if (m && m[1] === "/status") {
    const b = bestDiag();
    const body = Buffer.from(JSON.stringify({ osc_per_s: rate, from: lastFrom, pages: clients.size,
      diag: b ? b.r : null, diag_age_ms: b ? Date.now() - b.at : null, reporting_pages: diags.size }));
    sock.end(Buffer.concat([Buffer.from("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " +
      body.length + "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"), body]));
    return;
  }
  const hit = m && PAGES[m[1].split("?")[0]];
  if (!hit) { sock.end("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"); return; }
  const body = fs.readFileSync(path.join(__dirname, hit[0]));
  sock.end(Buffer.concat([Buffer.from("HTTP/1.1 200 OK\r\nContent-Type: " + hit[1] + "\r\nContent-Length: " +
    body.length + "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"), body]));
}

const server = net.createServer((sock) => {
  let upgraded = false;
  let head = "";
  let inbuf = Buffer.alloc(0);
  sock.on("data", (d) => {
    if (!upgraded) {
      head += d.toString("latin1");
      if (!head.includes("\r\n\r\n")) return;
      const m = /Sec-WebSocket-Key:\s*(.+)\r\n/i.exec(head);
      if (!m) { servePage(sock, head); return; }
      const accept = crypto.createHash("sha1").update(m[1].trim() + GUID).digest("base64");
      sock.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" +
        "Connection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n");
      upgraded = true;
      clients.add(sock);
      sock.write(frame(JSON.stringify({ state })));
      return;
    }
    // frames from the page: masked, text. Only the page's own report matters.
    inbuf = Buffer.concat([inbuf, d]);
    while (inbuf.length >= 2) {
      const op = inbuf[0] & 0x0f;
      let len = inbuf[1] & 0x7f, at = 2;
      if (len === 126) { if (inbuf.length < 4) break; len = inbuf.readUInt16BE(2); at = 4; }
      else if (len === 127) { sock.end(); return; }      // far larger than any report
      const masked = (inbuf[1] & 0x80) !== 0;
      const need = at + (masked ? 4 : 0) + len;
      if (inbuf.length < need) break;
      const payload = Buffer.from(inbuf.subarray(at + (masked ? 4 : 0), need));
      if (masked) for (let i = 0; i < payload.length; i++) payload[i] ^= inbuf[at + (i & 3)];
      inbuf = inbuf.subarray(need);
      if (op === 0x8) { sock.end(); return; }
      if (op === 0x9) sock.write(Buffer.from([0x8a, 0]));   // ping -> pong
      if (op === 0x1) {
        try { const j = JSON.parse(payload.toString("utf8")); if (j.diag) diags.set(j.diag.id || "?", { r: j.diag, at: Date.now() }); } catch (e) {}
      }
    }
  });
  sock.on("close", () => clients.delete(sock));
  sock.on("error", () => clients.delete(sock));
});
server.on("error", (e) => { console.error("websocket: " + e.message); process.exit(1); });
// MANGLER_LAN=1 opens the port to the local network (a second computer on the
// same Wi-Fi can show the visuals). The default stays this computer only.
const LAN = process.env.MANGLER_LAN === "1";
server.listen(WS_PORT, LAN ? "0.0.0.0" : "127.0.0.1");
if (LAN) console.log("LAN mode: other computers on this network can open http://<this computer>.local:" + WS_PORT);

// ---- UDP in --------------------------------------------------------------
let count = 0, bad = 0, lastFrom = "none";
const udp = dgram.createSocket("udp4");
udp.on("message", (buf, rinfo) => {
  lastFrom = rinfo.address;
  const msgs = [];
  try { parsePacket(buf, msgs); } catch (e) { bad++; return; }
  for (const { path, args } of msgs) {
    if (path.startsWith(PREFIX + "ev/")) {        // an event (several arguments, no stored state)
      count++;
      broadcast(JSON.stringify({ ev: path.slice(PREFIX.length + 3), a: args }));
      continue;
    }
    if (!path.startsWith(PREFIX) || args.length < 1) continue;
    const k = path.slice(PREFIX.length), v = args[0];
    state[k] = v;
    count++;
    broadcast(JSON.stringify({ k, v }));
  }
});
udp.on("error", (e) => { console.error("udp: " + e.message); process.exit(1); });
udp.bind(OSC_PORT, "0.0.0.0");

setInterval(() => {
  rate = count;
  console.log(`osc :${OSC_PORT} ${count} msg/s from ${lastFrom}` +
    (bad ? `, ${bad} unreadable` : "") + ` | ws :${WS_PORT} ${clients.size} page(s)` +
    (bestDiag() ? ` | video ${bestDiag().r.playing ? "playing" : "STOPPED"} ${bestDiag().r.src} ${bestDiag().r.fps}fps` : ""));
  count = 0; bad = 0;
}, 1000);
