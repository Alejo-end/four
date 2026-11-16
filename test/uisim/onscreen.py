"""Put a render of four's screen onto the screen of the pocket norns render,
for the README's picture (doc/four-on-pocket-norns.png).

usage: uv run --with pillow --with numpy --with scipy python \
         test/uisim/onscreen.py <device.png> <screen.png> <out.png> [debug.png]

<device.png> is an isometric render of the case with an empty, flat grey screen
(pocket-norns-cm4/export/pocket-norns-CM4-iso.png). <screen.png> is a page from
doc/ui (the README uses take-rec.png). debug.png marks the corners it found.

The device render is isometric, so the screen is a parallelogram. Its four
corners are found from the screen's flat grey, and the page is mapped onto it
with a perspective transform. The display's bottom edge is the long edge next
to the engraved name (the left and bottom corners of the parallelogram)."""
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

dev_path, scr_path, out_path = sys.argv[1:4]
dbg_path = sys.argv[4] if len(sys.argv) > 4 else None

dev = Image.open(dev_path).convert("RGB")
a = np.asarray(dev).astype(int)

# the screen glass: the flat grey at the middle of the window. Take the
# pixels close to it, then the biggest connected block of them.
from scipy import ndimage
H0, W0 = a.shape[:2]
cy, cx = H0 // 2 - 50, W0 // 2
ref = np.median(a[cy - 20:cy + 20, cx - 20:cx + 20].reshape(-1, 3), 0)
mask = (np.abs(a - ref).sum(-1) < 30)
lab, n = ndimage.label(mask)
sizes = ndimage.sum(mask, lab, range(1, n + 1))
big = 1 + int(np.argmax(sizes))
ys, xs = np.nonzero(lab == big)
print("screen grey", ref, "block", int(sizes.max()), "px")
pts = np.stack([xs, ys], 1)
left = pts[np.argmin(xs + 0.001 * ys)]
right = pts[np.argmax(xs - 0.001 * ys)]
top = pts[np.argmin(ys - 0.001 * xs)]
bottom = pts[np.argmax(ys + 0.001 * xs)]
print("corners: left", left, "top", top, "right", right, "bottom", bottom)

# display corners: top-left -> top, top-right -> right, bottom-right -> bottom,
# bottom-left -> left (see the docstring)
quad = [tuple(top), tuple(right), tuple(bottom), tuple(left)]

def inset(q, f):
    cx = sum(p[0] for p in q) / 4
    cy = sum(p[1] for p in q) / 4
    return [(cx + (x - cx) * (1 - f), cy + (y - cy) * (1 - f)) for x, y in q]

# the page: grey to a warm lit colour on black, upscaled with hard pixels
src = Image.open(scr_path).convert("L")
SW, SH = src.width * 4, src.height * 4
src = src.resize((SW, SH), Image.NEAREST)
LIT = np.array([246, 236, 214])
s = np.asarray(src).astype(float)[..., None] / 255.0
page = (np.array([7, 7, 8]) * (1 - s) + LIT * s).astype(np.uint8)
page = Image.fromarray(page, "RGB")

def coeffs(dst, srcpts):
    # PIL maps OUTPUT (dst) coordinates to INPUT (src) coordinates
    A, B = [], []
    for (x, y), (u, v) in zip(dst, srcpts):
        A.append([x, y, 1, 0, 0, 0, -u * x, -u * y]); B.append(u)
        A.append([0, 0, 0, x, y, 1, -v * x, -v * y]); B.append(v)
    return np.linalg.solve(np.array(A, float), np.array(B, float)).tolist()

out = dev.copy()
# the glass goes black first (the whole window), then the page sits inside it
glass = inset(quad, -0.01)
ImageDraw.Draw(out).polygon(glass, fill=(10, 10, 11))
active = inset(quad, 0.06)
c = coeffs(active, [(0, 0), (SW, 0), (SW, SH), (0, SH)])
warped = page.transform(out.size, Image.PERSPECTIVE, c, Image.BICUBIC)
m = Image.new("L", out.size, 0)
ImageDraw.Draw(m).polygon(active, fill=255)
# a faint glow of the lit pixels on the glass
glow = warped.filter(ImageFilter.GaussianBlur(4))
gm = m.filter(ImageFilter.GaussianBlur(3)).point(lambda v: int(v * 0.5))
out.paste(glow, (0, 0), gm)
out.paste(warped, (0, 0), m)
# crop to the device, with a margin
bx, by = np.nonzero((np.asarray(dev).astype(int).sum(-1) > 3 * 34).T)
x0, x1, y0, y1 = bx.min(), bx.max(), by.min(), by.max()
m = 60
out = out.crop((max(0, x0 - m), max(0, y0 - m), min(out.width, x1 + m), min(out.height, y1 + m)))
out.save(out_path, optimize=True)
print(out_path, out.size)

if dbg_path:
    d = dev.copy()
    dd = ImageDraw.Draw(d)
    dd.polygon(quad, outline=(255, 0, 0))
    for p, name in zip(quad, ("TL", "TR", "BR", "BL")):
        dd.text((p[0] + 4, p[1] + 4), name, fill=(255, 80, 80))
    d.save(dbg_path)
