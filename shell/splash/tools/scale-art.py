#!/usr/bin/env python3
"""Downsample ASCII art by character density, re-emitting in the same
palette. usage: scale-art.py <art.txt> <target-width> <target-height>"""
import sys, math

src = open(sys.argv[1]).read().rstrip('\n').split('\n')
W = max(len(l) for l in src)
H = len(src)
grid = [l.ljust(W) for l in src]
TW, TH = int(sys.argv[2]), int(sys.argv[3])

dens = {' ': 0.0}
for c in "'`,.": dens[c] = 0.25
for c in '"()|/\\!;:': dens[c] = 0.45
for c in 'o': dens[c] = 0.75
for c in '$': dens[c] = 1.0

out = []
for ty in range(TH):
    row = ''
    y0, y1 = ty * H / TH, (ty + 1) * H / TH
    for tx in range(TW):
        x0, x1 = tx * W / TW, (tx + 1) * W / TW
        tot = n = 0
        mx = 0.0
        for yy in range(int(y0), max(int(math.ceil(y1)), int(y0) + 1)):
            for xx in range(int(x0), max(int(math.ceil(x1)), int(x0) + 1)):
                if yy < H and xx < W:
                    d = dens.get(grid[yy][xx], 0.5)
                    tot += d
                    n += 1
                    mx = max(mx, d)
        # blend average with peak so sparse strokes (claws, whiskers)
        # survive the downsample instead of averaging into blank
        v = 0.62 * (tot / max(n, 1)) + 0.38 * mx
        if   v < 0.10: row += ' '
        elif v < 0.22: row += '.'
        elif v < 0.34: row += '"'
        elif v < 0.52: row += 'o'
        else:          row += '$'
    out.append(row.rstrip())

while out and not out[0].strip(): out.pop(0)
while out and not out[-1].strip(): out.pop()
print('\n'.join(out))
