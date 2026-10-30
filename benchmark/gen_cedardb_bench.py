#!/usr/bin/env python3
"""Emit the benchmark scene as a CedarDB (PostgreSQL-dialect) script.

CedarDB has no SQL lambdas / higher-order array functions, so the port is
*set-based* and *recursive-CTE* driven instead of expression-driven:

  ClickHouse tuple / DuckDB LIST  -> double precision[]  (1-indexed)
  leaf vector / scalar helpers    -> CREATE FUNCTION ... LANGUAGE sql AS 'SELECT expr'
                                     (CedarDB >= v2026-10-08 rejects bare-expression
                                      bodies; v2026-08-13 and older reject SELECT bodies)
  intersection math               -> sphere / cylinder / tori helpers are SQL
                                     functions shared by primary and shadow rays;
                                     a chain of functions passes intermediates as
                                     parameters ("let"), since CedarDB forbids
                                     subqueries inside function bodies. The
                                     one-off planet uses a LATERAL "let" chain.
  arrayFold ray-march             -> WITH RECURSIVE (all rays march in lockstep)
  arrayFold bounce loop           -> the bounce block is emitted once per depth,
                                     each as its own set of CTEs (a recursive CTE
                                     cannot be nested in another, so depth is
                                     unrolled; marches are relations either way)
  geometry list                   -> rows (VALUES); nearest hit via window min,
                                     shadow occlusion via bool_or (a correlated
                                     EXISTS here is ~25% slower overall)
  fixed-step terrain shadow loop  -> set-based join over generate_series(0,23)
  cityHash/intHash                -> the same portable LCG hash (pure arithmetic)

One genuine CedarDB engine bug shapes the port (reported upstream as
cedardb/issues#71): subscripting (>=2x) an array column produced by a CASE/if
expression, when a branch is a function returning an array and the query has
ORDER BY, aborts the server (ArrayRuntime.cpp:937). So every array choice here is
an arithmetic mix() blend (or vm()-by-0/1 + va()) on a scalar selector, never a
CASE returning an array. A zero-safe vn() keeps masked-out candidate normals
finite (mix(a,b,0) would otherwise turn an inf normal into NaN).

(LATERAL inside a recursive term works fine; the marches inline their per-step
expressions as a style choice, not out of necessity.)

Usage:  gen_cedardb_bench.py [W] [H] [DEPTH]   (default 48 24 2)
"""
import sys, math
import primfont2

W     = int(sys.argv[1]) if len(sys.argv) > 1 else 48
H     = int(sys.argv[2]) if len(sys.argv) > 2 else 24
DEPTH = int(sys.argv[3]) if len(sys.argv) > 3 else 2

def f(v): return repr(round(float(v), 8))
def arr(xs): return "ARRAY[" + ",".join(f(x) for x in xs) + "]::double precision[]"

# ---- geometry (world space), reused from the ClickHouse/DuckDB generators ----
S, Z0 = 1.0, 2.5
X0 = 24.0 - primfont2.TOTAL_W * S / 2.0
cyls, sph, tori = [], [], []
for p in primfont2.PRIMS:
    if p[0] == 'cyl':
        _, x0, z0, x1, z1, r = p
        cyls.append((x0*S+X0, 0.0, z0*S+Z0, x1*S+X0, 0.0, z1*S+Z0, r*S))
    elif p[0] == 'sphere':
        _, cx, cz, r = p
        sph.append((cx*S+X0, 0.0, cz*S+Z0, r*S))
    elif p[0] == 'torus':
        _, cx, cz, Ro, Ri, cut = p
        R, rr = (Ro+Ri)/2.0, (Ro-Ri)/2.0
        if cut is None:
            bc, bh = (1e6, 0.0, 1e6), (0.1, 0.1, 0.1)
        else:
            bc = ((cut[0]+cut[2])/2.0*S+X0, 0.0, (cut[1]+cut[3])/2.0*S+Z0)
            bh = (abs(cut[2]-cut[0])/2.0*S, 100.0, abs(cut[3]-cut[1])/2.0*S)
        tori.append((cx*S+X0, cz*S+Z0, R*S, rr*S, bc[0], bc[1], bc[2], bh[0], bh[1], bh[2]))

