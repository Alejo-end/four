#!/usr/bin/env python3
"""Find what holds the screen up (the user, 2026-11-25: "ui freezes at times").

    export NORNS_CTL=<control socket>       # see norns.py
    python3 test/device/freeze.py 120       # watch for 120 s while somebody plays

A norns clock that sleeps 20 ms logs each time it woke more than 120 ms late: Lua was
held, or the norns was. With it: the page, what was running, and the memory Lua held before
and after (a fall is the garbage collector). The same seconds carry the busiest threads and
the frame count, so a stall of Lua, of the screen and of the network read apart.
"""
import os
import re
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(__file__))
from norns import Norns  # noqa: E402

SECS = float(sys.argv[1]) if len(sys.argv) > 1 else 60
WATCH = """
if __fz then clock.cancel(__fz.id) end
__fz = { log = {}, n = 0 }
__fz.id = clock.run(function()
  local last, mem = util.time(), collectgarbage("count")
  while true do
    clock.sleep(0.02)
    local now, m = util.time(), collectgarbage("count")
    __fz.n = __fz.n + 1
    if now - last > 0.12 then
      local c = __ctx
      __fz.log[#__fz.log + 1] = string.format("%.2f held %.0f ms page %s menu %s rec %s morph %s lua %.0f to %.0f KB",
        now, (now - last) * 1000, tostring(c and c.PAGES[c.page]), tostring(norns.menu.status()), tostring(params:get("rec")),
        tostring(params:get("scene_morph_amt")), mem, m)
    end
    last, mem = now, m
  end
end)
print("@fz on")
"""
n = Norns()
n.helpers()
n.lua(WATCH)
busy, stop = [], threading.Event()


def top():
    while not stop.is_set():
        _, rows = n.threads(3, 5)
        busy.append((time.strftime("%H:%M:%S"), [(name, cpu) for name, cpu, _ in rows]))


t = threading.Thread(target=top, daemon=True)
t.start()
start, slow = time.time(), []
f0 = int(re.findall(r"\d+", n.ctx("c.frame"))[-1])
while time.time() - start < SECS:
    a = time.time()
    try:
        n.lua("print(1)", timeout=20)
    except TimeoutError:
        slow.append((time.strftime("%H:%M:%S"), "no answer in 20 s"))
    else:
        if time.time() - a > 0.4:
            slow.append((time.strftime("%H:%M:%S"), f"{(time.time() - a) * 1000:.0f} ms"))
    time.sleep(0.5)
el = time.time() - start
stop.set()
f1 = int(re.findall(r"\d+", n.lua("print(__ctx.frame)", timeout=60))[-1])
print(f"{(f1 - f0) / el:.1f} frames a second (15 is right)")
print("the REPL was slow (Lua, or the network):", slow)
# the watcher itself must have lived to the end, or "never" means nothing
alive = n.lua('print("@fz " .. tostring(__fz ~= nil and __fz.n))', timeout=60).split("@fz")[-1].strip()
print("the watcher woke", alive, "times (about", round(el * 40), "is right)")
print("@ Lua held:")
print(n.lua('for _, l in ipairs(__fz.log) do print(l) end clock.cancel(__fz.id) __fz = nil', timeout=20) or "never")
for row in busy:
    print(*row)
