-- ====================================================================
-- ClickHouse-over-terrain benchmark, CedarDB port (PHASE 2: first hit)
--   terrain + analytic letters (cylinders/sphere) + tori march + planet
-- ====================================================================

-- ---- vector helpers (double precision[3], 1-indexed) ----
CREATE OR REPLACE FUNCTION va(a double precision[], b double precision[]) RETURNS double precision[] LANGUAGE sql AS 'ARRAY[a[1]+b[1],a[2]+b[2],a[3]+b[3]]';
CREATE OR REPLACE FUNCTION vs(a double precision[], b double precision[]) RETURNS double precision[] LANGUAGE sql AS 'ARRAY[a[1]-b[1],a[2]-b[2],a[3]-b[3]]';
CREATE OR REPLACE FUNCTION vm(a double precision[], s double precision) RETURNS double precision[] LANGUAGE sql AS 'ARRAY[a[1]*s,a[2]*s,a[3]*s]';
CREATE OR REPLACE FUNCTION vd(a double precision[], b double precision[]) RETURNS double precision LANGUAGE sql AS 'a[1]*b[1]+a[2]*b[2]+a[3]*b[3]';
CREATE OR REPLACE FUNCTION vmul(a double precision[], b double precision[]) RETURNS double precision[] LANGUAGE sql AS 'ARRAY[a[1]*b[1],a[2]*b[2],a[3]*b[3]]';
-- zero-safe normalize: a zero vector maps to zero, never inf/NaN
CREATE OR REPLACE FUNCTION vn(a double precision[]) RETURNS double precision[] LANGUAGE sql AS 'vm(a, 1.0/sqrt(greatest(vd(a,a), 1e-18)))';
CREATE OR REPLACE FUNCTION vref(d double precision[], n double precision[]) RETURNS double precision[] LANGUAGE sql AS 'vs(d, vm(n, 2.0*vd(d,n)))';
CREATE OR REPLACE FUNCTION mix(a double precision[], b double precision[], t double precision) RETURNS double precision[] LANGUAGE sql AS 'va(a, vm(vs(b,a), t))';
CREATE OR REPLACE FUNCTION lerpS(a double precision, b double precision, t double precision) RETURNS double precision LANGUAGE sql AS 'a*(1.0-t)+b*t';
CREATE OR REPLACE FUNCTION clampS(lo double precision, hi double precision, x double precision) RETURNS double precision LANGUAGE sql AS 'greatest(lo, least(hi, x))';
CREATE OR REPLACE FUNCTION satb(c double precision[]) RETURNS double precision[] LANGUAGE sql AS
  'mix(ARRAY[c[1]*0.30+c[2]*0.59+c[3]*0.11, c[1]*0.30+c[2]*0.59+c[3]*0.11, c[1]*0.30+c[2]*0.59+c[3]*0.11], c, 1.45)';

-- ---- portable terrain noise (identical to ClickHouse/DuckDB; never overflows int64) ----
CREATE OR REPLACE FUNCTION hashf(ix bigint, iy bigint) RETURNS double precision LANGUAGE sql AS
  '((((((ix+4096)+(iy+4096)*8192)*1103515245+12345)%2147483648)*1103515245+12345)%2147483648%65536)::double precision/65536.0';
CREATE OR REPLACE FUNCTION fade(t double precision) RETURNS double precision LANGUAGE sql AS 't*t*t*(t*(t*6.0-15.0)+10.0)';
CREATE OR REPLACE FUNCTION vnoise(x double precision, y double precision) RETURNS double precision LANGUAGE sql AS
  'lerpS(lerpS(hashf(floor(x)::bigint,   floor(y)::bigint),   hashf(floor(x)::bigint+1, floor(y)::bigint),   fade(x-floor(x))),
         lerpS(hashf(floor(x)::bigint,   floor(y)::bigint+1), hashf(floor(x)::bigint+1, floor(y)::bigint+1), fade(x-floor(x))),
         fade(y-floor(y)))';
CREATE OR REPLACE FUNCTION fbm(x double precision, y double precision) RETURNS double precision LANGUAGE sql AS
  '(vnoise(x,y)*0.5 + vnoise(x*2.0,y*2.0)*0.25 + vnoise(x*4.0,y*4.0)*0.125 + vnoise(x*8.0,y*8.0)*0.0625)/0.9375';
