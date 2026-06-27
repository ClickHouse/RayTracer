#!/usr/bin/env python3
"""Same path tracer as gen.py, but the bounce loop is an arrayFold over
range(maxDepth) instead of a WITH RECURSIVE CTE.

The whole light path for a (pixel, sample) lives in ONE row: the fold's
accumulator carries the ray state (origin, direction, throughput, accumulated
color, alive flag) and each step advances it by one bounce. Because rows are
independent, this parallelizes across all CPU cores.

Since ClickHouse has no immediately-applied lambdas, each per-bounce
intermediate that is reused (or expensive) is bound once by passing it as a
parameter down a small tower of helper lambdas (b1..b7), mirroring exactly the
subquery levels the recursive version used."""
import sys

W       = int(sys.argv[1]) if len(sys.argv) > 1 else 320
H       = int(sys.argv[2]) if len(sys.argv) > 2 else 128
SAMPLES = int(sys.argv[3]) if len(sys.argv) > 3 else 4
DEPTH   = int(sys.argv[4]) if len(sys.argv) > 4 else 4

BANNER = [
    '.###..##...#.......#....#...#....................',
    '#...#..#...........#....#...#....................',
    '#......#...#...###.#.##.#...#..##..#..#..###..##.',
    '#......#...#..#....#.#..#####.#..#.#..#.#....#..#',
    '#......#...#..#....##...#...#.#..#.#..#..##..####',
    '#...#..#...#..#....#.#..#...#.#..#.#..#....#.#...',
    '.###...##..#...###.#..#.#...#..##...###.###...###',
]
ST = "Tuple(Tuple(Float64,Float64,Float64), Tuple(Float64,Float64,Float64), Float64, Tuple(Float64,Float64,Float64), Float64)"

def arr(rows):
    return "[" + ", ".join("'" + r + "'" for r in rows) + "]"

# "let name = expr in body" implemented as arrayMap(name -> body, [expr])[1].
# arrayMap's lambda parameter is bound by value, so each expr is evaluated once
# and the AST does not blow up no matter how many times the name is referenced.
def lets(bindings, body):
    for name, expr in reversed(bindings):
        body = f"arrayMap({name} -> {body}, [{expr}])[1]"
    return body

# The bounce, as a sequence of by-value bindings (s = ray state, lpos = light).
_BIND = [
    ("o",   "s.1"),
    ("d",   "s.2"),
    ("thr", "s.3"),
    ("acc", "s.4"),
    ("hits",   "sphereHits(o, d)"),
    ("tP",     "planeT(o, d)"),
    ("pairA",  "sphPair(o, d, csgA, csgAr)"),
    ("pairB",  "sphPair(o, d, csgB, csgBr)"),
    ("tS",     "arrayMin(hits)"),
    ("cEnter", "if(pairA.1 > eps AND pairA.1 < 1e8 AND NOT (pairB.1 <= pairA.1 AND pairA.1 <= pairB.2), pairA.1, 1e9)"),
    ("cCav",   "if(pairB.1 < 1e8 AND pairB.2 > eps AND pairA.1 <= pairB.2 AND pairB.2 <= pairA.2, pairB.2, 1e9)"),
    ("tC",     "least(cEnter, cCav)"),
    ("tM",     "least(tS, tC)"),
    ("tHit",   "least(tM, tP)"),
    ("hp",     "va(o, vm(d, tHit))"),
    ("sn",     "if(tC < tS, if(cEnter <= cCav, vn(vs(hp, csgA)), vn(vs(csgB, hp))), vn(vs(hp, spheres[indexOf(hits, tS)])))"),
    ("isMirror", "(tM < tP) AND (tM < 1e8)"),
    ("isFloor",  "(tP <= tM) AND (tP < 1e8)"),
    ("isMiss",   "(tM >= 1e8) AND (tP >= 1e8)"),
    ("nrm",    "if(isFloor, (0.0, 0.0, 1.0), sn)"),
    ("shOrig", "va(hp, vm(nrm, eps * 2.0))"),
    ("rdir",   "vref(d, sn)"),
    ("ldir",   "vn(vs(lpos, hp))"),
    ("distL",  "L2Norm(vs(lpos, hp))"),
    ("shadowed", "occluded(shOrig, ldir, distL - 0.05)"),
    ("spec",   "pow(greatest(vd(ldir, rdir), 0.0), shininess) * if(shadowed, 0.0, 1.0)"),
    ("lambert","greatest(vd(ldir, (0.0, 0.0, 1.0)), 0.0) * if(shadowed, 0.0, 1.0)"),
    ("fog",    "least(1.0, greatest(0.0, (tHit - fogStart) / fogRange))"),
    ("floorCol", "va(vm(vm(if(checker(hp) = 0, floorA, floorB), floorAmb + floorDiff * lambert), 1.0 - fog), vm(hazeColor, fog))"),
]
_BODY = """(
        if(isMirror, shOrig, o),
        if(isMirror, rdir, d),
        if(isMirror, thr * reflect_k, thr),
        va(acc, va(if(isMirror, vm(specColor, thr * spec), (0.0, 0.0, 0.0)),
                   va(if(isFloor, vm(floorCol, thr), (0.0, 0.0, 0.0)),
                      if(isMiss, vm(sky(d), thr), (0.0, 0.0, 0.0))))),
        if(isMirror, 1.0, 0.0))"""
