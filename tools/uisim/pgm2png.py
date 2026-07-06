#!/usr/bin/env python3
"""PGM (P2) -> grayscale PNG with nearest-neighbor upscale. Stdlib only."""
import sys, zlib, struct, pathlib

def read_pgm(path):
    tok = path.read_text().split()
    assert tok[0] == "P2"
    w, h, maxv = int(tok[1]), int(tok[2]), int(tok[3])
    vals = [int(v) for v in tok[4:4 + w * h]]
    return w, h, vals

def write_png(path, w, h, gray_rows):
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + bytes(row) for row in gray_rows)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    path.write_bytes(png)

def main():
    src, dst, scale = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), int(sys.argv[3])
    w, h, vals = read_pgm(src)
    rows = []
    for y in range(h):
        row = []
        for x in range(w):
            row.extend([vals[y * w + x]] * scale)
        for _ in range(scale):
            rows.append(row)
    write_png(dst, w * scale, h * scale, rows)

if __name__ == "__main__":
    main()
