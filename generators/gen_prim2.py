#!/usr/bin/env python3
"""Path tracer (arrayFold loop) with "ClickHouse" carved from three CSG solids:
   * oriented boxes (parallelepipeds)  -> straight strokes + k's flat-faced arms
   * rings = cylinder MINUS cylinder, optionally MINUS a box  -> round letters,
     and C/c/s arcs (the box-cut opening is what distinguishes C from O)
   * a sphere -> the dot on i
Plus the chrome planet (sphere MINUS sphere). Geometry from primfont2.py."""
import sys, math
import primfont2

W       = int(sys.argv[1]) if len(sys.argv) > 1 else 320
H       = int(sys.argv[2]) if len(sys.argv) > 2 else 128
SAMPLES = int(sys.argv[3]) if len(sys.argv) > 3 else 4
DEPTH   = int(sys.argv[4]) if len(sys.argv) > 4 else 4

S, Z0, TY = 1.0, 2.5, 0.6
X0 = 24.0 - primfont2.TOTAL_W * S / 2.0

def f(v): return repr(round(v, 5))

oboxes, cyls, rings, spheres, tori = [], [], [], [], []
for p in primfont2.PRIMS:
    if p[0] == 'obox':
        _, cx, cz, hx, hz, th = p
        t = math.radians(th)
        C = f"({f(cx*S+X0)},0.0,{f(cz*S+Z0)})"
        u = f"({f(math.cos(t))},0.0,{f(math.sin(t))})"
        v = f"({f(-math.sin(t))},0.0,{f(math.cos(t))})"
        oboxes.append(f"({C},{u},{v},{f(hx*S)},{f(hz*S)})")
    elif p[0] == 'cyl':
        _, x0, z0, x1, z1, r = p
        A = f"({f(x0*S+X0)},0.0,{f(z0*S+Z0)})"
        B = f"({f(x1*S+X0)},0.0,{f(z1*S+Z0)})"
        cyls.append(f"({A},{B},{f(r*S)})")
    elif p[0] == 'ring':
        _, cx, cz, Ro, Ri, cut = p
        if cut is None:
            rx0=rz0=rx1=rz1 = 1e8
        else:
            rx0, rz0, rx1, rz1 = cut[0]*S+X0, cut[1]*S+Z0, cut[2]*S+X0, cut[3]*S+Z0
        rings.append(f"({f(cx*S+X0)},{f(cz*S+Z0)},{f(Ro*S)},{f(Ri*S)},{f(rx0)},{f(rz0)},{f(rx1)},{f(rz1)})")
    elif p[0] == 'torus':
        _, cx, cz, Ro, Ri, cut = p
        R, rr = (Ro+Ri)/2.0, (Ro-Ri)/2.0          # major / minor radius of the tube
        if cut is None:                            # no opening: park the cut box far away
            bC, bH = "(1000000.0,0.0,1000000.0)", "(0.1,0.1,0.1)"
        else:
            bcx, bcz = (cut[0]+cut[2])/2.0*S+X0, (cut[1]+cut[3])/2.0*S+Z0
            bhx, bhz = abs(cut[2]-cut[0])/2.0*S, abs(cut[3]-cut[1])/2.0*S
            bC, bH = f"({f(bcx)},0.0,{f(bcz)})", f"({f(bhx)},100.0,{f(bhz)})"
        tori.append(f"({f(cx*S+X0)},{f(cz*S+Z0)},{f(R*S)},{f(rr*S)},{bC},{bH})")
    else:
        _, cx, cz, r = p
        spheres.append(f"(({f(cx*S+X0)},0.0,{f(cz*S+Z0)}),{f(r*S)})")

# keep arrays validly typed even when a primitive type ends up unused:
# a far-away dummy is never hit but stops `[]` from inferring Array(Nothing).
if not oboxes:
    oboxes = ["((100000.0,100000.0,100000.0),(1.0,0.0,0.0),(0.0,1.0,0.0),0.1,0.1)"]
if not rings:
    rings = ["(100000.0,100000.0,0.1,0.05,100000000.0,100000000.0,100000000.0,100000000.0)"]

OBOXES  = "[" + ", ".join(oboxes) + "]"
CYLS    = "[" + ", ".join(cyls) + "]"
RINGS   = "[" + ", ".join(rings) + "]"
SPHERES = "[" + ", ".join(spheres) + "]"
TORI    = "[" + ", ".join(tori) + "]"