ONE_BOUNCE = lets(_BIND, _BODY)

PRELUDE = f"""WITH
    {arr(BANNER)} AS banner,
    49 AS bannerW, 7 AS bannerH,
    1.0 AS spacing, 0.92 AS radius, 3.0 AS z0,
    (24.0, 0.0, 6.0)    AS target,
    (24.0, -42.0, 12.0) AS eye,
    34.0 AS fovDeg,
    {W}.0 AS imgW, {H}.0 AS imgH,
    {DEPTH} AS maxDepth,
    (9.0, -30.0, 52.0)  AS lightPos,
    5.0 AS lightR,
    (0.42, 0.60, 0.95)  AS skyColor,
    (0.66, 0.78, 0.96)  AS hazeColor,
    35.0 AS fogStart, 120.0 AS fogRange,
    (0.90, 0.27, 0.23)  AS floorA,
    (0.93, 0.93, 0.95)  AS floorB,
    5.0 AS tile, 0.30 AS floorAmb, 0.85 AS floorDiff,
    (1.0, 1.0, 1.0)     AS specColor,
    60.0 AS shininess, 0.72 AS reflect_k,
    (24.0, 12.0, 17.5)  AS csgA, 6.0 AS csgAr,
    (24.0, 6.6, 17.0)   AS csgB, 4.4 AS csgBr,
    1.15 AS exposure, 2.2 AS gamma, 0.002 AS eps,

    ((a, b) -> tuplePlus(a, b))                                   AS va,
    ((a, b) -> tupleMinus(a, b))                                  AS vs,
    ((a, s) -> tupleMultiplyByNumber(a, s))                       AS vm,
    ((a, b) -> dotProduct(a, b))                                  AS vd,
    ((a)    -> L2Normalize(a))                                    AS vn,
    ((a, b) -> (a.2*b.3 - a.3*b.2, a.3*b.1 - a.1*b.3, a.1*b.2 - a.2*b.1)) AS vc,
    ((d, n) -> tupleMinus(d, tupleMultiplyByNumber(n, 2.0 * dotProduct(d, n)))) AS vref,

    arrayMap(c -> (c.1 * spacing, 0.0, (toFloat64(bannerH - 1) - c.2) * spacing + z0),
      arrayFilter(c -> substring(banner[c.2 + 1], c.1 + 1, 1) = '#',
        arrayFlatten(arrayMap(gy -> arrayMap(gx -> (gx, gy), range(bannerW)), range(bannerH))))) AS spheres,

    L2Normalize(tupleMinus(target, eye))                          AS camFwd,
    L2Normalize(vc(L2Normalize(tupleMinus(target, eye)), (0.0, 0.0, 1.0))) AS camRight,
    vc(camRight, camFwd)                                          AS camUp,
    tan(fovDeg * 0.5 * pi() / 180.0)                              AS tanHalf,
    imgW / imgH AS aspect, radius * radius AS r2,

    ((p, d) -> if(
        dotProduct(p, d) * dotProduct(p, d) - (dotProduct(p, p) - r2) > 0.0
        AND -dotProduct(p, d) - sqrt(greatest(dotProduct(p, d) * dotProduct(p, d) - (dotProduct(p, p) - r2), 0.0)) > eps,
        -dotProduct(p, d) - sqrt(greatest(dotProduct(p, d) * dotProduct(p, d) - (dotProduct(p, p) - r2), 0.0)),
        1e9)) AS sphereT,
    ((o, d) -> arrayMap(c -> sphereT(vs(o, c), d), spheres))      AS sphereHits,
    ((o, d, c, rad) -> if(
        dotProduct(vs(o,c), d) * dotProduct(vs(o,c), d) - (dotProduct(vs(o,c), vs(o,c)) - rad*rad) > 0.0,
        (-dotProduct(vs(o,c), d) - sqrt(greatest(dotProduct(vs(o,c), d) * dotProduct(vs(o,c), d) - (dotProduct(vs(o,c), vs(o,c)) - rad*rad), 0.0)),
         -dotProduct(vs(o,c), d) + sqrt(greatest(dotProduct(vs(o,c), d) * dotProduct(vs(o,c), d) - (dotProduct(vs(o,c), vs(o,c)) - rad*rad), 0.0))),
        (1e9, -1e9))) AS sphPair,
    ((o, d) -> if(d.3 < -eps AND o.3 > 0.0, -o.3 / d.3, 1e9))     AS planeT,
    ((o, d, maxd) -> arrayExists(c -> sphereT(vs(o, c), d) < maxd, spheres)) AS occluded,
    ((d) -> tupleMultiplyByNumber(skyColor, 0.35 + 0.65 * pow(greatest(1.0 - d.3, 0.0), 3.0))) AS sky,
    ((p) -> (toInt64(floor(p.1 / tile)) + toInt64(floor(p.2 / tile))) % 2) AS checker,
    ((a, b, c) -> (cityHash64(a, b, c) % 1048576) / 1048576.0)    AS rnd,

    /* ---- one full bounce of a ray. Each intermediate is bound exactly once via
            arrayMap(x -> body, [expr])[1] -- a by-value "let", since arrayMap's
            lambda parameter is bound by value (unlike WITH-lambda macro args). ---- */
    ((s, lpos) -> {ONE_BOUNCE}) AS oneBounce
"""