CREATE OR REPLACE FUNCTION terrH(x double precision, y double precision) RETURNS double precision LANGUAGE sql AS
  '2.4*(fbm(x*0.05, y*0.05) - 0.5)';
CREATE OR REPLACE FUNCTION terrN(x double precision, y double precision) RETURNS double precision[] LANGUAGE sql AS
  'vn(ARRAY[(terrH(x-0.25,y)-terrH(x+0.25,y))/0.5, (terrH(x,y-0.25)-terrH(x,y+0.25))/0.5, 1.0])';
CREATE OR REPLACE FUNCTION terrCol(h double precision) RETURNS double precision[] LANGUAGE sql AS
  'mix(mix(mix(mix(ARRAY[0.06,0.24,0.55]::double precision[], ARRAY[0.84,0.68,0.32]::double precision[], clampS(0.0,1.0,(h+0.6)/0.4)),
                  ARRAY[0.16,0.52,0.09]::double precision[], clampS(0.0,1.0,(h+0.1)/0.5)),
              ARRAY[0.46,0.32,0.22]::double precision[], clampS(0.0,1.0,(h-0.6)/0.4)),
          ARRAY[0.97,0.98,1.0]::double precision[], clampS(0.0,1.0,(h-1.0)/0.3))';
CREATE OR REPLACE FUNCTION sky(d double precision[]) RETURNS double precision[] LANGUAGE sql AS
  'mix(ARRAY[0.66,0.78,0.96]::double precision[], ARRAY[0.30,0.50,0.85]::double precision[], greatest(0.0, least(1.0, d[3]*1.5)))';

-- ---- torus / box signed-distance fields (scalar args; no array subscripts) ----
CREATE OR REPLACE FUNCTION tsdf3(px double precision, py double precision, pz double precision,
                                 cx double precision, cz double precision, R double precision, rr double precision)
  RETURNS double precision LANGUAGE sql AS
  'sqrt((sqrt((px-cx)*(px-cx)+(pz-cz)*(pz-cz))-R)*(sqrt((px-cx)*(px-cx)+(pz-cz)*(pz-cz))-R) + py*py) - rr';
CREATE OR REPLACE FUNCTION bsdf3(px double precision, py double precision, pz double precision,
                                 cx double precision, cy double precision, cz double precision,
                                 hx double precision, hy double precision, hz double precision)
  RETURNS double precision LANGUAGE sql AS
  'sqrt(greatest(abs(px-cx)-hx,0.0)*greatest(abs(px-cx)-hx,0.0)
       + greatest(abs(py-cy)-hy,0.0)*greatest(abs(py-cy)-hy,0.0)
       + greatest(abs(pz-cz)-hz,0.0)*greatest(abs(pz-cz)-hz,0.0))
   + least(greatest(abs(px-cx)-hx, greatest(abs(py-cy)-hy, abs(pz-cz)-hz)), 0.0)';
-- nearest-surface distance over all 7 tori (each cut by its box)
CREATE OR REPLACE FUNCTION toriSDF3(px double precision, py double precision, pz double precision)
  RETURNS double precision LANGUAGE sql AS
  'least(greatest(tsdf3(px,py,pz,1.3,5.4,2.28,0.62), -bsdf3(px,py,pz,4.425,0.0,5.4,3.025,100.0,1.5)), least(greatest(tsdf3(px,py,pz,12.95,4.5,1.425,0.575), -bsdf3(px,py,pz,16.45,0.0,4.5,3.4,100.0,0.94)), least(greatest(tsdf3(px,py,pz,30.4,4.5,1.475,0.525), -bsdf3(px,py,pz,1000000.0,0.0,1000000.0,0.1,0.1,0.1)), least(greatest(tsdf3(px,py,pz,36.27,4.0,1.45,0.62), -bsdf3(px,py,pz,33.95,0.0,7.75,9.0,100.0,3.75)), least(greatest(tsdf3(px,py,pz,41.9,6.0,1.025,0.425), -bsdf3(px,py,pz,45.375,0.0,-0.25,3.475,100.0,6.25)), least(greatest(tsdf3(px,py,pz,41.9,3.9,1.025,0.425), -bsdf3(px,py,pz,36.375,0.0,7.7,5.525,100.0,3.8)), greatest(tsdf3(px,py,pz,47.25,4.55,1.585,0.465), -bsdf3(px,py,pz,50.8,0.0,3.87,3.25,100.0,0.32))))))))';