def lets(bindings, body):
    for name, expr in reversed(bindings):
        body = f"arrayMap({name} -> {body}, [{expr}])[1]"
    return body

# ---- oriented box: third axis is w=(0,1,0) with half-extent ty ----
OBOX_B = [
    ("eu","vd(b.2, vs(b.1,O))"), ("fu","vd(b.2,D)"),
    ("ev","vd(b.3, vs(b.1,O))"), ("fv","vd(b.3,D)"),
    ("ew","b.1.2 - O.2"),        ("fw","D.2"),
    ("lou","least((eu-b.4)/fu,(eu+b.4)/fu)"), ("hiu","greatest((eu-b.4)/fu,(eu+b.4)/fu)"),
    ("lov","least((ev-b.5)/fv,(ev+b.5)/fv)"), ("hiv","greatest((ev-b.5)/fv,(ev+b.5)/fv)"),
    ("low","least((ew-ty)/fw,(ew+ty)/fw)"),   ("hiw","greatest((ew-ty)/fw,(ew+ty)/fw)"),
    ("tn","greatest(lou, greatest(lov, low))"),
    ("tf","least(hiu, least(hiv, hiw))"),
]
oboxT = lets(OBOX_B, "if(tf >= tn AND tf > eps, if(tn > eps, tn, tf), 1e9)")

OBOXN_B = [
    ("qu","vd(b.2, vs(hp,b.1))/b.4"),
    ("qv","vd(b.3, vs(hp,b.1))/b.5"),
    ("qw","(hp.2 - b.1.2)/ty"),
]
oboxN = lets(OBOXN_B,
    "if(abs(qu) >= abs(qv) AND abs(qu) >= abs(qw), vm(b.2, if(qu>0.0,1.0,-1.0)),"
    " if(abs(qv) >= abs(qw), vm(b.3, if(qv>0.0,1.0,-1.0)), (0.0, if(qw>0.0,1.0,-1.0), 0.0)))")

# ---- finite cylinder (rod) between A and B, radius r, with flat end caps ----
CYL_B = [
    ("ba","vs(B,A)"), ("oa","vs(O,A)"),
    ("baba","vd(ba,ba)"), ("bard","vd(ba,D)"), ("baoa","vd(ba,oa)"),
    ("aa","baba - bard*bard"),
    ("bb","baba*vd(D,oa) - baoa*bard"),
    ("cc","baba*vd(oa,oa) - baoa*baoa - r*r*baba"),
    ("hh","bb*bb - aa*cc"),
    ("t","(-bb - sqrt(greatest(hh,0.0)))/aa"),
    ("y","baoa + t*bard"),
]
cylBodyT = lets(CYL_B, "if(hh >= 0.0 AND aa > 1e-9 AND t > eps AND y > 0.0 AND y < baba, t, 1e9)")
# disk cap at point P with axis normal ax, radius r
DISK_B = [
    ("den","vd(ax, D)"),
    ("t","vd(ax, vs(P,O))/den"),
    ("hp","va(O, vm(D, t))"),
]
diskT = lets(DISK_B, "if(abs(den) > 1e-9 AND t > eps AND vd(vs(hp,P), vs(hp,P)) <= r*r, t, 1e9)")
# rod normal: lateral (radial) or a flat end cap (+-axis), whichever the hit is on
RODN_B = [
    ("ba","vs(B,A)"),
    ("tL","cylBodyT(O,D,A,B,r)"),
    ("tA","diskT(O,D,A,ba,r)"),
    ("tB","diskT(O,D,B,ba,r)"),
    ("tm","least(tL, least(tA,tB))"),
    ("hp","va(O, vm(D,tm))"),
]
rodN = lets(RODN_B,
    "if(tm = tL, vn(vs(hp, va(A, vm(ba, vd(vs(hp,A),ba)/vd(ba,ba))))),"
    " if(tm = tA, vn(vm(ba,-1.0)), vn(ba)))")

