-- ============================================================================
--  A path tracer in one ClickHouse SQL query -- "ClickHouse" carved from
--  Constructive Solid Geometry primitives, rendered to a black & yellow scene.
--
--  Each glyph is built from real solids:
--    * CYLINDERS (round rods with flat end caps) for the straight strokes:
--      l, i's stem, k's stem and both angled arms, H, u's two verticals.
--      -> ray vs (clamped infinite cylinder) union two cap disks.
--    * TORI (a tube swept around a circle) for the round letters c, o, u, s, e.
--      Curves/arcs subtract a box for the opening (c, s, e, u's bottom). Tori
--      are ray-MARCHED via their signed-distance field (sphere tracing): the
--      bounce loop's arrayFold nests a second fold that steps along the ray by
--      the SDF; the surface normal is the SDF gradient. Ray-torus is a quartic,
--      so marching is far simpler than solving it in SQL.
--    * the capital C is a RING = cylinder MINUS cylinder MINUS a box (the box
--      cut is what distinguishes C from O), kept analytic.
--    * a SPHERE for the dot on i; a thin oriented BOX for e's cross-bar.
--  A chrome "planet" above is a sphere MINUS a sphere. So the scene shows boxes,
--  cylinders, tori and spheres, with CSG union, differences and a marched field.
--  Glyph layout is produced by primfont2.py.
--
--  The light transport is an arrayFold over range(maxDepth) inside each row, so
--  it parallelizes across cores; pixels stream to ClickHouse's PNG format.
--  max_block_size is capped to bound peak memory; threads are left unset so the
--  render spreads across all cores. optimize_and_compare_chain = 0 avoids a costly
--  analyzer pass on the deeply-nested comparison tree. The output carries explicit
--  PNG 'x'/'y' coordinate columns (pixel % W, intDiv(pixel, W)), so the rows need
--  no ORDER BY -- the heavy per-pixel projection stays fully parallel and the PNG
--  writer places each pixel by its coordinates.
--
--  Run it:
--      clickhouse local --queries-file clickhouse_raytracer_primitives.sql > clickhouse.png
--
--  Knobs: output_format_image_width/height (+ imgW/imgH and the numbers_mt(...)
--  / % W literals), the SAMPLES factor in numbers_mt(W*H*SAMPLES), maxDepth,
--  and marchSteps (torus ray-march quality).
-- ============================================================================
WITH
    2.5 AS z0, 0.6 AS ty,
    (24.0, 0.0, 6.0)    AS target,
    (24.0, -45.0, 12.0) AS eye,
    36.0 AS fovDeg,
    1280.0 AS imgW, 512.0 AS imgH,
    4 AS maxDepth,
    (9.0, -30.0, 52.0)  AS lightPos,
    5.0 AS lightR,
    (0.42, 0.60, 0.95)  AS skyColor,
    (0.66, 0.78, 0.96)  AS hazeColor,
    35.0 AS fogStart, 120.0 AS fogRange,
    (0.02, 0.02, 0.02)  AS floorA,
    (1.00, 0.80, 0.00)  AS floorB,
    5.0 AS tile, 0.30 AS floorAmb, 0.85 AS floorDiff,
    (1.0, 1.0, 1.0)     AS specColor,
    60.0 AS shininess, 0.72 AS reflect_k,
    (24.0, 12.0, 17.5)  AS csgA, 6.0 AS csgAr,
    (24.0, 6.6, 17.0)   AS csgB, 4.4 AS csgBr,
    1.15 AS exposure, 2.2 AS gamma, 0.002 AS eps,
    48 AS marchSteps, 0.01 AS marchEps, 260.0 AS marchMax,

    0.62 AS rodR,
    [((100000.0,100000.0,100000.0),(1.0,0.0,0.0),(0.0,1.0,0.0),0.1,0.1)]  AS oboxes,
    [((5.75,0.0,2.5),(5.75,0.0,9.5),0.62), ((8.65,0.0,2.5),(8.65,0.0,7.5),0.62), ((16.8,0.0,2.5),(16.8,0.0,9.5),0.62), ((17.15,0.0,5.0),(20.05,0.0,7.6),0.62), ((17.35,0.0,5.1),(20.05,0.0,2.5),0.62), ((22.4,0.0,2.5),(22.4,0.0,9.5),0.62), ((26.15,0.0,2.5),(26.15,0.0,9.5),0.62), ((22.35,0.0,6.0),(26.15,0.0,6.0),0.62), ((34.82,0.0,3.5),(34.82,0.0,7.5),0.62), ((37.72,0.0,3.5),(37.72,0.0,7.5),0.62), ((45.35,0.0,5.05),(48.85,0.0,5.05),0.41333)]    AS cyls,
    [(100000.0,100000.0,0.1,0.05,100000000.0,100000000.0,100000000.0,100000000.0)]   AS rings,
    [((8.65,0.0,8.8),0.72)] AS spheres,
    [(1.3,6.0,2.28,0.62,(4.425,0.0,6.0),(3.025,100.0,1.5)), (12.95,5.0,1.425,0.575,(16.45,0.0,5.0),(3.4,100.0,1.1)), (30.4,5.0,1.475,0.525,(1000000.0,0.0,1000000.0),(0.1,0.1,0.1)), (36.27,4.0,1.45,0.62,(33.95,0.0,7.75),(9.0,100.0,3.75)), (41.9,6.0,1.025,0.425,(45.375,0.0,-0.25),(3.475,100.0,6.25)), (41.9,3.9,1.025,0.425,(36.375,0.0,7.7),(5.525,100.0,3.8)), (47.25,5.0,1.585,0.465,(50.8,0.0,4.32),(3.25,100.0,0.32))]    AS tori,

    ((a, b) -> tuplePlus(a, b))                                   AS va,
    ((a, b) -> tupleMinus(a, b))                                  AS vs,
    ((a, s) -> tupleMultiplyByNumber(a, s))                       AS vm,
    ((a, b) -> dotProduct(a, b))                                  AS vd,
    ((a)    -> L2Normalize(a))                                    AS vn,
    ((a, b) -> (a.2*b.3 - a.3*b.2, a.3*b.1 - a.1*b.3, a.1*b.2 - a.2*b.1)) AS vc,
    ((d, n) -> tupleMinus(d, tupleMultiplyByNumber(n, 2.0 * dotProduct(d, n)))) AS vref,

    L2Normalize(tupleMinus(target, eye))                          AS camFwd,
    L2Normalize(vc(L2Normalize(tupleMinus(target, eye)), (0.0, 0.0, 1.0))) AS camRight,
    vc(camRight, camFwd)                                          AS camUp,
    tan(fovDeg * 0.5 * pi() / 180.0)                              AS tanHalf,
    imgW / imgH AS aspect,

    ((O,D,b)  -> arrayMap(eu -> arrayMap(fu -> arrayMap(ev -> arrayMap(fv -> arrayMap(ew -> arrayMap(fw -> arrayMap(lou -> arrayMap(hiu -> arrayMap(lov -> arrayMap(hiv -> arrayMap(low -> arrayMap(hiw -> arrayMap(tn -> arrayMap(tf -> if(tf >= tn AND tf > eps, if(tn > eps, tn, tf), 1e9), [least(hiu, least(hiv, hiw))])[1], [greatest(lou, greatest(lov, low))])[1], [greatest((ew-ty)/fw,(ew+ty)/fw)])[1], [least((ew-ty)/fw,(ew+ty)/fw)])[1], [greatest((ev-b.5)/fv,(ev+b.5)/fv)])[1], [least((ev-b.5)/fv,(ev+b.5)/fv)])[1], [greatest((eu-b.4)/fu,(eu+b.4)/fu)])[1], [least((eu-b.4)/fu,(eu+b.4)/fu)])[1], [D.2])[1], [b.1.2 - O.2])[1], [vd(b.3,D)])[1], [vd(b.3, vs(b.1,O))])[1], [vd(b.2,D)])[1], [vd(b.2, vs(b.1,O))])[1]) AS oboxT,
    ((hp,b)   -> arrayMap(qu -> arrayMap(qv -> arrayMap(qw -> if(abs(qu) >= abs(qv) AND abs(qu) >= abs(qw), vm(b.2, if(qu>0.0,1.0,-1.0)), if(abs(qv) >= abs(qw), vm(b.3, if(qv>0.0,1.0,-1.0)), (0.0, if(qw>0.0,1.0,-1.0), 0.0))), [(hp.2 - b.1.2)/ty])[1], [vd(b.3, vs(hp,b.1))/b.5])[1], [vd(b.2, vs(hp,b.1))/b.4])[1]) AS oboxN,
    ((O,D,A,B,r)  -> arrayMap(ba -> arrayMap(oa -> arrayMap(baba -> arrayMap(bard -> arrayMap(baoa -> arrayMap(aa -> arrayMap(bb -> arrayMap(cc -> arrayMap(hh -> arrayMap(t -> arrayMap(y -> if(hh >= 0.0 AND aa > 1e-9 AND t > eps AND y > 0.0 AND y < baba, t, 1e9), [baoa + t*bard])[1], [(-bb - sqrt(greatest(hh,0.0)))/aa])[1], [bb*bb - aa*cc])[1], [baba*vd(oa,oa) - baoa*baoa - r*r*baba])[1], [baba*vd(D,oa) - baoa*bard])[1], [baba - bard*bard])[1], [vd(ba,oa)])[1], [vd(ba,D)])[1], [vd(ba,ba)])[1], [vs(O,A)])[1], [vs(B,A)])[1]) AS cylBodyT,
    ((O,D,P,ax,r) -> arrayMap(den -> arrayMap(t -> arrayMap(hp -> if(abs(den) > 1e-9 AND t > eps AND vd(vs(hp,P), vs(hp,P)) <= r*r, t, 1e9), [va(O, vm(D, t))])[1], [vd(ax, vs(P,O))/den])[1], [vd(ax, D)])[1]) AS diskT,
    ((O,D,A,B,r)  -> least(cylBodyT(O,D,A,B,r), least(diskT(O,D,A,vs(B,A),r), diskT(O,D,B,vs(B,A),r)))) AS rodT,
    ((O,D,A,B,r)  -> arrayMap(ba -> arrayMap(tL -> arrayMap(tA -> arrayMap(tB -> arrayMap(tm -> arrayMap(hp -> if(tm = tL, vn(vs(hp, va(A, vm(ba, vd(vs(hp,A),ba)/vd(ba,ba))))), if(tm = tA, vn(vm(ba,-1.0)), vn(ba))), [va(O, vm(D,tm))])[1], [least(tL, least(tA,tB))])[1], [diskT(O,D,B,ba,r)])[1], [diskT(O,D,A,ba,r)])[1], [cylBodyT(O,D,A,B,r)])[1], [vs(B,A)])[1]) AS rodN,
    ((O,D,rg) -> arrayMap(a2 -> arrayMap(hb -> arrayMap(rr -> arrayMap(dO -> arrayMap(dI -> arrayMap(toN -> arrayMap(toF -> arrayMap(tiN -> arrayMap(tiF -> arrayMap(ty0 -> arrayMap(ty1 -> arrayMap(tcN -> arrayMap(tcF -> arrayMap(aN -> arrayMap(aF -> arrayMap(e1 -> arrayMap(e2 -> arrayMap(e3 -> arrayMap(tm -> tm, [least(e1, least(e2, e3))])[1], [if(aN < tcF AND tcF < aF AND tcF > eps AND NOT (tiN < tcF AND tcF < tiF), tcF, 1e9)])[1], [if(aN < tiF AND tiF < aF AND tiF > eps AND NOT (tcN < tiF AND tiF < tcF), tiF, 1e9)])[1], [if(aN < aF AND aN > eps AND NOT (tiN < aN AND aN < tiF) AND NOT (tcN < aN AND aN < tcF), aN, 1e9)])[1], [least(ty1, toF)])[1], [greatest(ty0, toN)])[1], [least(greatest((rg.5-O.1)/D.1,(rg.7-O.1)/D.1), greatest((rg.6-O.3)/D.3,(rg.8-O.3)/D.3))])[1], [greatest(least((rg.5-O.1)/D.1,(rg.7-O.1)/D.1), least((rg.6-O.3)/D.3,(rg.8-O.3)/D.3))])[1], [greatest((-ty-O.2)/D.2, (ty-O.2)/D.2)])[1], [least((-ty-O.2)/D.2, (ty-O.2)/D.2)])[1], [if(dI > 0.0, (-hb + sqrt(dI))/a2, -1e9)])[1], [if(dI > 0.0, (-hb - sqrt(dI))/a2, 1e9)])[1], [if(dO > 0.0, (-hb + sqrt(dO))/a2, -1e9)])[1], [if(dO > 0.0, (-hb - sqrt(dO))/a2, 1e9)])[1], [hb*hb - a2*(rr - rg.4*rg.4)])[1], [hb*hb - a2*(rr - rg.3*rg.3)])[1], [(O.1-rg.1)*(O.1-rg.1) + (O.3-rg.2)*(O.3-rg.2)])[1], [(O.1-rg.1)*D.1 + (O.3-rg.2)*D.3])[1], [greatest(D.1*D.1 + D.3*D.3, 1e-12)])[1]) AS ringT,
    ((O,D,rg) -> arrayMap(a2 -> arrayMap(hb -> arrayMap(rr -> arrayMap(dO -> arrayMap(dI -> arrayMap(toN -> arrayMap(toF -> arrayMap(tiN -> arrayMap(tiF -> arrayMap(ty0 -> arrayMap(ty1 -> arrayMap(tcN -> arrayMap(tcF -> arrayMap(aN -> arrayMap(aF -> arrayMap(e1 -> arrayMap(e2 -> arrayMap(e3 -> arrayMap(tm -> arrayMap(hp -> if(tm = e1, if(toN >= ty0, vn((hp.1-rg.1, 0.0, hp.3-rg.2)), (0.0, if(D.2>0.0,-1.0,1.0), 0.0)), if(tm = e2, vn((rg.1-hp.1, 0.0, rg.2-hp.3)),    if(greatest((rg.5-O.1)/D.1,(rg.7-O.1)/D.1) <= greatest((rg.6-O.3)/D.3,(rg.8-O.3)/D.3),       (if(D.1>0.0,-1.0,1.0),0.0,0.0), (0.0,0.0,if(D.3>0.0,-1.0,1.0))))), [va(O, vm(D, tm))])[1], [least(e1, least(e2, e3))])[1], [if(aN < tcF AND tcF < aF AND tcF > eps AND NOT (tiN < tcF AND tcF < tiF), tcF, 1e9)])[1], [if(aN < tiF AND tiF < aF AND tiF > eps AND NOT (tcN < tiF AND tiF < tcF), tiF, 1e9)])[1], [if(aN < aF AND aN > eps AND NOT (tiN < aN AND aN < tiF) AND NOT (tcN < aN AND aN < tcF), aN, 1e9)])[1], [least(ty1, toF)])[1], [greatest(ty0, toN)])[1], [least(greatest((rg.5-O.1)/D.1,(rg.7-O.1)/D.1), greatest((rg.6-O.3)/D.3,(rg.8-O.3)/D.3))])[1], [greatest(least((rg.5-O.1)/D.1,(rg.7-O.1)/D.1), least((rg.6-O.3)/D.3,(rg.8-O.3)/D.3))])[1], [greatest((-ty-O.2)/D.2, (ty-O.2)/D.2)])[1], [least((-ty-O.2)/D.2, (ty-O.2)/D.2)])[1], [if(dI > 0.0, (-hb + sqrt(dI))/a2, -1e9)])[1], [if(dI > 0.0, (-hb - sqrt(dI))/a2, 1e9)])[1], [if(dO > 0.0, (-hb + sqrt(dO))/a2, -1e9)])[1], [if(dO > 0.0, (-hb - sqrt(dO))/a2, 1e9)])[1], [hb*hb - a2*(rr - rg.4*rg.4)])[1], [hb*hb - a2*(rr - rg.3*rg.3)])[1], [(O.1-rg.1)*(O.1-rg.1) + (O.3-rg.2)*(O.3-rg.2)])[1], [(O.1-rg.1)*D.1 + (O.3-rg.2)*D.3])[1], [greatest(D.1*D.1 + D.3*D.3, 1e-12)])[1]) AS ringN,
    ((O,D,C,r) -> if(dotProduct(vs(O,C),D)*dotProduct(vs(O,C),D) - (dotProduct(vs(O,C),vs(O,C))-r*r) > 0.0
                     AND -dotProduct(vs(O,C),D) - sqrt(greatest(dotProduct(vs(O,C),D)*dotProduct(vs(O,C),D)-(dotProduct(vs(O,C),vs(O,C))-r*r),0.0)) > eps,
                     -dotProduct(vs(O,C),D) - sqrt(greatest(dotProduct(vs(O,C),D)*dotProduct(vs(O,C),D)-(dotProduct(vs(O,C),vs(O,C))-r*r),0.0)), 1e9)) AS sphT,
    ((o, d, c, rad) -> if(
        dotProduct(vs(o,c), d) * dotProduct(vs(o,c), d) - (dotProduct(vs(o,c), vs(o,c)) - rad*rad) > 0.0,
        (-dotProduct(vs(o,c), d) - sqrt(greatest(dotProduct(vs(o,c), d) * dotProduct(vs(o,c), d) - (dotProduct(vs(o,c), vs(o,c)) - rad*rad), 0.0)),
         -dotProduct(vs(o,c), d) + sqrt(greatest(dotProduct(vs(o,c), d) * dotProduct(vs(o,c), d) - (dotProduct(vs(o,c), vs(o,c)) - rad*rad), 0.0))),
        (1e9, -1e9))) AS sphPair,
    /* ----- tori (round letters), ray-marched via signed distance fields ----- */
    /* torus SDF: tube radius tl.4 swept around radius tl.3 in x-z about center (tl.1, tl.2) */
    ((p,tl) -> sqrt(pow(sqrt((p.1-tl.1)*(p.1-tl.1)+(p.3-tl.2)*(p.3-tl.2)) - tl.3, 2) + p.2*p.2) - tl.4) AS tsdf,
    /* axis-aligned box SDF (used to cut the openings) */
    ((p,C,H) -> sqrt(pow(greatest(abs(p.1-C.1)-H.1,0.0),2) + pow(greatest(abs(p.2-C.2)-H.2,0.0),2) + pow(greatest(abs(p.3-C.3)-H.3,0.0),2))
                + least(greatest(abs(p.1-C.1)-H.1, greatest(abs(p.2-C.2)-H.2, abs(p.3-C.3)-H.3)), 0.0)) AS bsdf,
    /* nearest of all torus letters; each is (torus MINUS cut box) */
    ((p) -> arrayMin(arrayMap(tl -> greatest(tsdf(p, tl), -bsdf(p, tl.5, tl.6)), tori))) AS toriSDF,
    /* sphere-trace the tori; returns the hit distance or 1e9 */
    ((O,D) -> arrayMap(tfin -> if(toriSDF(va(O, vm(D, tfin))) < marchEps AND tfin > eps AND tfin < marchMax, tfin, 1e9),
                       [arrayFold((t, i) -> t + toriSDF(va(O, vm(D, t))), range(marchSteps), 0.02)])[1]) AS marchTorus,
    /* torus normal at the hit = gradient of the SDF (4-tap tetrahedron) */
    ((O,D,t) -> arrayMap(p -> vn(va(va(vm((1.0,-1.0,-1.0), toriSDF(va(p, (0.0009,-0.0009,-0.0009)))),
                                       vm((-1.0,-1.0,1.0), toriSDF(va(p, (-0.0009,-0.0009,0.0009))))),
                                    va(vm((-1.0,1.0,-1.0), toriSDF(va(p, (-0.0009,0.0009,-0.0009)))),
                                       vm((1.0,1.0,1.0), toriSDF(va(p, (0.0009,0.0009,0.0009))))))),
                         [va(O, vm(D, t))])[1]) AS torusN,
    ((o, d) -> if(d.3 < -eps AND o.3 > 0.0, -o.3 / d.3, 1e9))     AS planeT,
    ((o, d, maxd) -> arrayExists(b -> oboxT(o, d, b) < maxd, oboxes)
        OR arrayExists(c -> rodT(o, d, c.1, c.2, c.3) < maxd, cyls)
        OR arrayExists(rg -> ringT(o, d, rg) < maxd, rings)
        OR arrayExists(sp -> sphT(o, d, sp.1, sp.2) < maxd, spheres)
        OR (marchTorus(o, d) < maxd)) AS occluded,
    ((d) -> tupleMultiplyByNumber(skyColor, 0.35 + 0.65 * pow(greatest(1.0 - d.3, 0.0), 3.0))) AS sky,
    ((p) -> (toInt64(floor(p.1 / tile)) + toInt64(floor(p.2 / tile))) % 2) AS checker,
    ((a, b, c) -> (cityHash64(a, b, c) % 1048576) / 1048576.0)    AS rnd,

    ((s, lpos) -> arrayMap(o -> arrayMap(d -> arrayMap(thr -> arrayMap(acc -> arrayMap(oboxHits -> arrayMap(cylHits -> arrayMap(ringHits -> arrayMap(sphHits -> arrayMap(tTorus -> arrayMap(tBox -> arrayMap(tCyl -> arrayMap(tRing -> arrayMap(tSph -> arrayMap(tLet -> arrayMap(tP -> arrayMap(pairA -> arrayMap(pairB -> arrayMap(cEnter -> arrayMap(cCav -> arrayMap(tC -> arrayMap(tM -> arrayMap(tHit -> arrayMap(hp -> arrayMap(letN -> arrayMap(sn -> arrayMap(isMirror -> arrayMap(isFloor -> arrayMap(isMiss -> arrayMap(nrm -> arrayMap(shOrig -> arrayMap(rdir -> arrayMap(ldir -> arrayMap(distL -> arrayMap(shadowed -> arrayMap(spec -> arrayMap(lambert -> arrayMap(fog -> arrayMap(floorCol -> (
        if(isMirror, shOrig, o),
        if(isMirror, rdir, d),
        if(isMirror, thr * reflect_k, thr),
        va(acc, va(if(isMirror, vm(specColor, thr * spec), (0.0, 0.0, 0.0)),
                   va(if(isFloor, vm(floorCol, thr), (0.0, 0.0, 0.0)),
                      if(isMiss, vm(sky(d), thr), (0.0, 0.0, 0.0))))),
        if(isMirror, 1.0, 0.0)), [va(vm(vm(if(checker(hp) = 0, floorA, floorB), floorAmb + floorDiff * lambert), 1.0 - fog), vm(hazeColor, fog))])[1], [least(1.0, greatest(0.0, (tHit - fogStart) / fogRange))])[1], [greatest(vd(ldir, (0.0, 0.0, 1.0)), 0.0) * if(shadowed, 0.0, 1.0)])[1], [pow(greatest(vd(ldir, rdir), 0.0), shininess) * if(shadowed, 0.0, 1.0)])[1], [occluded(shOrig, ldir, distL - 0.05)])[1], [L2Norm(vs(lpos, hp))])[1], [vn(vs(lpos, hp))])[1], [vref(d, sn)])[1], [va(hp, vm(nrm, eps * 2.0))])[1], [if(isFloor, (0.0, 0.0, 1.0), sn)])[1], [(tM >= 1e8) AND (tP >= 1e8)])[1], [(tP <= tM) AND (tP < 1e8)])[1], [(tM < tP) AND (tM < 1e8)])[1], [if(tC < tLet, if(cEnter <= cCav, vn(vs(hp, csgA)), vn(vs(csgB, hp))), letN)])[1], [if(tTorus <= tBox AND tTorus <= tCyl AND tTorus <= tRing AND tTorus <= tSph, torusN(o, d, tTorus), if(tCyl <= tBox AND tCyl <= tRing AND tCyl <= tSph,    rodN(o, d, cyls[indexOf(cylHits, tCyl)].1, cyls[indexOf(cylHits, tCyl)].2, cyls[indexOf(cylHits, tCyl)].3), if(tBox <= tRing AND tBox <= tSph, oboxN(hp, oboxes[indexOf(oboxHits, tBox)]), if(tRing <= tSph, ringN(o, d, rings[indexOf(ringHits, tRing)]),    vn(vs(hp, spheres[indexOf(sphHits, tSph)].1))))))])[1], [va(o, vm(d, tHit))])[1], [least(tM, tP)])[1], [least(tLet, tC)])[1], [least(cEnter, cCav)])[1], [if(pairB.1 < 1e8 AND pairB.2 > eps AND pairA.1 <= pairB.2 AND pairB.2 <= pairA.2, pairB.2, 1e9)])[1], [if(pairA.1 > eps AND pairA.1 < 1e8 AND NOT (pairB.1 <= pairA.1 AND pairA.1 <= pairB.2), pairA.1, 1e9)])[1], [sphPair(o, d, csgB, csgBr)])[1], [sphPair(o, d, csgA, csgAr)])[1], [planeT(o, d)])[1], [least(least(tBox, tCyl), least(tRing, least(tSph, tTorus)))])[1], [arrayMin(sphHits)])[1], [arrayMin(ringHits)])[1], [arrayMin(cylHits)])[1], [arrayMin(oboxHits)])[1], [marchTorus(o, d)])[1], [arrayMap(sp -> sphT(o, d, sp.1, sp.2), spheres)])[1], [arrayMap(rg -> ringT(o, d, rg), rings)])[1], [arrayMap(c -> rodT(o, d, c.1, c.2, c.3), cyls)])[1], [arrayMap(b -> oboxT(o, d, b), oboxes)])[1], [s.4])[1], [s.3])[1], [s.2])[1], [s.1])[1]) AS oneBounce

SELECT
    clamp(pow(greatest(avg(col.1), 0.0) * exposure, 1.0 / gamma), 0.0, 1.0) AS r,
    clamp(pow(greatest(avg(col.2), 0.0) * exposure, 1.0 / gamma), 0.0, 1.0) AS g,
    clamp(pow(greatest(avg(col.3), 0.0) * exposure, 1.0 / gamma), 0.0, 1.0) AS b,
    pixel % 1280      AS x,                         /* explicit PNG coordinates: no ORDER BY needed */
    intDiv(pixel, 1280) AS y
FROM (
  SELECT pixel, va(st.4, if(st.5 > 0.5, vm(sky(st.2), st.3), (0.0,0.0,0.0))) AS col
  FROM (
    SELECT pixel,
      arrayFold((s, i) -> if(s.5 > 0.5, oneBounce(s, lpos), s), range(maxDepth), st0) AS st
    FROM (
      SELECT
        intDiv(number, 24) AS pixel,
        number % 24 AS sample,
        va(lightPos, (lightR * (rnd(pixel, sample, 3) - 0.5),
                      lightR * (rnd(pixel, sample, 4) - 0.5),
                      lightR * (rnd(pixel, sample, 5) - 0.5))) AS lpos,
        CAST((eye,
              vn(va(camFwd, va(vm(camRight, (((pixel % 1280) + rnd(pixel, sample, 1)) / imgW * 2.0 - 1.0) * aspect * tanHalf),
                                vm(camUp,    (1.0 - (intDiv(pixel, 1280) + rnd(pixel, sample, 2)) / imgH * 2.0) * tanHalf)))),
              1.0, (0.0, 0.0, 0.0), 1.0) AS Tuple(Tuple(Float64,Float64,Float64), Tuple(Float64,Float64,Float64), Float64, Tuple(Float64,Float64,Float64), Float64)) AS st0
      FROM numbers_mt(1280 * 512 * 24)
    )
  )
)
GROUP BY pixel
SETTINGS output_format_image_width = 1280, output_format_image_height = 512,
         max_block_size = 2048,
         optimize_and_compare_chain = 0
FORMAT PNG
