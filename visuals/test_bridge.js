#!/usr/bin/env node
// test_bridge.js: a fake norns and a fake page, to prove the bridge with no
// hardware. Starts the bridge on spare ports, sends OSC over UDP, reads the
// WebSocket by hand. Exits 1 on any failure.
//   node visuals/test_bridge.js
const { spawn } = require("child_process");
const dgram = require("dgram");
const net = require("net");
const path = require("path");

const OSC = 19000, WS = 18080, NORNS = 19111;
let fails = 0, checks = 0;
function ok(c, w) { checks++; if (!c) { fails++; console.log("FAIL: " + w); } }

function pad(buf) { const n = (4 - (buf.length % 4)) % 4; return Buffer.concat([buf, Buffer.alloc(n)]); }
function str(s) { return pad(Buffer.concat([Buffer.from(s), Buffer.from([0])])); }
function msg(p, tag, val) {
  let a;
  if (tag === "f") { a = Buffer.alloc(4); a.writeFloatBE(val); }
  else if (tag === "i") { a = Buffer.alloc(4); a.writeInt32BE(val); }
  else a = str(val);
  return Buffer.concat([str(p), str("," + tag), a]);
}

function msg3(p, a, b, c) {
  const x = Buffer.alloc(12);
  x.writeInt32BE(a, 0); x.writeInt32BE(b, 4); x.writeInt32BE(c, 8);
  return Buffer.concat([str(p), str(",iii"), x]);
}

const bridge = spawn(process.execPath,
  [path.join(__dirname, "bridge.js"), "--osc-port", OSC, "--ws-port", WS, "--norns-port", NORNS], { stdio: "ignore" });
// the fake norns's own OSC port: what the control page sends arrives here
const nornsIn = dgram.createSocket("udp4");
const toNorns = [];
nornsIn.on("message", (b) => toNorns.push(b));
nornsIn.bind(NORNS, "127.0.0.1");
// a masked text frame, as a browser sends it
function pageFrame(obj) {
  const rep = Buffer.from(JSON.stringify(obj));
  const key = Buffer.from([9, 8, 7, 6]);
  const m = Buffer.from(rep); for (let i = 0; i < m.length; i++) m[i] ^= key[i & 3];
  const head = rep.length < 126 ? Buffer.from([0x81, 0x80 | rep.length])
    : Buffer.from([0x81, 0x80 | 126, rep.length >> 8, rep.length & 255]);
  return Buffer.concat([head, key, m]);
}
const udp = dgram.createSocket("udp4");
const send = (b) => udp.send(b, OSC, "127.0.0.1");