# ---- camera basis (constant; eye/target fixed) ----
def sub(a, b): return [a[0]-b[0], a[1]-b[1], a[2]-b[2]]
def cross(a, b): return [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]]
def norm(a):
    l = math.sqrt(sum(c*c for c in a)); return [c/l for c in a]
EYE    = [24.0, -45.0, 12.0]
TARGET = [24.0, 0.0, 6.0]
FWD    = norm(sub(TARGET, EYE))
RIGHT  = norm(cross(FWD, [0.0, 0.0, 1.0]))
UP     = cross(RIGHT, FWD)
TANH   = math.tan(36.0 * 0.5 * math.pi / 180.0)
ASPECT = W / H

LIGHT  = [9.0, -30.0, 52.0]
CSGA, CSGB, RA, RB = [24.0,12.0,17.5], [24.0,6.6,17.0], 6.0, 4.4

def tori_terms():
    terms = []
    for (cx, cz, R, rr, bcx, bcy, bcz, bhx, bhy, bhz) in tori:
        t = f"tsdf3(px,py,pz,{f(cx)},{f(cz)},{f(R)},{f(rr)})"
        b = f"bsdf3(px,py,pz,{f(bcx)},{f(bcy)},{f(bcz)},{f(bhx)},{f(bhy)},{f(bhz)})"
        terms.append(f"greatest({t}, -{b})")
    expr = terms[-1]
    for t in reversed(terms[:-1]):
        expr = f"least({t}, {expr})"
    return expr

def cyl_values():
    rows = []
    for (ax, ay, az, bx, by, bz, r) in cyls:
        rows.append(f"({arr([ax,ay,az])}, {arr([bx,by,bz])}, {f(r)}::double precision)")
    return ",\n     ".join(rows)

SPHc = sph[0]


# ====================================================================
#  one bounce: consume ray CTE `IN` (idx,o,d,thr,acc,alive), emit `rays_{S}`
# ====================================================================
SPH_ARGS = f"{arr(SPHc[:3])}, {f(SPHc[3]*SPHc[3])}"

