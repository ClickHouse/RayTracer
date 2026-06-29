#!/usr/bin/env python3
"""Generate a self-contained ClickHouse SQL query that path-traces the word
"ClickHouse" (built from spheres, in the spirit of Andrew Kensler's Pixar
business-card ray tracer) and emits it via the PNG output format.

The light transport is expressed as a WITH RECURSIVE CTE: each iteration
advances every live ray by one bounce, so the query text stays a single
stage regardless of the maximum bounce depth."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import font

# ---- Tunable parameters -------------------------------------------------
W       = int(sys.argv[1]) if len(sys.argv) > 1 else 320   # image width
H       = int(sys.argv[2]) if len(sys.argv) > 2 else 128   # image height
SAMPLES = int(sys.argv[3]) if len(sys.argv) > 3 else 4     # samples per pixel
DEPTH   = int(sys.argv[4]) if len(sys.argv) > 4 else 4     # max ray bounces
TEXT    = sys.argv[5] if len(sys.argv) > 5 else "ClickHouse"  # word(s) to render

# ---- Build the banner (7 rows, '#' = a sphere) from the text ------------
BANNER, bannerW = font.banner(TEXT)
bannerH = font.ROWS

# Recenter the camera / light / hero sphere on the banner's midpoint so any
# length of text stays framed. The original "ClickHouse" banner is 49 wide,
# whose center (x = 24) the scene was hand-tuned around, so dx = 0 there and
# the default render is unchanged.
cx = (bannerW - 1) / 2.0
dx = cx - 24.0
def fx(x):
    return repr(round(x + dx, 4))   # shift an x-coordinate and format it

def sql_str_array(rows):
    return "[" + ", ".join("'" + r + "'" for r in rows) + "]"

# ---- Constants and helper lambdas (the WITH prelude) --------------------
PRELUDE = f"""WITH RECURSIVE
    /* ----- scene / camera constants ----- */
    {sql_str_array(BANNER)} AS banner,
    {bannerW}        AS bannerW,
    {bannerH}         AS bannerH,
    1.0       AS spacing,         /* grid spacing between sphere centers */
    0.92      AS radius,          /* sphere radius (overlap -> solid strokes) */
    3.0       AS z0,              /* world z of the lowest text row */
    ({fx(24.0)}, 0.0, 6.0)    AS target,        /* center of the text block */
    ({fx(24.0)}, -42.0, 12.0) AS eye,           /* camera position (in front, -y) */
    34.0      AS fovDeg,          /* vertical field of view, degrees */
    getSetting('output_format_image_width')::UInt64  AS W,
    getSetting('output_format_image_height')::UInt64 AS H,
    W::Float64     AS imgW,
    H::Float64     AS imgH,
    {DEPTH}   AS maxDepth,        /* number of ray-trace bounces */
    ({fx(9.0)}, -30.0, 52.0)  AS lightPos,      /* area-light center */
    5.0       AS lightR,          /* area-light radius (soft shadows) */
    (0.42, 0.60, 0.95)  AS skyColor,      /* base sky tint */
    (0.66, 0.78, 0.96)  AS hazeColor,     /* horizon haze the floor fades into */
    35.0      AS fogStart,        /* floor distance where the haze begins */
    120.0     AS fogRange,        /* floor distance over which it fully fades */
    (0.90, 0.27, 0.23)  AS floorA,        /* checkerboard color A */
    (0.93, 0.93, 0.95)  AS floorB,        /* checkerboard color B */
    5.0       AS tile,            /* checkerboard tile size */
    0.30      AS floorAmb,        /* floor ambient term */
    0.85      AS floorDiff,       /* floor diffuse strength */
    (1.0, 1.0, 1.0)     AS specColor,     /* specular highlight color */
    60.0      AS shininess,       /* specular exponent */
    0.72      AS reflect_k,       /* mirror reflectivity of the letters */

    /* ----- a Constructive Solid Geometry hero object: a chrome sphere with a
            spherical cavity carved out of it (solid = sphere csgA MINUS sphere csgB) ----- */
    ({fx(24.0)}, 12.0, 17.5)  AS csgA,          /* big sphere center (floats above the word) */
    6.0       AS csgAr,           /* big sphere radius */
    ({fx(24.0)}, 6.6, 17.0)   AS csgB,          /* cutter sphere center (faces the camera) */
    4.4       AS csgBr,           /* cutter sphere radius */
    1.15      AS exposure,
    2.2       AS gamma,
    0.002     AS eps,

    /* ----- vector helpers on Tuple(Float64, Float64, Float64) ----- */
    ((a, b) -> tuplePlus(a, b))                                   AS va,   /* add */
    ((a, b) -> tupleMinus(a, b))                                  AS vs,   /* subtract */
    ((a, s) -> tupleMultiplyByNumber(a, s))                       AS vm,   /* scale by scalar */
    ((a, b) -> dotProduct(a, b))                                  AS vd,   /* dot product */
    ((a)    -> L2Normalize(a))                                    AS vn,   /* normalize */
    ((a, b) -> (a.2*b.3 - a.3*b.2, a.3*b.1 - a.1*b.3, a.1*b.2 - a.2*b.1)) AS vc, /* cross */
    ((d, n) -> tupleMinus(d, tupleMultiplyByNumber(n, 2.0 * dotProduct(d, n)))) AS vref, /* reflect */

    /* ----- build the sphere centers from the banner bitmap ----- */
    arrayMap(c -> (c.1 * spacing, 0.0, (toFloat64(bannerH - 1) - c.2) * spacing + z0),
      arrayFilter(c -> substring(banner[c.2 + 1], c.1 + 1, 1) = '#',
        arrayFlatten(arrayMap(gy -> arrayMap(gx -> (gx, gy), range(bannerW)), range(bannerH)))
      )
    ) AS spheres,

    /* ----- camera basis (computed once) ----- */
    L2Normalize(tupleMinus(target, eye))                          AS camFwd,
    L2Normalize(vc(L2Normalize(tupleMinus(target, eye)), (0.0, 0.0, 1.0))) AS camRight,
    vc(camRight, camFwd)                                          AS camUp,
    tan(fovDeg * 0.5 * pi() / 180.0)                              AS tanHalf,
    imgW / imgH                                                   AS aspect,
    radius * radius                                               AS r2,

    /* ----- ray-sphere intersection (returns distance or 1e9) ----- */
    ((p, d) -> if(
        dotProduct(p, d) * dotProduct(p, d) - (dotProduct(p, p) - r2) > 0.0
        AND -dotProduct(p, d) - sqrt(greatest(dotProduct(p, d) * dotProduct(p, d) - (dotProduct(p, p) - r2), 0.0)) > eps,
        -dotProduct(p, d) - sqrt(greatest(dotProduct(p, d) * dotProduct(p, d) - (dotProduct(p, p) - r2), 0.0)),
        1e9)) AS sphereT,
    ((o, d) -> arrayMap(c -> sphereT(vs(o, c), d), spheres))      AS sphereHits,
    /* the near and far ray parameters of a sphere, or (1e9, -1e9) if missed */
    ((o, d, c, rad) -> if(
        dotProduct(vs(o,c), d) * dotProduct(vs(o,c), d) - (dotProduct(vs(o,c), vs(o,c)) - rad*rad) > 0.0,
        (-dotProduct(vs(o,c), d) - sqrt(greatest(dotProduct(vs(o,c), d) * dotProduct(vs(o,c), d) - (dotProduct(vs(o,c), vs(o,c)) - rad*rad), 0.0)),
         -dotProduct(vs(o,c), d) + sqrt(greatest(dotProduct(vs(o,c), d) * dotProduct(vs(o,c), d) - (dotProduct(vs(o,c), vs(o,c)) - rad*rad), 0.0))),
        (1e9, -1e9))) AS sphPair,
    /* distance to the floor plane z = 0, or 1e9 if not seen from above */
    ((o, d) -> if(d.3 < -eps AND o.3 > 0.0, -o.3 / d.3, 1e9))     AS planeT,
    /* is the segment from o toward d (length maxd) blocked by a text sphere? */
    ((o, d, maxd) -> arrayExists(c -> sphereT(vs(o, c), d) < maxd, spheres)) AS occluded,
    /* sky color for a ray that escaped the scene */
    ((d) -> tupleMultiplyByNumber(skyColor, 0.35 + 0.65 * pow(greatest(1.0 - d.3, 0.0), 3.0))) AS sky,
    /* checkerboard parity at a floor point */
    ((p) -> (toInt64(floor(p.1 / tile)) + toInt64(floor(p.2 / tile))) % 2) AS checker,
    /* deterministic pseudo-random number in [0, 1) from a seed triple */
    ((a, b, c) -> (cityHash64(a, b, c) % 1048576) / 1048576.0)    AS rnd,