function page() {
  return new Promise((resolve) => {
    const sock = net.connect(WS, "127.0.0.1");
    const got = [];
    let upgraded = false, buf = Buffer.alloc(0);
    sock.on("connect", () => sock.write("GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n" +
      "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"));
    sock.on("data", (d) => {
      buf = Buffer.concat([buf, d]);
      if (!upgraded) {
        const i = buf.indexOf("\r\n\r\n");
        if (i < 0) return;
        got.push("HEAD " + buf.toString("latin1", 0, i));
        buf = buf.subarray(i + 4); upgraded = true;
      }
      while (buf.length >= 2) {
        let len = buf[1] & 0x7f, at = 2;
        if (len === 126) { len = buf.readUInt16BE(2); at = 4; }
        if (buf.length < at + len) break;
        got.push(buf.toString("utf8", at, at + len));
        buf = buf.subarray(at + len);
      }
    });
    resolve({ sock, got });
  });
}
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  await wait(500);
  send(msg("/four/size", "f", 0.25));          // before any page connects
  send(msg("/four/page_name", "s", "GRAIN"));
  send(msg("/other/thing", "f", 1));              // not ours: ignored
  send(Buffer.from("garbage"));                    // unreadable: must not crash
  await wait(200);
  const p = await page();
  await wait(300);
  ok(p.got[0] && p.got[0].includes("101 Switching Protocols"), "the handshake is accepted");
  ok(p.got[0] && p.got[0].includes("s3pPLMBiTxaQ9kYGzzhZRbK+xOo="), "the accept key matches the RFC 6455 example");
  const snap = p.got.map((g) => { try { return JSON.parse(g); } catch (e) { return null; } }).find((j) => j && j.state);
  ok(snap && Math.abs(snap.state.size - 0.25) < 1e-6, "a new page gets the last state first");
  ok(snap && snap.state.page_name === "GRAIN", "...including a string field");
  ok(snap && !("thing" in snap.state), "...and nothing outside /four/");
  send(msg("/four/density", "f", 0.5));
  send(msg("/four/mode", "i", 3));
  await wait(300);
  const live = p.got.map((g) => { try { return JSON.parse(g); } catch (e) { return null; } }).filter((j) => j && j.k);
  ok(live.some((j) => j.k === "density" && Math.abs(j.v - 0.5) < 1e-6), "a float goes out as {k,v}");
  ok(live.some((j) => j.k === "mode" && j.v === 3), "an int goes out as {k,v}");
  // an event has several arguments and is not kept as state
  send(msg3("/four/ev/note", 3, 60, 100));
  await wait(300);
  const evs = p.got.map((g) => { try { return JSON.parse(g); } catch (e) { return null; } }).filter((j) => j && j.ev);
  ok(evs.some((j) => j.ev === "note" && j.a.join() === "3,60,100"), "an event goes out as {ev,a} with all its arguments");
  // a bundle with two messages
  const a = msg("/four/cutoff", "f", 0.75), b = msg("/four/rev_mix", "f", 0.1);
  const sz = (m) => { const x = Buffer.alloc(4); x.writeInt32BE(m.length); return x; };
  send(Buffer.concat([str("#bundle"), Buffer.alloc(8), sz(a), a, sz(b), b]));
  await wait(300);
  const all = p.got.map((g) => { try { return JSON.parse(g); } catch (e) { return null; } }).filter((j) => j && j.k);
  ok(all.some((j) => j.k === "cutoff") && all.some((j) => j.k === "rev_mix"), "a bundle delivers both messages");
  // the page's own report comes back at /status (a masked text frame, as a browser sends it)
  const rep = Buffer.from(JSON.stringify({ diag: { id: "t1", playing: true, fps: 60, src: "TEST" } }));
  const key = Buffer.from([1, 2, 3, 4]);
  const masked = Buffer.from(rep); for (let i = 0; i < masked.length; i++) masked[i] ^= key[i & 3];
  p.sock.write(Buffer.concat([Buffer.from([0x81, 0x80 | rep.length]), key, masked]));
  await wait(200);
  const st = await new Promise((resolve) => {
    const c = net.connect(WS, "127.0.0.1"); let out = "";
    c.on("connect", () => c.write("GET /status HTTP/1.1\r\nHost: x\r\n\r\n"));
    c.on("data", (d) => { out += d; }); c.on("close", () => resolve(out));
  });
  ok(st.includes('"src":"TEST"') && st.includes('"fps":60'), "a page report is served at /status");
  // a page that leaves does not break the others
  p.sock.destroy();
  const p2 = await page();
  await wait(200);
  send(msg("/four/size", "f", 0.9));
  await wait(200);
  ok(p2.got.some((g) => { try { const j = JSON.parse(g); return j.k === "size" && Math.abs(j.v - 0.9) < 1e-6; } catch (e) { return false; } }), "a second page gets live messages after the first left");
  // THE CONTROL PAGE: served at /control, and its moves reach the norns as OSC
  const ctl = await new Promise((resolve) => {
    const c = net.connect(WS, "127.0.0.1"); let out = "";
    c.on("connect", () => c.write("GET /control HTTP/1.1\r\nHost: x\r\n\r\n"));
    c.on("data", (d) => { out += d; }); c.on("close", () => resolve(out));
  });
  ok(ctl.includes("200 OK") && ctl.includes("four · control"), "the control page is served at /control");
  p2.sock.write(pageFrame({ cmd: "norm", id: "t2_level", v: 0.5 }));
  p2.sock.write(pageFrame({ cmd: "press", id: "scene_recall" }));
  p2.sock.write(pageFrame({ cmd: "set", id: "../etc", v: 1 }));       // not an id: dropped
  await wait(300);
  const parsed = toNorns.map((b) => b.toString("latin1"));
  const norm = toNorns.find((b) => b.toString("latin1").startsWith("/four/norm"));
  ok(norm && norm.toString("latin1").includes(",sf") && norm.toString("latin1").includes("t2_level"),
    "a fader goes to the norns as /four/norm <id> <float>");
  ok(norm && Math.abs(norm.readFloatBE(norm.length - 4) - 0.5) < 1e-6, "...with its value");
  ok(parsed.some((s) => s.startsWith("/four/press") && s.includes("scene_recall")), "a button goes as /four/press <id>");
  ok(toNorns.length === 2, "a name that is not a param id is dropped (" + toNorns.length + " sent)");
  ok(bridge.exitCode === null, "the bridge survived garbage and a closed page");
  p2.sock.destroy(); udp.close(); nornsIn.close(); bridge.kill();
  console.log(`bridge test: ${checks - fails}/${checks} checks passed`);
  process.exit(fails ? 1 : 0);
})();