def emit_bounce(S, IN):
    return f"""
-- ============================ bounce {S} ============================
in_{S} AS (SELECT idx, o, d, thr, acc FROM {IN} WHERE alive > 0.5),

-- terrain height-field march (lockstep)
m_{S} AS (
  SELECT idx, o, d,
         CASE WHEN d[3] < -0.001 THEN greatest(0.05, (o[3]-1.55)/(-d[3])) ELSE 0.05 END AS t,
         0.0::double precision AS prevT, 1e9::double precision AS prevDiff,
         1e9::double precision AS result, 0 AS done, 0 AS iter
  FROM in_{S}
  UNION ALL
  SELECT idx, o, d,
    CASE WHEN prevDiff > 0.0 AND dc <= 0.0 THEN t ELSE t + greatest(0.45, t*0.008) END,
    t, dc,
    CASE WHEN prevDiff > 0.0 AND dc <= 0.0 THEN prevT + (t - prevT)*prevDiff/(prevDiff - dc) ELSE 1e9 END,
    CASE WHEN prevDiff > 0.0 AND dc <= 0.0 THEN 1
         WHEN o[3] + t*d[3] > 1.55 AND d[3] >= 0.0 THEN 2 ELSE 0 END,
    iter + 1
  FROM (SELECT idx, o, d, t, prevT, prevDiff, iter,
               o[3] + t*d[3] - terrH(o[1] + t*d[1], o[2] + t*d[2]) AS dc
        FROM m_{S} WHERE done = 0 AND iter < 110) s
),
terr_{S} AS (SELECT idx, min(CASE WHEN done = 1 THEN result ELSE 1e9 END) AS tTerr FROM m_{S} GROUP BY idx),

-- tori sphere-trace march (48 fixed steps)
tmar_{S} AS (
  SELECT idx, o, d, 0.02::double precision AS t, 0 AS iter FROM in_{S}
  UNION ALL
  SELECT idx, o, d, t + toriAt(o, d, t), iter + 1 FROM tmar_{S} WHERE iter < 48
),
tori_{S} AS (
  SELECT idx, tTorus, toriN(pt(o, d, least(tTorus, 5000.0))) AS nTorus
  FROM (SELECT idx, o, d, CASE WHEN toriAt(o, d, t) < 0.01 AND t > 0.002 AND t < 260.0 THEN t ELSE 1e9 END AS tTorus
        FROM tmar_{S} WHERE iter = 48) z
),

-- nearest cylinder per pixel
cyl_{S} AS (
  SELECT idx, t AS tCyl, cylN(o, d, t, a, b, r) AS nCyl
  FROM (SELECT *, row_number() OVER (PARTITION BY idx ORDER BY t) AS rn
        FROM (SELECT p.idx, p.o, p.d, c.a, c.b, c.r, cylT(p.o, p.d, c.a, c.b, c.r) AS t
              FROM in_{S} p CROSS JOIN cyls c) y) z
  WHERE rn = 1
),

-- planet: sphere csgA with a spherical cavity csgB
planet_{S} AS (
  SELECT p.idx, least(cEnter, cCav) AS tC,
         sel(vn(vs({arr(CSGB)}, pt(p.o, p.d, least(cEnter,cCav)))),
             vn(vs(pt(p.o, p.d, least(cEnter,cCav)), {arr(CSGA)})),
             f01(cEnter <= cCav)) AS nC
  FROM in_{S} p
  , LATERAL (SELECT vs(p.o, {arr(CSGA)}) AS ocA, vs(p.o, {arr(CSGB)}) AS ocB) q0
  , LATERAL (SELECT vd(q0.ocA,p.d) AS bA, vd(q0.ocA,q0.ocA)-{f(RA*RA)} AS cA,
                    vd(q0.ocB,p.d) AS bB, vd(q0.ocB,q0.ocB)-{f(RB*RB)} AS cB) q1
  , LATERAL (SELECT q1.bA*q1.bA-q1.cA AS dA, q1.bB*q1.bB-q1.cB AS dB) q2
  , LATERAL (SELECT CASE WHEN q2.dA>0.0 THEN -q1.bA-sqrt(q2.dA) ELSE 1e9 END AS aNear,
                    CASE WHEN q2.dA>0.0 THEN -q1.bA+sqrt(q2.dA) ELSE -1e9 END AS aFar,
                    CASE WHEN q2.dB>0.0 THEN -q1.bB-sqrt(q2.dB) ELSE 1e9 END AS bNear,
                    CASE WHEN q2.dB>0.0 THEN -q1.bB+sqrt(q2.dB) ELSE -1e9 END AS bFar) q3
  , LATERAL (SELECT CASE WHEN q3.aNear>0.002 AND q3.aNear<1e8 AND NOT (q3.bNear<=q3.aNear AND q3.aNear<=q3.bFar)
                         THEN q3.aNear ELSE 1e9 END AS cEnter,
                    CASE WHEN q3.bNear<1e8 AND q3.bFar>0.002 AND q3.aNear<=q3.bFar AND q3.bFar<=q3.aFar
                         THEN q3.bFar ELSE 1e9 END AS cCav) q4
),

-- nearest hit (+ i-dot sphere); surface normal, shadow ray, reflected ray
comb_{S} AS (
  SELECT p.idx, p.o, p.d, p.thr, p.acc, h.tHit, h.isMirror, h.isTerr, h.isMiss, h.hp,
         n.tN, n.rdir, n.ldir, n.distL, va(h.hp, vm(sel(h.sn, n.tN, h.isTerr), 0.02)) AS shOrig
  FROM in_{S} p
  JOIN tori_{S} th USING (idx) JOIN cyl_{S} ch USING (idx)
  JOIN planet_{S} pl USING (idx) JOIN terr_{S} tr USING (idx)
  , LATERAL (SELECT sphT(p.o, p.d, {SPH_ARGS}) AS tSph) sh
  , LATERAL (SELECT least(ch.tCyl, least(sh.tSph, th.tTorus)) AS tLet) a0
  , LATERAL (SELECT least(a0.tLet, pl.tC) AS tM) a1
  , LATERAL (SELECT least(a1.tM, tr.tTerr) AS tHit,
                    pt(p.o, p.d, least(least(a1.tM, tr.tTerr), 5000.0)) AS hp,
                    f01(a1.tM < tr.tTerr AND a1.tM < 1e8) AS isMirror,
                    f01(tr.tTerr <= a1.tM AND tr.tTerr < 1e8) AS isTerr,
                    f01(a1.tM >= 1e8 AND tr.tTerr >= 1e8) AS isMiss,
                    sel(sel(sel(vn(vs(pt(p.o, p.d, sh.tSph), {arr(SPHc[:3])})), ch.nCyl, f01(ch.tCyl<=sh.tSph)),
                            th.nTorus, f01(th.tTorus<=ch.tCyl AND th.tTorus<=sh.tSph)),
                        pl.nC, f01(pl.tC<a0.tLet)) AS sn) h
  , LATERAL (SELECT terrN(h.hp[1], h.hp[2]) AS tN, vref(p.d, h.sn) AS rdir,
                    vn(vs({arr(LIGHT)}, h.hp)) AS ldir,
                    sqrt(vd(vs({arr(LIGHT)}, h.hp), vs({arr(LIGHT)}, h.hp))) AS distL) n
),

-- shadow ray: terrain (24 fixed steps), cylinders, tori (march); sphere in shade_{S}
sterr_{S} AS (
  SELECT cb.idx, bool_or(
           (0.3::double precision + i*0.6::double precision) < cb.distL-0.05 AND
           cb.shOrig[3] + (0.3::double precision + i*0.6::double precision)*cb.ldir[3] <
             terrH(cb.shOrig[1] + (0.3::double precision + i*0.6::double precision)*cb.ldir[1], cb.shOrig[2] + (0.3::double precision + i*0.6::double precision)*cb.ldir[2])
         ) AS occ
  FROM comb_{S} cb CROSS JOIN generate_series(0,23) i
  GROUP BY cb.idx
),
stmar_{S} AS (
  SELECT idx, shOrig AS o, ldir AS d, distL, 0.02::double precision AS t, 0 AS iter FROM comb_{S}
  UNION ALL
  SELECT idx, o, d, distL, t + toriAt(o, d, t), iter + 1 FROM stmar_{S} WHERE iter < 48
),
socc_{S} AS (
  SELECT cb.idx, bool_or(cylT(cb.shOrig, cb.ldir, c.a, c.b, c.r) < cb.distL-0.05) AS occ
  FROM comb_{S} cb CROSS JOIN cyls c GROUP BY cb.idx
),
stori_{S} AS (
  SELECT idx, toriAt(o, d, t) < 0.01 AND t > 0.002 AND t < 260.0 AND t < distL-0.05 AS occ
  FROM stmar_{S} WHERE iter = 48
),

-- shading, accumulation, next ray
shade_{S} AS (
  SELECT cb.idx,
         va(cb.acc, va(vm(ARRAY[1.0,1.0,1.0]::double precision[], cb.thr*spec*cb.isMirror),
                       va(vm(terrShade, cb.thr*cb.isTerr),
                          vm(sky(cb.d), cb.thr*cb.isMiss)))) AS acc,
         sel(cb.o, cb.shOrig, cb.isMirror) AS o,
         sel(cb.d, cb.rdir,   cb.isMirror) AS d,
         cb.thr * (1.0 - 0.28*cb.isMirror) AS thr,
         cb.isMirror AS alive
  FROM comb_{S} cb JOIN sterr_{S} se USING (idx) JOIN socc_{S} sc USING (idx) JOIN stori_{S} st USING (idx)
  , LATERAL (SELECT 1.0 - f01(se.occ OR sc.occ OR st.occ
                              OR sphT(cb.shOrig, cb.ldir, {SPH_ARGS}) < cb.distL-0.05) AS lit) z1
  , LATERAL (SELECT power(greatest(vd(cb.ldir, cb.rdir),0.0), 60.0) * z1.lit AS spec,
                    greatest(vd(cb.ldir, cb.tN), 0.0) * z1.lit AS lambert,
                    least(1.0, greatest(0.0, (cb.tHit-70.0)/160.0)) AS fog) z2
  , LATERAL (SELECT va(vm(satb(vmul(terrCol(cb.hp[3]),
                          va(vm({arr([0.45,0.56,0.80])}, 0.26 + 0.18*greatest(cb.tN[3],0.0)),
                             vm({arr([1.06,0.97,0.82])}, 1.45*z2.lambert)))), 1.0 - z2.fog),
                      vm({arr([0.66,0.78,0.96])}, z2.fog)) AS terrShade) z3
),
rays_{S} AS (
  SELECT idx, o, d, thr, acc, alive FROM shade_{S}
  UNION ALL
  SELECT idx, o, d, thr, acc, 0.0 AS alive FROM {IN} WHERE alive <= 0.5
)"""