"""

# ---- BASE term of the recursion: one primary ray per (pixel, sample) ----
BASE = """  (
    SELECT
      toInt32(0)                               AS depth,
      pixel, sample, lpos,
      eye                                      AS o,
      vn(va(camFwd, va(vm(camRight, ndcx), vm(camUp, ndcy)))) AS d,
      CAST(1.0 AS Float64)                     AS thr,
      CAST((0.0, 0.0, 0.0) AS Tuple(Float64, Float64, Float64)) AS acc,
      toUInt8(1)                               AS alive
    FROM (
      SELECT
        number AS pixel,
        sample,
        va(lightPos, (lightR * (rnd(pixel, sample, 3) - 0.5),
                      lightR * (rnd(pixel, sample, 4) - 0.5),
                      lightR * (rnd(pixel, sample, 5) - 0.5))) AS lpos,
        (((pixel % W) + rnd(pixel, sample, 1)) / imgW * 2.0 - 1.0) * aspect * tanHalf AS ndcx,
        (1.0 - (intDiv(pixel, W) + rnd(pixel, sample, 2)) / imgH * 2.0) * tanHalf      AS ndcy
      FROM numbers(W * H)
      ARRAY JOIN range({SAMPLES:UInt32}) AS sample
    )
  )""".replace("{W}", str(W)).replace("{H}", str(H)).replace("{S}", str(SAMPLES))

# ---- RECURSIVE term: advance every live ray by exactly one bounce -------
# Nested subquery levels keep each expensive sphere-loop (sphereHits /
# occluded) computed once and referenced as plain columns downstream.
RECURSE = """  (
    SELECT
      depth + 1                                AS depth,
      pixel, sample, lpos,
      if(isMirror, shOrig, o)                  AS o,
      if(isMirror, rdir, d)                    AS d,
      if(isMirror, thr * reflect_k, thr)       AS thr,
      va(acc,
         va(if(isMirror, vm(specColor, thr * spec), (0.0, 0.0, 0.0)),
            va(if(isFloor, vm(floorCol, thr), (0.0, 0.0, 0.0)),
               if(isMiss, vm(sky(d), thr), (0.0, 0.0, 0.0))))) AS acc,
      if(isMirror, toUInt8(1), toUInt8(0))     AS alive
    FROM (
      /* level 3: shading (occluded computed once, as a column) */
      SELECT
        depth, pixel, sample, lpos, o, d, thr, acc,
        isMirror, isFloor, isMiss, hp, rdir,
        va(hp, vm(nrm, eps * 2.0))             AS shOrig,
        occluded(shOrig, ldir, distL - 0.05)   AS shadowed,
        pow(greatest(vd(ldir, rdir), 0.0), shininess) * if(shadowed, 0.0, 1.0) AS spec,
        greatest(vd(ldir, (0.0, 0.0, 1.0)), 0.0) * if(shadowed, 0.0, 1.0)      AS lambert,
        least(1.0, greatest(0.0, (tHit - fogStart) / fogRange)) AS fog,
        va(vm(vm(if(checker(hp) = 0, floorA, floorB), floorAmb + floorDiff * lambert), 1.0 - fog),
           vm(hazeColor, fog))                 AS floorCol
      FROM (
        /* level 2: nearest hit, geometry, surface vectors. Mirror surfaces are
           the text spheres OR the CSG object (sphere csgA minus sphere csgB). */
        SELECT
          depth, pixel, sample, lpos, o, d, thr, acc, alive, tP,
          arrayMin(hits)                       AS tS,
          /* CSG A-B: enter A where not inside B, or exit B (the cavity wall) where inside A */
          if(pairA.1 > eps AND pairA.1 < 1e8 AND NOT (pairB.1 <= pairA.1 AND pairA.1 <= pairB.2),
             pairA.1, 1e9)                     AS cEnter,
          if(pairB.1 < 1e8 AND pairB.2 > eps AND pairA.1 <= pairB.2 AND pairB.2 <= pairA.2,
             pairB.2, 1e9)                     AS cCav,
          least(cEnter, cCav)                  AS tC,
          least(tS, tC)                        AS tM,
          least(tM, tP)                        AS tHit,
          va(o, vm(d, tHit))                   AS hp,
          /* normal of the chosen mirror surface */
          if(tC < tS,
             if(cEnter <= cCav, vn(vs(hp, csgA)), vn(vs(csgB, hp))),
             vn(vs(hp, spheres[indexOf(hits, tS)]))) AS sn,
          alive AND (tM < tP) AND (tM < 1e8)   AS isMirror,
          alive AND (tP <= tM) AND (tP < 1e8)  AS isFloor,
          alive AND (tM >= 1e8) AND (tP >= 1e8) AS isMiss,
          if(isFloor, (0.0, 0.0, 1.0), sn)     AS nrm,
          vref(d, sn)                          AS rdir,
          vn(vs(lpos, hp))                     AS ldir,
          L2Norm(vs(lpos, hp))                 AS distL
        FROM (
          /* level 1: ray-vs-scene distances */
          SELECT
            depth, pixel, sample, lpos, o, d, thr, acc, alive,
            sphereHits(o, d)                   AS hits,
            planeT(o, d)                       AS tP,
            sphPair(o, d, csgA, csgAr)         AS pairA,
            sphPair(o, d, csgB, csgBr)         AS pairB
          FROM trace
          WHERE alive AND depth < maxDepth
        )
      )
    )
  )"""

# ---- final: add sky for still-live rays, average samples, tone map ------
QUERY = f"""{PRELUDE}
    trace AS (
{BASE}
      UNION ALL
{RECURSE}
    )
SELECT
    clamp(pow(greatest(avg(col.1), 0.0) * exposure, 1.0 / gamma), 0.0, 1.0) AS r,
    clamp(pow(greatest(avg(col.2), 0.0) * exposure, 1.0 / gamma), 0.0, 1.0) AS g,
    clamp(pow(greatest(avg(col.3), 0.0) * exposure, 1.0 / gamma), 0.0, 1.0) AS b,
    pixel % W      AS x,                          /* explicit PNG coordinates: no ORDER BY needed */
    intDiv(pixel, W) AS y
FROM (
  /* per sample, the terminal ray (max depth) holds the fully accumulated color */
  SELECT pixel, argMax(va(acc, if(alive, vm(sky(d), thr), (0.0, 0.0, 0.0))), depth) AS col
  FROM trace
  GROUP BY pixel, sample
)
GROUP BY pixel
SETTINGS max_block_size = 2048,
         max_recursive_cte_evaluation_depth = 64,
         optimize_and_compare_chain = 0
FORMAT PNG
"""

sys.stdout.write(QUERY)