# ---- ring (annulus extruded in y, minus a cut box). rg=(cx,cz,Ro,Ri,rx0,rz0,rx1,rz1) ----
RING_CORE = [
    ("a2","greatest(D.1*D.1 + D.3*D.3, 1e-12)"),
    ("hb","(O.1-rg.1)*D.1 + (O.3-rg.2)*D.3"),
    ("rr","(O.1-rg.1)*(O.1-rg.1) + (O.3-rg.2)*(O.3-rg.2)"),
    ("dO","hb*hb - a2*(rr - rg.3*rg.3)"),
    ("dI","hb*hb - a2*(rr - rg.4*rg.4)"),
    ("toN","if(dO > 0.0, (-hb - sqrt(dO))/a2, 1e9)"),
    ("toF","if(dO > 0.0, (-hb + sqrt(dO))/a2, -1e9)"),
    ("tiN","if(dI > 0.0, (-hb - sqrt(dI))/a2, 1e9)"),
    ("tiF","if(dI > 0.0, (-hb + sqrt(dI))/a2, -1e9)"),
    ("ty0","least((-ty-O.2)/D.2, (ty-O.2)/D.2)"),
    ("ty1","greatest((-ty-O.2)/D.2, (ty-O.2)/D.2)"),
    ("tcN","greatest(least((rg.5-O.1)/D.1,(rg.7-O.1)/D.1), least((rg.6-O.3)/D.3,(rg.8-O.3)/D.3))"),
    ("tcF","least(greatest((rg.5-O.1)/D.1,(rg.7-O.1)/D.1), greatest((rg.6-O.3)/D.3,(rg.8-O.3)/D.3))"),
    ("aN","greatest(ty0, toN)"),
    ("aF","least(ty1, toF)"),
    ("e1","if(aN < aF AND aN > eps AND NOT (tiN < aN AND aN < tiF) AND NOT (tcN < aN AND aN < tcF), aN, 1e9)"),
    ("e2","if(aN < tiF AND tiF < aF AND tiF > eps AND NOT (tcN < tiF AND tiF < tcF), tiF, 1e9)"),
    ("e3","if(aN < tcF AND tcF < aF AND tcF > eps AND NOT (tiN < tcF AND tcF < tiF), tcF, 1e9)"),
    ("tm","least(e1, least(e2, e3))"),
]
ringT = lets(RING_CORE, "tm")
ringN = lets(RING_CORE + [("hp","va(O, vm(D, tm))")],
    "if(tm = e1, if(toN >= ty0, vn((hp.1-rg.1, 0.0, hp.3-rg.2)), (0.0, if(D.2>0.0,-1.0,1.0), 0.0)),"
    " if(tm = e2, vn((rg.1-hp.1, 0.0, rg.2-hp.3)),"
    "    if(greatest((rg.5-O.1)/D.1,(rg.7-O.1)/D.1) <= greatest((rg.6-O.3)/D.3,(rg.8-O.3)/D.3),"
    "       (if(D.1>0.0,-1.0,1.0),0.0,0.0), (0.0,0.0,if(D.3>0.0,-1.0,1.0)))))")

PRELUDE = f"""WITH
    {Z0} AS z0, {TY} AS ty,
    (24.0, 0.0, 6.0)    AS target,
    (24.0, -45.0, 12.0) AS eye,
    36.0 AS fovDeg,
    {W}.0 AS imgW, {H}.0 AS imgH,
    {DEPTH} AS maxDepth,
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
    {OBOXES}  AS oboxes,
    {CYLS}    AS cyls,
    {RINGS}   AS rings,
    {SPHERES} AS spheres,
    {TORI}    AS tori,

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

    ((O,D,b)  -> {oboxT}) AS oboxT,
    ((hp,b)   -> {oboxN}) AS oboxN,
    ((O,D,A,B,r)  -> {cylBodyT}) AS cylBodyT,
    ((O,D,P,ax,r) -> {diskT}) AS diskT,
    ((O,D,A,B,r)  -> least(cylBodyT(O,D,A,B,r), least(diskT(O,D,A,vs(B,A),r), diskT(O,D,B,vs(B,A),r)))) AS rodT,
    ((O,D,A,B,r)  -> {rodN}) AS rodN,
    ((O,D,rg) -> {ringT}) AS ringT,
    ((O,D,rg) -> {ringN}) AS ringN,
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

    ((s, lpos) -> {{ONE_BOUNCE}}) AS oneBounce
"""