# ---- assemble all CTEs ----
# The camera as the reference computes it: in double precision, at run time.
DBL = "double precision"
ctes = [f"""cam0 AS (SELECT vn(vs({arr(TARGET)}, {arr(EYE)})) AS cf,
                 tan(36.0::{DBL} * 0.5 * pi() / 180.0) AS th, {W}.0::{DBL} / {H}.0::{DBL} AS aspect)""",
f"""cam1 AS (SELECT cf, th, aspect, vn(vc(cf, ARRAY[0.0,0.0,1.0]::{DBL}[])) AS cr FROM cam0)""",
f"""cam AS (SELECT cf, th, aspect, cr, vc(cr, cf) AS cu FROM cam1)""",
f"""px AS (
  SELECT g AS idx, {arr(EYE)} AS o,
         vn(va(cam.cf,
                va(vm(cam.cr, (((g % {W})::{DBL} + 0.5) / {W}.0::{DBL} * 2.0 - 1.0) * cam.aspect * cam.th),
                   vm(cam.cu, (1.0 - ((g / {W})::{DBL} + 0.5) / {H}.0::{DBL} * 2.0) * cam.th)))) AS d,
         1.0::double precision AS thr, ARRAY[0.0,0.0,0.0]::double precision[] AS acc, 1.0::double precision AS alive
  FROM generate_series(0, {W*H-1}) g, cam
)""",
f"""cyls(a, b, r) AS (VALUES
     {cyl_values()}
)"""]
prev = "px"
for b in range(1, DEPTH + 1):
    ctes.append(emit_bounce(f"b{b}", prev).strip().rstrip(","))
    prev = f"rays_b{b}"

