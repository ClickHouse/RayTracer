#!/usr/bin/env python3
# Design the "ClickHouse" banner as a 7-row ASCII bitmap.
# Caps (C, H) and ascenders (l, k) span all 7 rows.
# x-height lowercase letters (i, c, o, u, s, e) sit in rows 2..6.

glyphs = {
    'C': [
        ".###.",
        "#...#",
        "#....",
        "#....",
        "#....",
        "#...#",
        ".###.",
    ],
    'l': [
        "##.",
        ".#.",
        ".#.",
        ".#.",
        ".#.",
        ".#.",
        ".##",
    ],
    'i': [
        ".#.",
        "...",
        ".#.",
        ".#.",
        ".#.",
        ".#.",
        ".#.",
    ],
    'c': [
        "....",
        "....",
        ".###",
        "#...",
        "#...",
        "#...",
        ".###",
    ],
    'k': [
        "#...",
        "#...",
        "#.##",
        "#.#.",
        "##..",
        "#.#.",
        "#..#",
    ],
    'H': [
        "#...#",
        "#...#",
        "#...#",
        "#####",
        "#...#",
        "#...#",
        "#...#",
    ],
    'o': [
        "....",
        "....",
        ".##.",
        "#..#",
        "#..#",
        "#..#",
        ".##.",
    ],
    'u': [
        "....",
        "....",
        "#..#",
        "#..#",
        "#..#",
        "#..#",
        ".###",
    ],
    's': [
        "....",
        "....",
        ".###",
        "#...",
        ".##.",
        "...#",
        "###.",
    ],
    'e': [
        "....",
        "....",
        ".##.",
        "#..#",
        "####",
        "#...",
        ".###",
    ],
}

word = "ClickHouse"
gap = 1
rows = ["" for _ in range(7)]
for ch in word:
    g = glyphs[ch]
    w = max(len(r) for r in g)
    for i in range(7):
        line = g[i].ljust(w, '.')
        rows[i] += line + ("." * gap)

# strip trailing gap
rows = [r[:-gap] for r in rows]

for r in rows:
    print(r.replace('.', ' ').replace('#', '@'))

print()
print("width:", len(rows[0]))
print("spheres:", sum(r.count('#') for r in rows))
print()
# Emit as SQL array literal
print("[")
for r in rows:
    print("  '" + r + "',")
print("]")
