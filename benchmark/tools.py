#!/usr/bin/env python3
"""Benchmark helpers: turn a system's pixel dump into a PNG, and compare two
dumps for correctness.

Every engine emits the same thing: one row per pixel, TAB-separated
    idx  R  G  B
with R,G,B integers in [0,255] and idx the scanline pixel index (0-based,
left-to-right, top-to-bottom). That uniform format is what we diff and render
(no engine needs native image output except ClickHouse, which we bypass here).
"""
import sys
from PIL import Image

def load(path):
    px = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            idx, r, g, b = line.split('\t')
            px[int(idx)] = (int(r), int(g), int(b))
    return px

def render(tsv, w, h, out):
    px = load(tsv)
    img = Image.new('RGB', (w, h))
    img.putdata([px.get(i, (0, 0, 0)) for i in range(w * h)])
    img.save(out)
    print(f"wrote {out} ({w}x{h}, {len(px)} pixels)")

def compare(ref_path, other_path):
    ref, other = load(ref_path), load(other_path)
    keys = sorted(set(ref) | set(other))
    n = len(keys)
    if not n:
        print("no pixels"); return
    max_d = 0; sum_d = 0; within1 = 0; within4 = 0; missing = 0
    for k in keys:
        a = ref.get(k); b = other.get(k)
        if a is None or b is None:
            missing += 1; continue
        d = max(abs(a[0]-b[0]), abs(a[1]-b[1]), abs(a[2]-b[2]))
        max_d = max(max_d, d); sum_d += d
        within1 += (d <= 1); within4 += (d <= 4)
    cmp = n - missing
    print(f"pixels:            {n}")
    print(f"missing/extra:     {missing}")
    print(f"max channel diff:  {max_d}")
    print(f"mean channel diff: {sum_d/cmp:.3f}")
    print(f"within +-1:        {100*within1/cmp:.2f}%")
    print(f"within +-4:        {100*within4/cmp:.2f}%")
    ok = (missing == 0 and within4/cmp >= 0.999 and max_d <= 16)
    print(f"VERDICT:           {'MATCH' if ok else 'DIFFERENT'} "
          f"(tolerant: >=99.9% within +-4 and max diff <=16)")

if __name__ == '__main__':
    if sys.argv[1] == 'render':
        render(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5])
    elif sys.argv[1] == 'compare':
        compare(sys.argv[2], sys.argv[3])
    else:
        sys.exit("usage: tools.py render <tsv> <W> <H> <out.png>  |  compare <ref.tsv> <other.tsv>")