WITHBLOCK = ",\n".join(ctes)

SCRIPT = f"""\
-- ====================================================================
-- ClickHouse-over-terrain benchmark, CedarDB port  ({W}x{H}, depth {DEPTH})
--   terrain + analytic letters + tori march + planet + shadows + bounces
-- ====================================================================

-- ---- vector helpers (double precision[3], 1-indexed) ----
CREATE OR REPLACE FUNCTION va(a double precision[], b double precision[]) RETURNS double precision[] LANGUAGE sql AS 'SELECT ARRAY[a[1]+b[1],a[2]+b[2],a[3]+b[3]]';
CREATE OR REPLACE FUNCTION vs(a double precision[], b double precision[]) RETURNS double precision[] LANGUAGE sql AS 'SELECT ARRAY[a[1]-b[1],a[2]-b[2],a[3]-b[3]]';
CREATE OR REPLACE FUNCTION vm(a double precision[], s double precision) RETURNS double precision[] LANGUAGE sql AS 'SELECT ARRAY[a[1]*s,a[2]*s,a[3]*s]';
CREATE OR REPLACE FUNCTION vd(a double precision[], b double precision[]) RETURNS double precision LANGUAGE sql AS 'SELECT a[1]*b[1]+a[2]*b[2]+a[3]*b[3]';
CREATE OR REPLACE FUNCTION vmul(a double precision[], b double precision[]) RETURNS double precision[] LANGUAGE sql AS 'SELECT ARRAY[a[1]*b[1],a[2]*b[2],a[3]*b[3]]';
CREATE OR REPLACE FUNCTION vn(a double precision[]) RETURNS double precision[] LANGUAGE sql AS 'SELECT vm(a, 1.0/sqrt(greatest(vd(a,a), 1e-18)))';
CREATE OR REPLACE FUNCTION vc(a double precision[], b double precision[]) RETURNS double precision[] LANGUAGE sql AS
  'SELECT ARRAY[a[2]*b[3]-a[3]*b[2], a[3]*b[1]-a[1]*b[3], a[1]*b[2]-a[2]*b[1]]';
CREATE OR REPLACE FUNCTION vref(d double precision[], n double precision[]) RETURNS double precision[] LANGUAGE sql AS 'SELECT vs(d, vm(n, 2.0*vd(d,n)))';
CREATE OR REPLACE FUNCTION mix(a double precision[], b double precision[], t double precision) RETURNS double precision[] LANGUAGE sql AS 'SELECT va(a, vm(vs(b,a), t))';
-- pick a (c = 0) or b (c = 1) exactly; a + (b-a)*1 can miss b by an ulp, as a CASE would not
CREATE OR REPLACE FUNCTION sel(a double precision[], b double precision[], c double precision) RETURNS double precision[] LANGUAGE sql AS 'SELECT va(vm(a, 1.0 - c), vm(b, c))';
CREATE OR REPLACE FUNCTION lerpS(a double precision, b double precision, t double precision) RETURNS double precision LANGUAGE sql AS 'SELECT a*(1.0-t)+b*t';
CREATE OR REPLACE FUNCTION clampS(lo double precision, hi double precision, x double precision) RETURNS double precision LANGUAGE sql AS 'SELECT greatest(lo, least(hi, x))';
CREATE OR REPLACE FUNCTION satb(c double precision[]) RETURNS double precision[] LANGUAGE sql AS
  'SELECT mix(ARRAY[c[1]*0.30+c[2]*0.59+c[3]*0.11, c[1]*0.30+c[2]*0.59+c[3]*0.11, c[1]*0.30+c[2]*0.59+c[3]*0.11], c, 1.45)';

-- ---- portable terrain noise (identical to ClickHouse/DuckDB; never overflows int64) ----
CREATE OR REPLACE FUNCTION hashf(ix bigint, iy bigint) RETURNS double precision LANGUAGE sql AS
  'SELECT ((((((ix+4096)+(iy+4096)*8192)*1103515245+12345)%2147483648)*1103515245+12345)%2147483648%65536)::double precision/65536.0';
CREATE OR REPLACE FUNCTION fade(t double precision) RETURNS double precision LANGUAGE sql AS 'SELECT t*t*t*(t*(t*6.0-15.0)+10.0)';
CREATE OR REPLACE FUNCTION vnoise(x double precision, y double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT lerpS(lerpS(hashf(floor(x)::bigint,   floor(y)::bigint),   hashf(floor(x)::bigint+1, floor(y)::bigint),   fade(x-floor(x))),
         lerpS(hashf(floor(x)::bigint,   floor(y)::bigint+1), hashf(floor(x)::bigint+1, floor(y)::bigint+1), fade(x-floor(x))),
         fade(y-floor(y)))';
CREATE OR REPLACE FUNCTION fbm(x double precision, y double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT (vnoise(x,y)*0.5 + vnoise(x*2.0,y*2.0)*0.25 + vnoise(x*4.0,y*4.0)*0.125 + vnoise(x*8.0,y*8.0)*0.0625)/0.9375';
CREATE OR REPLACE FUNCTION terrH(x double precision, y double precision) RETURNS double precision LANGUAGE sql AS 'SELECT 2.4*(fbm(x*0.05, y*0.05) - 0.5)';
CREATE OR REPLACE FUNCTION terrN(x double precision, y double precision) RETURNS double precision[] LANGUAGE sql AS
  'SELECT vn(ARRAY[(terrH(x-0.25,y)-terrH(x+0.25,y))/0.5, (terrH(x,y-0.25)-terrH(x,y+0.25))/0.5, 1.0])';
CREATE OR REPLACE FUNCTION terrCol(h double precision) RETURNS double precision[] LANGUAGE sql AS
  'SELECT mix(mix(mix(mix(ARRAY[0.06,0.24,0.55]::double precision[], ARRAY[0.84,0.68,0.32]::double precision[], clampS(0.0,1.0,(h+0.6)/0.4)),
                  ARRAY[0.16,0.52,0.09]::double precision[], clampS(0.0,1.0,(h+0.1)/0.5)),
              ARRAY[0.46,0.32,0.22]::double precision[], clampS(0.0,1.0,(h-0.6)/0.4)),
          ARRAY[0.97,0.98,1.0]::double precision[], clampS(0.0,1.0,(h-1.0)/0.3))';
CREATE OR REPLACE FUNCTION sky(d double precision[]) RETURNS double precision[] LANGUAGE sql AS
  'SELECT mix(ARRAY[0.66,0.78,0.96]::double precision[], ARRAY[0.30,0.50,0.85]::double precision[], greatest(0.0, least(1.0, d[3]*1.5)))';

-- ---- torus / box signed-distance fields (scalar args; no array subscripts) ----
CREATE OR REPLACE FUNCTION tsdf3(px double precision, py double precision, pz double precision,
                                 cx double precision, cz double precision, R double precision, rr double precision)
  RETURNS double precision LANGUAGE sql AS
  'SELECT sqrt((sqrt((px-cx)*(px-cx)+(pz-cz)*(pz-cz))-R)*(sqrt((px-cx)*(px-cx)+(pz-cz)*(pz-cz))-R) + py*py) - rr';
CREATE OR REPLACE FUNCTION bsdf3(px double precision, py double precision, pz double precision,
                                 cx double precision, cy double precision, cz double precision,
                                 hx double precision, hy double precision, hz double precision)
  RETURNS double precision LANGUAGE sql AS
  'SELECT sqrt(greatest(abs(px-cx)-hx,0.0)*greatest(abs(px-cx)-hx,0.0)
       + greatest(abs(py-cy)-hy,0.0)*greatest(abs(py-cy)-hy,0.0)
       + greatest(abs(pz-cz)-hz,0.0)*greatest(abs(pz-cz)-hz,0.0))
   + least(greatest(abs(px-cx)-hx, greatest(abs(py-cy)-hy, abs(pz-cz)-hz)), 0.0)';
CREATE OR REPLACE FUNCTION toriSDF3(px double precision, py double precision, pz double precision)
  RETURNS double precision LANGUAGE sql AS 'SELECT {tori_terms()}';

-- ---- ray / primitive intersection helpers (function parameters act as "let") ----
-- point along a ray, and a 0/1 weight from a predicate (for mix() selection)
CREATE OR REPLACE FUNCTION pt(o double precision[], d double precision[], t double precision) RETURNS double precision[] LANGUAGE sql AS 'SELECT va(o, vm(d, t))';
CREATE OR REPLACE FUNCTION f01(c boolean) RETURNS double precision LANGUAGE sql AS 'SELECT CASE WHEN c THEN 1.0 ELSE 0.0 END';
-- tori SDF along a ray, and its normal by the reference's tetrahedral estimate: the SDF at
-- p + (e,-e,-e), (-e,-e,e), (-e,e,-e), (e,e,e), weighted by those signs (a, b, c, d here)
CREATE OR REPLACE FUNCTION toriAt(o double precision[], d double precision[], t double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT toriSDF3(o[1]+d[1]*t, o[2]+d[2]*t, o[3]+d[3]*t)';
CREATE OR REPLACE FUNCTION toriN4(a double precision, b double precision, c double precision, d double precision) RETURNS double precision[] LANGUAGE sql AS
  'SELECT vn(ARRAY[(a - b) + (d - c), (-a - b) + (c + d), (b - a) + (d - c)])';
CREATE OR REPLACE FUNCTION toriN(p double precision[]) RETURNS double precision[] LANGUAGE sql AS
  'SELECT toriN4(toriSDF3(p[1]+0.0009,p[2]-0.0009,p[3]-0.0009), toriSDF3(p[1]-0.0009,p[2]-0.0009,p[3]+0.0009),
                 toriSDF3(p[1]-0.0009,p[2]+0.0009,p[3]-0.0009), toriSDF3(p[1]+0.0009,p[2]+0.0009,p[3]+0.0009))';
-- sphere (centre c, radius^2 rr): nearest t > eps, else 1e9
CREATE OR REPLACE FUNCTION sphT2(bb double precision, cc double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT CASE WHEN bb*bb-cc > 0.0 AND -bb-sqrt(greatest(bb*bb-cc,0.0)) > 0.002 THEN -bb-sqrt(greatest(bb*bb-cc,0.0)) ELSE 1e9 END';
CREATE OR REPLACE FUNCTION sphT(o double precision[], d double precision[], c double precision[], rr double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT sphT2(vd(vs(o,c), d), vd(vs(o,c), vs(o,c)) - rr)';
-- capped cylinder a-b, radius r: body (quadratic) and the two end disks
CREATE OR REPLACE FUNCTION cylBody3(tb double precision, hh double precision, aa double precision,
                                    baba double precision, bard double precision, baoa double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT CASE WHEN hh >= 0.0 AND aa > 1e-9 AND tb > 0.002 AND baoa + tb*bard > 0.0 AND baoa + tb*bard < baba THEN tb ELSE 1e9 END';
CREATE OR REPLACE FUNCTION cylBody2(aa double precision, bb double precision, cc double precision,
                                    baba double precision, bard double precision, baoa double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT cylBody3((-bb - sqrt(greatest(bb*bb - aa*cc, 0.0)))/aa, bb*bb - aa*cc, aa, baba, bard, baoa)';
CREATE OR REPLACE FUNCTION cylBody1(baba double precision, bard double precision, baoa double precision,
                                    doa double precision, oaoa double precision, r double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT cylBody2(baba - bard*bard, baba*doa - baoa*bard, baba*oaoa - baoa*baoa - r*r*baba, baba, bard, baoa)';
CREATE OR REPLACE FUNCTION cylBody(o double precision[], d double precision[], a double precision[], b double precision[], r double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT cylBody1(vd(vs(b,a),vs(b,a)), vd(vs(b,a),d), vd(vs(b,a),vs(o,a)), vd(d,vs(o,a)), vd(vs(o,a),vs(o,a)), r)';
CREATE OR REPLACE FUNCTION cylCap2(o double precision[], d double precision[], c double precision[], r double precision,
                                   den double precision, ta double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT CASE WHEN abs(den) > 1e-9 AND ta > 0.002 AND vd(vs(pt(o,d,ta),c), vs(pt(o,d,ta),c)) <= r*r THEN ta ELSE 1e9 END';
CREATE OR REPLACE FUNCTION cylCap(o double precision[], d double precision[], ba double precision[], c double precision[], r double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT cylCap2(o, d, c, r, vd(ba,d), vd(ba, vs(c,o))/CASE WHEN abs(vd(ba,d)) < 1e-12 THEN 1e-12 ELSE vd(ba,d) END)';
CREATE OR REPLACE FUNCTION cylT(o double precision[], d double precision[], a double precision[], b double precision[], r double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT least(cylBody(o,d,a,b,r), least(cylCap(o,d,vs(b,a),a,r), cylCap(o,d,vs(b,a),b,r)))';
-- normal at hit t: side normal on the body, -axis on cap a, +axis otherwise
CREATE OR REPLACE FUNCTION cylN2(t double precision, hp double precision[], a double precision[], ba double precision[],
                                 tBody double precision, tCapA double precision) RETURNS double precision[] LANGUAGE sql AS
  'SELECT sel(sel(vn(ba), vn(vm(ba,-1.0)), f01(t = tCapA)),
              vn(vs(hp, va(a, vm(ba, vd(vs(hp,a),ba)/vd(ba,ba))))), f01(t = tBody))';
CREATE OR REPLACE FUNCTION cylN(o double precision[], d double precision[], t double precision,
                                a double precision[], b double precision[], r double precision) RETURNS double precision[] LANGUAGE sql AS
  'SELECT cylN2(t, pt(o,d,t), a, vs(b,a), cylBody(o,d,a,b,r), cylCap(o,d,vs(b,a),a,r))';

-- ====================================================================
--  render
-- ====================================================================
-- the LATERAL "let" chains are intentional correlated joins, not accidental
-- cross products; allow them past CedarDB's implicit-cross-product guard.
SET implicit_cross_products = ON;
COPY (
WITH RECURSIVE
{WITHBLOCK}
SELECT idx,
  round(clampS(0.0,1.0, power(greatest(col[1],0.0)*1.15::double precision, 1.0::double precision/2.2::double precision))*255.0::double precision)::int AS r,
  round(clampS(0.0,1.0, power(greatest(col[2],0.0)*1.15::double precision, 1.0::double precision/2.2::double precision))*255.0::double precision)::int AS g,
  round(clampS(0.0,1.0, power(greatest(col[3],0.0)*1.15::double precision, 1.0::double precision/2.2::double precision))*255.0::double precision)::int AS b
FROM (
  SELECT idx, va(acc, vm(sky(d), thr*alive)) AS col FROM {prev}
) f
ORDER BY idx
) TO STDOUT WITH (FORMAT csv, DELIMITER E'\\t', HEADER false);
"""
sys.stdout.write(SCRIPT)
