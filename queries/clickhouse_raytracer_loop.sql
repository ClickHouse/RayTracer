-- ============================================================================
--  A path tracer in one ClickHouse SQL query -- LOOP version.
--
--  Same scene as the recursive-CTE version (the word "ClickHouse" built from a
--  union of spheres, a chrome CSG "planet" = sphere A minus sphere B, hovering
--  over a checkerboard floor under a hazy sky -- a homage to Andrew Kensler's
--  Pixar business-card ray tracer), but the bounce loop is NOT a recursive CTE.
--
--  Is recursion necessary?  No.  Bounces are *sequential* (bounce k needs the
--  reflected ray from bounce k-1), so a plain `CROSS JOIN numbers(N)` of
--  independent rows cannot express it -- but a fixed-count loop can.  Here the
--  loop is `arrayFold(... , range(maxDepth), ...)` run INSIDE each row: the
--  fold's accumulator carries the ray state (origin, direction, throughput,
--  accumulated color, alive flag) and each step advances it by one bounce.
--
--  Why this is the better default:
--    * One row per (pixel, sample) from start to finish -- no recursive frontier,
--      no GROUP BY to pick the terminal row. Rows are independent, so with
--      `numbers_mt` it parallelizes across all CPU cores. On a 96-core box this
--      renders ~6x faster than the single-threaded recursive CTE (32s vs ~3min
--      at 640x256, 24 samples).
--
--  Two ClickHouse subtleties this relies on:
--    * `WITH` lambdas are call-by-name (macro substitution): passing a value as a
--      parameter does NOT bind it -- every use re-expands the argument and blows
--      up the query tree. So intermediates are bound by value via
--          arrayMap(x -> body, [expr])[1]
--      a one-element-array "let": arrayMap's lambda parameter IS by value, so
--      each expensive sub-expression (the sphere loop, the shadow ray) is
--      evaluated exactly once. `oneBounce` is a stack of these lets.
--    * `arrayFold`'s accumulator type must match every iteration exactly, so the
--      ray state is kept all-Float64 (the alive flag too: 1.0 / 0.0).
--
--  Run it:
--      clickhouse local --queries-file clickhouse_raytracer_loop.sql > clickhouse.png
--
--  Knobs: output_format_image_width/height (+ imgW/imgH and the numbers_mt(W*H)
--  / % W literals), range(N) AS sample (samples/pixel), maxDepth (bounces).
-- ============================================================================
WITH
    ['.###..##...#.......#....#...#....................', '#...#..#...........#....#...#....................', '#......#...#...###.#.##.#...#..##..#..#..###..##.', '#......#...#..#....#.#..#####.#..#.#..#.#....#..#', '#......#...#..#....##...#...#.#..#.#..#..##..####', '#...#..#...#..#....#.#..#...#.#..#.#..#....#.#...', '.###...##..#...###.#..#.#...#..##...###.###...###'] AS banner,
    49 AS bannerW, 7 AS bannerH,
    1.0 AS spacing, 0.92 AS radius, 3.0 AS z0,
    (24.0, 0.0, 6.0)    AS target,
    (24.0, -42.0, 12.0) AS eye,
    34.0 AS fovDeg,
    640.0 AS imgW, 256.0 AS imgH,
    4 AS maxDepth,
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
    ((s, lpos) -> arrayMap(o -> arrayMap(d -> arrayMap(thr -> arrayMap(acc -> arrayMap(hits -> arrayMap(tP -> arrayMap(pairA -> arrayMap(pairB -> arrayMap(tS -> arrayMap(cEnter -> arrayMap(cCav -> arrayMap(tC -> arrayMap(tM -> arrayMap(tHit -> arrayMap(hp -> arrayMap(sn -> arrayMap(isMirror -> arrayMap(isFloor -> arrayMap(isMiss -> arrayMap(nrm -> arrayMap(shOrig -> arrayMap(rdir -> arrayMap(ldir -> arrayMap(distL -> arrayMap(shadowed -> arrayMap(spec -> arrayMap(lambert -> arrayMap(fog -> arrayMap(floorCol -> (
        if(isMirror, shOrig, o),
        if(isMirror, rdir, d),
        if(isMirror, thr * reflect_k, thr),
        va(acc, va(if(isMirror, vm(specColor, thr * spec), (0.0, 0.0, 0.0)),
                   va(if(isFloor, vm(floorCol, thr), (0.0, 0.0, 0.0)),
                      if(isMiss, vm(sky(d), thr), (0.0, 0.0, 0.0))))),
        if(isMirror, 1.0, 0.0)), [va(vm(vm(if(checker(hp) = 0, floorA, floorB), floorAmb + floorDiff * lambert), 1.0 - fog), vm(hazeColor, fog))])[1], [least(1.0, greatest(0.0, (tHit - fogStart) / fogRange))])[1], [greatest(vd(ldir, (0.0, 0.0, 1.0)), 0.0) * if(shadowed, 0.0, 1.0)])[1], [pow(greatest(vd(ldir, rdir), 0.0), shininess) * if(shadowed, 0.0, 1.0)])[1], [occluded(shOrig, ldir, distL - 0.05)])[1], [L2Norm(vs(lpos, hp))])[1], [vn(vs(lpos, hp))])[1], [vref(d, sn)])[1], [va(hp, vm(nrm, eps * 2.0))])[1], [if(isFloor, (0.0, 0.0, 1.0), sn)])[1], [(tM >= 1e8) AND (tP >= 1e8)])[1], [(tP <= tM) AND (tP < 1e8)])[1], [(tM < tP) AND (tM < 1e8)])[1], [if(tC < tS, if(cEnter <= cCav, vn(vs(hp, csgA)), vn(vs(csgB, hp))), vn(vs(hp, spheres[indexOf(hits, tS)])))])[1], [va(o, vm(d, tHit))])[1], [least(tM, tP)])[1], [least(tS, tC)])[1], [least(cEnter, cCav)])[1], [if(pairB.1 < 1e8 AND pairB.2 > eps AND pairA.1 <= pairB.2 AND pairB.2 <= pairA.2, pairB.2, 1e9)])[1], [if(pairA.1 > eps AND pairA.1 < 1e8 AND NOT (pairB.1 <= pairA.1 AND pairA.1 <= pairB.2), pairA.1, 1e9)])[1], [arrayMin(hits)])[1], [sphPair(o, d, csgB, csgBr)])[1], [sphPair(o, d, csgA, csgAr)])[1], [planeT(o, d)])[1], [sphereHits(o, d)])[1], [s.4])[1], [s.3])[1], [s.2])[1], [s.1])[1]) AS oneBounce