_BIND = [
    ("o", "s.1"), ("d", "s.2"), ("thr", "s.3"), ("acc", "s.4"),
    ("oboxHits", "arrayMap(b -> oboxT(o, d, b), oboxes)"),
    ("cylHits",  "arrayMap(c -> rodT(o, d, c.1, c.2, c.3), cyls)"),
    ("ringHits", "arrayMap(rg -> ringT(o, d, rg), rings)"),
    ("sphHits",  "arrayMap(sp -> sphT(o, d, sp.1, sp.2), spheres)"),
    ("tTorus", "marchTorus(o, d)"),
    ("tBox", "arrayMin(oboxHits)"),
    ("tCyl", "arrayMin(cylHits)"),
    ("tRing", "arrayMin(ringHits)"),
    ("tSph", "arrayMin(sphHits)"),
    ("tLet", "least(least(tBox, tCyl), least(tRing, least(tSph, tTorus)))"),
    ("tP",   "planeT(o, d)"),
    ("pairA", "sphPair(o, d, csgA, csgAr)"),
    ("pairB", "sphPair(o, d, csgB, csgBr)"),
    ("cEnter", "if(pairA.1 > eps AND pairA.1 < 1e8 AND NOT (pairB.1 <= pairA.1 AND pairA.1 <= pairB.2), pairA.1, 1e9)"),
    ("cCav",   "if(pairB.1 < 1e8 AND pairB.2 > eps AND pairA.1 <= pairB.2 AND pairB.2 <= pairA.2, pairB.2, 1e9)"),
    ("tC",   "least(cEnter, cCav)"),
    ("tM",   "least(tLet, tC)"),
    ("tHit", "least(tM, tP)"),
    ("hp",   "va(o, vm(d, tHit))"),
    ("letN", "if(tTorus <= tBox AND tTorus <= tCyl AND tTorus <= tRing AND tTorus <= tSph, torusN(o, d, tTorus),"
             " if(tCyl <= tBox AND tCyl <= tRing AND tCyl <= tSph,"
             "    rodN(o, d, cyls[indexOf(cylHits, tCyl)].1, cyls[indexOf(cylHits, tCyl)].2, cyls[indexOf(cylHits, tCyl)].3),"
             " if(tBox <= tRing AND tBox <= tSph, oboxN(hp, oboxes[indexOf(oboxHits, tBox)]),"
             " if(tRing <= tSph, ringN(o, d, rings[indexOf(ringHits, tRing)]),"
             "    vn(vs(hp, spheres[indexOf(sphHits, tSph)].1))))))"),
    ("sn",   "if(tC < tLet, if(cEnter <= cCav, vn(vs(hp, csgA)), vn(vs(csgB, hp))), letN)"),
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
PRELUDE = PRELUDE.replace("{ONE_BOUNCE}", lets(_BIND, _BODY))

STT = "Tuple(Tuple(Float64,Float64,Float64), Tuple(Float64,Float64,Float64), Float64, Tuple(Float64,Float64,Float64), Float64)"

QUERY = PRELUDE + f"""
SELECT
    clamp(pow(greatest(avg(col.1), 0.0) * exposure, 1.0 / gamma), 0.0, 1.0) AS r,
    clamp(pow(greatest(avg(col.2), 0.0) * exposure, 1.0 / gamma), 0.0, 1.0) AS g,
    clamp(pow(greatest(avg(col.3), 0.0) * exposure, 1.0 / gamma), 0.0, 1.0) AS b
FROM (
  SELECT pixel, va(st.4, if(st.5 > 0.5, vm(sky(st.2), st.3), (0.0,0.0,0.0))) AS col
  FROM (
    SELECT pixel,
      arrayFold((s, i) -> if(s.5 > 0.5, oneBounce(s, lpos), s), range(maxDepth), st0) AS st
    FROM (
      SELECT
        intDiv(number, {SAMPLES}) AS pixel,
        number % {SAMPLES} AS sample,
        va(lightPos, (lightR * (rnd(pixel, sample, 3) - 0.5),
                      lightR * (rnd(pixel, sample, 4) - 0.5),
                      lightR * (rnd(pixel, sample, 5) - 0.5))) AS lpos,
        CAST((eye,
              vn(va(camFwd, va(vm(camRight, (((pixel % {W}) + rnd(pixel, sample, 1)) / imgW * 2.0 - 1.0) * aspect * tanHalf),
                                vm(camUp,    (1.0 - (intDiv(pixel, {W}) + rnd(pixel, sample, 2)) / imgH * 2.0) * tanHalf)))),
              1.0, (0.0, 0.0, 0.0), 1.0) AS {STT}) AS st0
      FROM numbers_mt({W} * {H} * {SAMPLES})
    )
  )
)
GROUP BY pixel
ORDER BY pixel
SETTINGS output_format_image_width = {W}, output_format_image_height = {H},
         max_block_size = 2048, max_threads = 24
FORMAT PNG
"""
sys.stdout.write(QUERY)