-- ====================================================================
--  render
-- ====================================================================
COPY (
WITH RECURSIVE
-- primary rays: one row per pixel
px AS (
  SELECT g AS idx,
         ARRAY[24.0,-45.0,12.0]::double precision[] AS o,
         vn(va(ARRAY[0.0,0.9912279,-0.13216372]::double precision[],
                va(vm(ARRAY[1.0,-0.0,0.0]::double precision[], (((g % 48) + 0.5) / 48.0 * 2.0 - 1.0) * 2.0 * 0.3249197),
                   vm(ARRAY[0.0,0.13216372,0.9912279]::double precision[],    (1.0 - ((g / 48)::int + 0.5) / 24.0 * 2.0) * 0.3249197)))) AS d
  FROM generate_series(0, 1151) g
),

-- ---- terrain height-field march (lockstep; inlined, no LATERAL in recursion) ----
m AS (
  SELECT idx, o, d,
         CASE WHEN d[3] < -0.001 THEN greatest(0.05, (o[3]-1.55)/(-d[3])) ELSE 0.05 END AS t,
         0.0::double precision AS prevT, 1e9::double precision AS prevDiff,
         1e9::double precision AS result, 0 AS done, 0 AS iter
  FROM px
  UNION ALL
  SELECT idx, o, d,
    CASE WHEN prevDiff > 0.0 AND dc <= 0.0 THEN t ELSE t + greatest(0.06, t*0.035) END,
    t, dc,
    CASE WHEN prevDiff > 0.0 AND dc <= 0.0 THEN prevT + (t - prevT)*prevDiff/(prevDiff - dc) ELSE 1e9 END,
    CASE WHEN prevDiff > 0.0 AND dc <= 0.0 THEN 1
         WHEN o[3] + t*d[3] > 1.55 AND d[3] >= 0.0 THEN 2 ELSE 0 END,
    iter + 1
  FROM (
    SELECT idx, o, d, t, prevT, prevDiff, iter,
           o[3] + t*d[3] - terrH(o[1] + t*d[1], o[2] + t*d[2]) AS dc
    FROM m WHERE done = 0 AND iter < 110
  ) s
),
terr AS (SELECT idx, min(CASE WHEN done = 1 THEN result ELSE 1e9 END) AS tTerr FROM m GROUP BY idx),

-- ---- tori sphere-trace march (exactly 48 accumulate steps, like DuckDB) ----
tmar AS (
  SELECT idx, o, d, 0.02::double precision AS t, 0 AS iter FROM px
  UNION ALL
  SELECT idx, o, d, t + toriSDF3(o[1]+d[1]*t, o[2]+d[2]*t, o[3]+d[3]*t), iter + 1
  FROM tmar WHERE iter < 48
),
tori_hit AS (
  SELECT idx, tfin, sdf,
         CASE WHEN sdf < 0.01 AND tfin > 0.002 AND tfin < 260.0 THEN tfin ELSE 1e9 END AS tTorus
  FROM (
    SELECT t1.idx, t1.t AS tfin, t1.o, t1.d,
           toriSDF3(t1.o[1]+t1.d[1]*t1.t, t1.o[2]+t1.d[2]*t1.t, t1.o[3]+t1.d[3]*t1.t) AS sdf
    FROM tmar t1 WHERE t1.iter = 48
  ) z
),
-- tori normal at the hit point (numerical SDF gradient, zero-safe)
tori_nrm AS (
  SELECT h.idx, h.tTorus,
         vn(ARRAY[
            toriSDF3(hx+0.0009,hy,hz) - toriSDF3(hx-0.0009,hy,hz),
            toriSDF3(hx,hy+0.0009,hz) - toriSDF3(hx,hy-0.0009,hz),
            toriSDF3(hx,hy,hz+0.0009) - toriSDF3(hx,hy,hz-0.0009)]) AS nTorus
  FROM tori_hit h, px p,
       LATERAL (SELECT p.o[1]+p.d[1]*least(h.tTorus,5000.0) AS hx,
                       p.o[2]+p.d[2]*least(h.tTorus,5000.0) AS hy,
                       p.o[3]+p.d[3]*least(h.tTorus,5000.0) AS hz) g
  WHERE p.idx = h.idx
),

-- ---- analytic cylinders (finite rod = body + 2 disk caps), nearest per pixel ----
cyls(a, b, r) AS (VALUES
     (ARRAY[5.75,0.0,2.5]::double precision[], ARRAY[5.75,0.0,9.5]::double precision[], 0.62::double precision),
     (ARRAY[8.65,0.0,2.5]::double precision[], ARRAY[8.65,0.0,7.5]::double precision[], 0.62::double precision),
     (ARRAY[16.8,0.0,2.5]::double precision[], ARRAY[16.8,0.0,9.5]::double precision[], 0.62::double precision),
     (ARRAY[17.15,0.0,5.0]::double precision[], ARRAY[20.05,0.0,7.6]::double precision[], 0.62::double precision),
     (ARRAY[17.35,0.0,5.1]::double precision[], ARRAY[20.05,0.0,2.5]::double precision[], 0.62::double precision),
     (ARRAY[22.4,0.0,2.5]::double precision[], ARRAY[22.4,0.0,9.5]::double precision[], 0.62::double precision),
     (ARRAY[26.15,0.0,2.5]::double precision[], ARRAY[26.15,0.0,9.5]::double precision[], 0.62::double precision),
     (ARRAY[22.35,0.0,6.0]::double precision[], ARRAY[26.15,0.0,6.0]::double precision[], 0.62::double precision),
     (ARRAY[34.82,0.0,3.5]::double precision[], ARRAY[34.82,0.0,7.5]::double precision[], 0.62::double precision),
     (ARRAY[37.72,0.0,3.5]::double precision[], ARRAY[37.72,0.0,7.5]::double precision[], 0.62::double precision),
     (ARRAY[45.35,0.0,4.6]::double precision[], ARRAY[48.85,0.0,4.6]::double precision[], 0.41333333::double precision)
),
cyl_raw AS (
  SELECT p.idx,
         least(tBody, least(tCapA, tCapB)) AS t,
         -- normal: body | capA(-ba) | capB(ba) chosen by which sub-t is the min
         mix(mix(vn(l1.ba), vn(vm(l1.ba,-1.0)),
                 CASE WHEN least(tBody,least(tCapA,tCapB)) = tCapA THEN 1.0 ELSE 0.0 END),
             vn(vs(va(p.o, vm(p.d, least(tBody,least(tCapA,tCapB)))),
                   va(c.a, vm(l1.ba, vd(vs(va(p.o, vm(p.d, least(tBody,least(tCapA,tCapB)))), c.a), l1.ba)/l1.baba)))),
             CASE WHEN least(tBody,least(tCapA,tCapB)) = tBody THEN 1.0 ELSE 0.0 END) AS n
  FROM px p CROSS JOIN cyls c
  , LATERAL (SELECT vs(c.b,c.a) AS ba, vs(p.o,c.a) AS oa) l0
  , LATERAL (SELECT l0.ba AS ba, l0.oa AS oa, vd(l0.ba,l0.ba) AS baba, vd(l0.ba,p.d) AS bard,
                    vd(l0.ba,l0.oa) AS baoa, vd(p.d,l0.oa) AS doa, vd(l0.oa,l0.oa) AS oaoa) l1
  -- body quadratic
  , LATERAL (SELECT l1.baba - l1.bard*l1.bard AS aa,
                    l1.baba*l1.doa - l1.baoa*l1.bard AS bb,
                    l1.baba*l1.oaoa - l1.baoa*l1.baoa - c.r*c.r*l1.baba AS cc) l2
  , LATERAL (SELECT l2.bb*l2.bb - l2.aa*l2.cc AS hh) l3
  , LATERAL (SELECT (-l2.bb - sqrt(greatest(l3.hh,0.0)))/l2.aa AS tb) l4
  , LATERAL (SELECT CASE WHEN l3.hh >= 0.0 AND l2.aa > 1e-9 AND l4.tb > 0.002
                              AND (l1.baoa + l4.tb*l1.bard) > 0.0
                              AND (l1.baoa + l4.tb*l1.bard) < l1.baba
                         THEN l4.tb ELSE 1e9 END AS tBody) l5
  -- disk caps at A and B (axis = ba)
  , LATERAL (SELECT vd(l1.ba, p.d) AS den) l6
  , LATERAL (SELECT vd(l1.ba, vs(c.a, p.o))/CASE WHEN abs(l6.den) < 1e-12 THEN 1e-12 ELSE l6.den END AS taA,
                    vd(l1.ba, vs(c.b, p.o))/CASE WHEN abs(l6.den) < 1e-12 THEN 1e-12 ELSE l6.den END AS taB) l7
  , LATERAL (SELECT vs(va(p.o, vm(p.d, l7.taA)), c.a) AS dA, vs(va(p.o, vm(p.d, l7.taB)), c.b) AS dB) l8
  , LATERAL (SELECT CASE WHEN abs(l6.den) > 1e-9 AND l7.taA > 0.002 AND vd(l8.dA,l8.dA) <= c.r*c.r THEN l7.taA ELSE 1e9 END AS tCapA,
                    CASE WHEN abs(l6.den) > 1e-9 AND l7.taB > 0.002 AND vd(l8.dB,l8.dB) <= c.r*c.r THEN l7.taB ELSE 1e9 END AS tCapB) l9
),
cyl_hit AS (
  SELECT idx, t AS tCyl, n AS nCyl FROM (
    SELECT idx, t, n, row_number() OVER (PARTITION BY idx ORDER BY t) AS rn FROM cyl_raw
  ) z WHERE rn = 1
),

-- ---- i-dot sphere ----
sph_hit AS (
  SELECT p.idx,
         CASE WHEN disc > 0.0 AND tnear > 0.002 THEN tnear ELSE 1e9 END AS tSph,
         vn(vs(va(p.o, vm(p.d, CASE WHEN disc > 0.0 AND tnear > 0.002 THEN tnear ELSE 1e9 END)),
               ARRAY[8.65,0.0,8.8]::double precision[])) AS nSph
  FROM px p
  , LATERAL (SELECT vs(p.o, ARRAY[8.65,0.0,8.8]::double precision[]) AS oc) s0
  , LATERAL (SELECT vd(s0.oc, p.d) AS bb, vd(s0.oc, s0.oc) - 0.5184 AS cc) s1
  , LATERAL (SELECT s1.bb*s1.bb - s1.cc AS disc) s2
  , LATERAL (SELECT -s1.bb - sqrt(greatest(s2.disc,0.0)) AS tnear) s3
),

-- ---- planet: sphere csgA with a spherical cavity csgB ----
planet AS (
  SELECT p.idx,
         least(cEnter, cCav) AS tC,
         -- outward A normal if entering A, else inward B normal
         mix(vn(vs(ARRAY[24.0,6.6,17.0]::double precision[], va(p.o, vm(p.d, least(cEnter,cCav))))),
             vn(vs(va(p.o, vm(p.d, least(cEnter,cCav))), ARRAY[24.0,12.0,17.5]::double precision[])),
             CASE WHEN cEnter <= cCav THEN 1.0 ELSE 0.0 END) AS nC
  FROM px p
  , LATERAL (SELECT vs(p.o, ARRAY[24.0,12.0,17.5]::double precision[]) AS ocA, vs(p.o, ARRAY[24.0,6.6,17.0]::double precision[]) AS ocB) q0
  , LATERAL (SELECT vd(q0.ocA,p.d) AS bA, vd(q0.ocA,q0.ocA)-36.0 AS cA,
                    vd(q0.ocB,p.d) AS bB, vd(q0.ocB,q0.ocB)-19.36 AS cB) q1
  , LATERAL (SELECT q1.bA*q1.bA-q1.cA AS dA, q1.bB*q1.bB-q1.cB AS dB) q2
  , LATERAL (SELECT CASE WHEN q2.dA > 0.0 THEN -q1.bA - sqrt(q2.dA) ELSE 1e9 END AS aNear,
                    CASE WHEN q2.dA > 0.0 THEN -q1.bA + sqrt(q2.dA) ELSE -1e9 END AS aFar,
                    CASE WHEN q2.dB > 0.0 THEN -q1.bB - sqrt(q2.dB) ELSE 1e9 END AS bNear,
                    CASE WHEN q2.dB > 0.0 THEN -q1.bB + sqrt(q2.dB) ELSE -1e9 END AS bFar) q3
  , LATERAL (SELECT CASE WHEN q3.aNear > 0.002 AND q3.aNear < 1e8
                              AND NOT (q3.bNear <= q3.aNear AND q3.aNear <= q3.bFar)
                         THEN q3.aNear ELSE 1e9 END AS cEnter,
                    CASE WHEN q3.bNear < 1e8 AND q3.bFar > 0.002
                              AND q3.aNear <= q3.bFar AND q3.bFar <= q3.aFar
                         THEN q3.bFar ELSE 1e9 END AS cCav) q4
),

-- ---- combine: nearest hit, normal via mix-blends, then shade (first hit, no bounce) ----
comb AS (
  SELECT p.idx, p.o, p.d,
         th.tTorus, tn.nTorus, ch.tCyl, ch.nCyl, sh.tSph, sh.nSph, pl.tC, pl.nC, tr.tTerr,
         least(ch.tCyl, least(sh.tSph, th.tTorus)) AS tLet,
         least(least(ch.tCyl, least(sh.tSph, th.tTorus)), pl.tC) AS tM,
         least(least(least(ch.tCyl, least(sh.tSph, th.tTorus)), pl.tC), tr.tTerr) AS tHit
  FROM px p
  JOIN tori_hit th USING (idx)
  JOIN tori_nrm tn USING (idx)
  JOIN cyl_hit ch USING (idx)
  JOIN sph_hit sh USING (idx)
  JOIN planet  pl USING (idx)
  JOIN terr    tr USING (idx)
),
nrm AS (
  SELECT c.*,
         va(o, vm(d, least(tHit, 5000.0))) AS hp,
         CASE WHEN tM < tTerr  AND tM < 1e8   THEN 1.0 ELSE 0.0 END AS isMirror,
         CASE WHEN tTerr <= tM AND tTerr < 1e8 THEN 1.0 ELSE 0.0 END AS isTerr,
         CASE WHEN tM >= 1e8   AND tTerr >= 1e8 THEN 1.0 ELSE 0.0 END AS isMiss,
         -- surface normal of the nearest reflective primitive
         mix(mix(mix(nSph, nCyl, CASE WHEN tCyl <= tSph THEN 1.0 ELSE 0.0 END),
                 nTorus, CASE WHEN tTorus <= tCyl AND tTorus <= tSph THEN 1.0 ELSE 0.0 END),
             nC, CASE WHEN tC < tLet THEN 1.0 ELSE 0.0 END) AS sn
  FROM comb c
),
shade AS (
  SELECT idx,
    va(va(
       vm(satb(vmul(terrCol(hp[3]),
                    va(vm(ARRAY[0.45,0.56,0.80]::double precision[], 0.26 + 0.18*greatest((terrN(hp[1],hp[2]))[3],0.0)),
                       vm(ARRAY[1.06,0.97,0.82]::double precision[],
                          1.45*greatest(vd(vn(vs(ARRAY[9.0,-30.0,52.0]::double precision[], hp)), terrN(hp[1],hp[2])),0.0))))), isTerr),
       vm(sky(vref(d, sn)), isMirror)),
       vm(sky(d), isMiss)) AS col
  FROM nrm
)
SELECT idx,
  round(clampS(0.0,1.0, power(greatest(col[1],0.0)*1.15, 1.0/2.2))*255)::int AS r,
  round(clampS(0.0,1.0, power(greatest(col[2],0.0)*1.15, 1.0/2.2))*255)::int AS g,
  round(clampS(0.0,1.0, power(greatest(col[3],0.0)*1.15, 1.0/2.2))*255)::int AS b
FROM shade
ORDER BY idx
) TO STDOUT WITH (FORMAT csv, DELIMITER E'	', HEADER false);