SELECT
    clamp(pow(greatest(avg(col.1), 0.0) * exposure, 1.0 / gamma), 0.0, 1.0) AS r,
    clamp(pow(greatest(avg(col.2), 0.0) * exposure, 1.0 / gamma), 0.0, 1.0) AS g,
    clamp(pow(greatest(avg(col.3), 0.0) * exposure, 1.0 / gamma), 0.0, 1.0) AS b,
    pixel % 640      AS x,                          /* explicit PNG coordinates: no ORDER BY needed */
    intDiv(pixel, 640) AS y
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
              vn(va(camFwd, va(vm(camRight, (((number % 640) + rnd(number, sample, 1)) / imgW * 2.0 - 1.0) * aspect * tanHalf),
                                vm(camUp,    (1.0 - (intDiv(number, 640) + rnd(number, sample, 2)) / imgH * 2.0) * tanHalf)))),
              1.0, (0.0, 0.0, 0.0), 1.0) AS Tuple(Tuple(Float64,Float64,Float64), Tuple(Float64,Float64,Float64), Float64, Tuple(Float64,Float64,Float64), Float64)) AS st0
      FROM numbers_mt(640 * 256)
      ARRAY JOIN range(24) AS sample
    )
  )
)
GROUP BY pixel
SETTINGS output_format_image_width = 640, output_format_image_height = 256,
         max_block_size = 2048,
         optimize_and_compare_chain = 0
FORMAT PNG