QUERY = PRELUDE + f"""
SELECT
    clamp(pow(greatest(avg(col.1), 0.0) * exposure, 1.0 / gamma), 0.0, 1.0) AS r,
    clamp(pow(greatest(avg(col.2), 0.0) * exposure, 1.0 / gamma), 0.0, 1.0) AS g,
    clamp(pow(greatest(avg(col.3), 0.0) * exposure, 1.0 / gamma), 0.0, 1.0) AS b
FROM (
  SELECT pixel, va(st.4, if(st.5 > 0.5, vm(sky(st.2), st.3), (0.0,0.0,0.0))) AS col
  FROM (
    SELECT pixel,
      /* the bounce loop: a fold over range(maxDepth), not recursion */
      arrayFold((s, i) -> if(s.5 > 0.5, oneBounce(s, lpos), s), range(maxDepth), st0) AS st
    FROM (
      SELECT
        number AS pixel, sample,
        va(lightPos, (lightR * (rnd(number, sample, 3) - 0.5),
                      lightR * (rnd(number, sample, 4) - 0.5),
                      lightR * (rnd(number, sample, 5) - 0.5))) AS lpos,
        CAST((eye,
              vn(va(camFwd, va(vm(camRight, (((number % {W}) + rnd(number, sample, 1)) / imgW * 2.0 - 1.0) * aspect * tanHalf),
                                vm(camUp,    (1.0 - (intDiv(number, {W}) + rnd(number, sample, 2)) / imgH * 2.0) * tanHalf)))),
              1.0, (0.0, 0.0, 0.0), 1.0) AS {ST}) AS st0
      FROM numbers_mt({W} * {H})
      ARRAY JOIN range({SAMPLES}) AS sample
    )
  )
)
GROUP BY pixel
ORDER BY pixel
SETTINGS output_format_image_width = {W}, output_format_image_height = {H}
FORMAT PNG
"""

sys.stdout.write(QUERY)
