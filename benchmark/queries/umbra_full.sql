-- ====================================================================
-- ClickHouse-over-terrain benchmark, Umbra port  (2560x1200, depth 2)
--   terrain + analytic letters + tori march + planet + shadows + bounces
-- ====================================================================

-- ---- vector helpers (double precision[3], 1-indexed) ----
CREATE OR REPLACE FUNCTION va(a double precision array, b double precision array) RETURNS double precision array LANGUAGE sql AS 'SELECT ARRAY[a[1]+b[1],a[2]+b[2],a[3]+b[3]]';
CREATE OR REPLACE FUNCTION vs(a double precision array, b double precision array) RETURNS double precision array LANGUAGE sql AS 'SELECT ARRAY[a[1]-b[1],a[2]-b[2],a[3]-b[3]]';
CREATE OR REPLACE FUNCTION vm(a double precision array, s double precision) RETURNS double precision array LANGUAGE sql AS 'SELECT ARRAY[a[1]*s,a[2]*s,a[3]*s]';
CREATE OR REPLACE FUNCTION vd(a double precision array, b double precision array) RETURNS double precision LANGUAGE sql AS 'SELECT a[1]*b[1]+a[2]*b[2]+a[3]*b[3]';
CREATE OR REPLACE FUNCTION vmul(a double precision array, b double precision array) RETURNS double precision array LANGUAGE sql AS 'SELECT ARRAY[a[1]*b[1],a[2]*b[2],a[3]*b[3]]';
CREATE OR REPLACE FUNCTION vn(a double precision array) RETURNS double precision array LANGUAGE sql AS 'SELECT vm(a, 1.0/sqrt(greatest(vd(a,a), 1e-18)))';
CREATE OR REPLACE FUNCTION vc(a double precision array, b double precision array) RETURNS double precision array LANGUAGE sql AS
  'SELECT ARRAY[a[2]*b[3]-a[3]*b[2], a[3]*b[1]-a[1]*b[3], a[1]*b[2]-a[2]*b[1]]';
CREATE OR REPLACE FUNCTION vref(d double precision array, n double precision array) RETURNS double precision array LANGUAGE sql AS 'SELECT vs(d, vm(n, 2.0*vd(d,n)))';
CREATE OR REPLACE FUNCTION mix(a double precision array, b double precision array, t double precision) RETURNS double precision array LANGUAGE sql AS 'SELECT va(a, vm(vs(b,a), t))';
-- pick a (c = 0) or b (c = 1) exactly; a + (b-a)*1 can miss b by an ulp, as a CASE would not
CREATE OR REPLACE FUNCTION sel(a double precision array, b double precision array, c double precision) RETURNS double precision array LANGUAGE sql AS 'SELECT va(vm(a, 1.0 - c), vm(b, c))';
CREATE OR REPLACE FUNCTION lerpS(a double precision, b double precision, t double precision) RETURNS double precision LANGUAGE sql AS 'SELECT a*(1.0-t)+b*t';
CREATE OR REPLACE FUNCTION clampS(lo double precision, hi double precision, x double precision) RETURNS double precision LANGUAGE sql AS 'SELECT greatest(lo, least(hi, x))';
CREATE OR REPLACE FUNCTION satb(c double precision array) RETURNS double precision array LANGUAGE sql AS
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
CREATE OR REPLACE FUNCTION terrN(x double precision, y double precision) RETURNS double precision array LANGUAGE sql AS
  'SELECT vn(ARRAY[(terrH(x-0.25,y)-terrH(x+0.25,y))/0.5, (terrH(x,y-0.25)-terrH(x,y+0.25))/0.5, 1.0])';
CREATE OR REPLACE FUNCTION terrCol(h double precision) RETURNS double precision array LANGUAGE sql AS
  'SELECT mix(mix(mix(mix(ARRAY[0.06,0.24,0.55]::double precision[], ARRAY[0.84,0.68,0.32]::double precision[], clampS(0.0,1.0,(h+0.6)/0.4)),
                  ARRAY[0.16,0.52,0.09]::double precision[], clampS(0.0,1.0,(h+0.1)/0.5)),
              ARRAY[0.46,0.32,0.22]::double precision[], clampS(0.0,1.0,(h-0.6)/0.4)),
          ARRAY[0.97,0.98,1.0]::double precision[], clampS(0.0,1.0,(h-1.0)/0.3))';
CREATE OR REPLACE FUNCTION sky(d double precision array) RETURNS double precision array LANGUAGE sql AS
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
  RETURNS double precision LANGUAGE sql AS 'SELECT least(greatest(tsdf3(px,py,pz,1.3,5.4,2.28,0.62), -bsdf3(px,py,pz,4.425,0.0,5.4,3.025,100.0,1.5)), least(greatest(tsdf3(px,py,pz,12.95,4.5,1.425,0.575), -bsdf3(px,py,pz,16.45,0.0,4.5,3.4,100.0,0.94)), least(greatest(tsdf3(px,py,pz,30.4,4.5,1.475,0.525), -bsdf3(px,py,pz,1000000.0,0.0,1000000.0,0.1,0.1,0.1)), least(greatest(tsdf3(px,py,pz,36.27,4.0,1.45,0.62), -bsdf3(px,py,pz,33.95,0.0,7.75,9.0,100.0,3.75)), least(greatest(tsdf3(px,py,pz,41.9,6.0,1.025,0.425), -bsdf3(px,py,pz,45.375,0.0,-0.25,3.475,100.0,6.25)), least(greatest(tsdf3(px,py,pz,41.9,3.9,1.025,0.425), -bsdf3(px,py,pz,36.375,0.0,7.7,5.525,100.0,3.8)), greatest(tsdf3(px,py,pz,47.25,4.55,1.585,0.465), -bsdf3(px,py,pz,50.8,0.0,3.87,3.25,100.0,0.32))))))))';

-- ---- ray / primitive intersection helpers (function parameters act as "let") ----
-- point along a ray, and a 0/1 weight from a predicate (for mix() selection)
CREATE OR REPLACE FUNCTION pt(o double precision array, d double precision array, t double precision) RETURNS double precision array LANGUAGE sql AS 'SELECT va(o, vm(d, t))';
CREATE OR REPLACE FUNCTION f01(c boolean) RETURNS double precision LANGUAGE sql AS 'SELECT CASE WHEN c THEN 1.0 ELSE 0.0 END';
-- tori SDF along a ray, and its normal by the reference's tetrahedral estimate: the SDF at
-- p + (e,-e,-e), (-e,-e,e), (-e,e,-e), (e,e,e), weighted by those signs (a, b, c, d here)
CREATE OR REPLACE FUNCTION toriAt(o double precision array, d double precision array, t double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT toriSDF3(o[1]+d[1]*t, o[2]+d[2]*t, o[3]+d[3]*t)';
CREATE OR REPLACE FUNCTION toriN4(a double precision, b double precision, c double precision, d double precision) RETURNS double precision array LANGUAGE sql AS
  'SELECT vn(ARRAY[(a - b) + (d - c), (-a - b) + (c + d), (b - a) + (d - c)])';
CREATE OR REPLACE FUNCTION toriN(p double precision array) RETURNS double precision array LANGUAGE sql AS
  'SELECT toriN4(toriSDF3(p[1]+0.0009,p[2]-0.0009,p[3]-0.0009), toriSDF3(p[1]-0.0009,p[2]-0.0009,p[3]+0.0009),
                 toriSDF3(p[1]-0.0009,p[2]+0.0009,p[3]-0.0009), toriSDF3(p[1]+0.0009,p[2]+0.0009,p[3]+0.0009))';
-- sphere (centre c, radius^2 rr): nearest t > eps, else 1e9
CREATE OR REPLACE FUNCTION sphT2(bb double precision, cc double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT CASE WHEN bb*bb-cc > 0.0 AND -bb-sqrt(greatest(bb*bb-cc,0.0)) > 0.002 THEN -bb-sqrt(greatest(bb*bb-cc,0.0)) ELSE 1e9 END';
CREATE OR REPLACE FUNCTION sphT(o double precision array, d double precision array, c double precision array, rr double precision) RETURNS double precision LANGUAGE sql AS
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
CREATE OR REPLACE FUNCTION cylBody(o double precision array, d double precision array, a double precision array, b double precision array, r double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT cylBody1(vd(vs(b,a),vs(b,a)), vd(vs(b,a),d), vd(vs(b,a),vs(o,a)), vd(d,vs(o,a)), vd(vs(o,a),vs(o,a)), r)';
CREATE OR REPLACE FUNCTION cylCap2(o double precision array, d double precision array, c double precision array, r double precision,
                                   den double precision, ta double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT CASE WHEN abs(den) > 1e-9 AND ta > 0.002 AND vd(vs(pt(o,d,ta),c), vs(pt(o,d,ta),c)) <= r*r THEN ta ELSE 1e9 END';
CREATE OR REPLACE FUNCTION cylCap(o double precision array, d double precision array, ba double precision array, c double precision array, r double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT cylCap2(o, d, c, r, vd(ba,d), vd(ba, vs(c,o))/CASE WHEN abs(vd(ba,d)) < 1e-12 THEN 1e-12 ELSE vd(ba,d) END)';
CREATE OR REPLACE FUNCTION cylT(o double precision array, d double precision array, a double precision array, b double precision array, r double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT least(cylBody(o,d,a,b,r), least(cylCap(o,d,vs(b,a),a,r), cylCap(o,d,vs(b,a),b,r)))';
-- normal at hit t: side normal on the body, -axis on cap a, +axis otherwise
CREATE OR REPLACE FUNCTION cylN2(t double precision, hp double precision array, a double precision array, ba double precision array,
                                 tBody double precision, tCapA double precision) RETURNS double precision array LANGUAGE sql AS
  'SELECT sel(sel(vn(ba), vn(vm(ba,-1.0)), f01(t = tCapA)),
              vn(vs(hp, va(a, vm(ba, vd(vs(hp,a),ba)/vd(ba,ba))))), f01(t = tBody))';
CREATE OR REPLACE FUNCTION cylN(o double precision array, d double precision array, t double precision,
                                a double precision array, b double precision array, r double precision) RETURNS double precision array LANGUAGE sql AS
  'SELECT cylN2(t, pt(o,d,t), a, vs(b,a), cylBody(o,d,a,b,r), cylCap(o,d,vs(b,a),a,r))';

-- ====================================================================
--  render
-- ====================================================================
-- the LATERAL "let" chains are intentional correlated joins, not accidental
-- cross products; allow them past Umbra's implicit-cross-product guard.
SET implicit_cross_products = ON;
COPY (
WITH RECURSIVE
cam0 AS (SELECT vn(vs(ARRAY[24.0,0.0,6.0]::double precision[], ARRAY[24.0,-45.0,12.0]::double precision[])) AS cf,
                 tan(36.0::double precision * 0.5 * pi() / 180.0) AS th, 2560.0::double precision / 1200.0::double precision AS aspect),
cam1 AS (SELECT cf, th, aspect, vn(vc(cf, ARRAY[0.0,0.0,1.0]::double precision[])) AS cr FROM cam0),
cam AS (SELECT cf, th, aspect, cr, vc(cr, cf) AS cu FROM cam1),
px AS (
  SELECT g AS idx, ARRAY[24.0,-45.0,12.0]::double precision[] AS o,
         vn(va(cam.cf,
                va(vm(cam.cr, (((g % 2560)::double precision + 0.5) / 2560.0::double precision * 2.0 - 1.0) * cam.aspect * cam.th),
                   vm(cam.cu, (1.0 - ((g / 2560)::double precision + 0.5) / 1200.0::double precision * 2.0) * cam.th)))) AS d,
         1.0::double precision AS thr, ARRAY[0.0,0.0,0.0]::double precision[] AS acc, 1.0::double precision AS alive
  FROM generate_series(0, 3071999) g, cam
),
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
-- ============================ bounce b1 ============================
in_b1 AS (SELECT idx, o, d, thr, acc FROM px WHERE alive > 0.5),

-- terrain height-field march (lockstep)
m_b1 AS (
  SELECT idx, o, d,
         CASE WHEN d[3] < -0.001 THEN greatest(0.05, (o[3]-1.55)/(-d[3])) ELSE 0.05 END AS t,
         0.0::double precision AS prevT, 1e9::double precision AS prevDiff,
         1e9::double precision AS result, 0 AS done, 0 AS iter
  FROM in_b1
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
        FROM m_b1 WHERE done = 0 AND iter < 110) s
),
terr_b1 AS (SELECT idx, min(CASE WHEN done = 1 THEN result ELSE 1e9 END) AS tTerr FROM m_b1 GROUP BY idx),

-- tori sphere-trace march (48 fixed steps)
tmar_b1 AS (
  SELECT idx, o, d, 0.02::double precision AS t, 0 AS iter FROM in_b1
  UNION ALL
  SELECT idx, o, d, t + toriAt(o, d, t), iter + 1 FROM tmar_b1 WHERE iter < 48
),
tori_b1 AS (
  SELECT idx, tTorus, toriN(pt(o, d, least(tTorus, 5000.0))) AS nTorus
  FROM (SELECT idx, o, d, CASE WHEN toriAt(o, d, t) < 0.01 AND t > 0.002 AND t < 260.0 THEN t ELSE 1e9 END AS tTorus
        FROM tmar_b1 WHERE iter = 48) z
),

-- nearest cylinder per pixel
cyl_b1 AS (
  SELECT idx, t AS tCyl, cylN(o, d, t, a, b, r) AS nCyl
  FROM (SELECT *, row_number() OVER (PARTITION BY idx ORDER BY t) AS rn
        FROM (SELECT p.idx, p.o, p.d, c.a, c.b, c.r, cylT(p.o, p.d, c.a, c.b, c.r) AS t
              FROM in_b1 p CROSS JOIN cyls c) y) z
  WHERE rn = 1
),

-- planet: sphere csgA with a spherical cavity csgB
planet_b1 AS (
  SELECT p.idx, least(cEnter, cCav) AS tC,
         sel(vn(vs(ARRAY[24.0,6.6,17.0]::double precision[], pt(p.o, p.d, least(cEnter,cCav)))),
             vn(vs(pt(p.o, p.d, least(cEnter,cCav)), ARRAY[24.0,12.0,17.5]::double precision[])),
             f01(cEnter <= cCav)) AS nC
  FROM in_b1 p
  , LATERAL (SELECT vs(p.o, ARRAY[24.0,12.0,17.5]::double precision[]) AS ocA, vs(p.o, ARRAY[24.0,6.6,17.0]::double precision[]) AS ocB) q0
  , LATERAL (SELECT vd(q0.ocA,p.d) AS bA, vd(q0.ocA,q0.ocA)-36.0 AS cA,
                    vd(q0.ocB,p.d) AS bB, vd(q0.ocB,q0.ocB)-19.36 AS cB) q1
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
comb_b1 AS (
  SELECT p.idx, p.o, p.d, p.thr, p.acc, h.tHit, h.isMirror, h.isTerr, h.isMiss, h.hp,
         n.tN, n.rdir, n.ldir, n.distL, va(h.hp, vm(sel(h.sn, n.tN, h.isTerr), 0.02)) AS shOrig
  FROM in_b1 p
  JOIN tori_b1 th USING (idx) JOIN cyl_b1 ch USING (idx)
  JOIN planet_b1 pl USING (idx) JOIN terr_b1 tr USING (idx)
  , LATERAL (SELECT sphT(p.o, p.d, ARRAY[8.65,0.0,8.8]::double precision[], 0.5184) AS tSph) sh
  , LATERAL (SELECT least(ch.tCyl, least(sh.tSph, th.tTorus)) AS tLet) a0
  , LATERAL (SELECT least(a0.tLet, pl.tC) AS tM) a1
  , LATERAL (SELECT least(a1.tM, tr.tTerr) AS tHit,
                    pt(p.o, p.d, least(least(a1.tM, tr.tTerr), 5000.0)) AS hp,
                    f01(a1.tM < tr.tTerr AND a1.tM < 1e8) AS isMirror,
                    f01(tr.tTerr <= a1.tM AND tr.tTerr < 1e8) AS isTerr,
                    f01(a1.tM >= 1e8 AND tr.tTerr >= 1e8) AS isMiss,
                    sel(sel(sel(vn(vs(pt(p.o, p.d, sh.tSph), ARRAY[8.65,0.0,8.8]::double precision[])), ch.nCyl, f01(ch.tCyl<=sh.tSph)),
                            th.nTorus, f01(th.tTorus<=ch.tCyl AND th.tTorus<=sh.tSph)),
                        pl.nC, f01(pl.tC<a0.tLet)) AS sn) h
  , LATERAL (SELECT terrN(h.hp[1], h.hp[2]) AS tN, vref(p.d, h.sn) AS rdir,
                    vn(vs(ARRAY[9.0,-30.0,52.0]::double precision[], h.hp)) AS ldir,
                    sqrt(vd(vs(ARRAY[9.0,-30.0,52.0]::double precision[], h.hp), vs(ARRAY[9.0,-30.0,52.0]::double precision[], h.hp))) AS distL) n
),

-- shadow ray: terrain (24 fixed steps), cylinders, tori (march); sphere in shade_b1
sterr_b1 AS (
  SELECT cb.idx, bool_or(
           (0.3::double precision + i*0.6::double precision) < cb.distL-0.05 AND
           cb.shOrig[3] + (0.3::double precision + i*0.6::double precision)*cb.ldir[3] <
             terrH(cb.shOrig[1] + (0.3::double precision + i*0.6::double precision)*cb.ldir[1], cb.shOrig[2] + (0.3::double precision + i*0.6::double precision)*cb.ldir[2])
         ) AS occ
  FROM comb_b1 cb CROSS JOIN generate_series(0,23) i
  GROUP BY cb.idx
),
stmar_b1 AS (
  SELECT idx, shOrig AS o, ldir AS d, distL, 0.02::double precision AS t, 0 AS iter FROM comb_b1
  UNION ALL
  SELECT idx, o, d, distL, t + toriAt(o, d, t), iter + 1 FROM stmar_b1 WHERE iter < 48
),
socc_b1 AS (
  SELECT cb.idx, bool_or(cylT(cb.shOrig, cb.ldir, c.a, c.b, c.r) < cb.distL-0.05) AS occ
  FROM comb_b1 cb CROSS JOIN cyls c GROUP BY cb.idx
),
stori_b1 AS (
  SELECT idx, toriAt(o, d, t) < 0.01 AND t > 0.002 AND t < 260.0 AND t < distL-0.05 AS occ
  FROM stmar_b1 WHERE iter = 48
),

-- shading, accumulation, next ray
shade_b1 AS (
  SELECT cb.idx,
         va(cb.acc, va(vm(ARRAY[1.0,1.0,1.0]::double precision[], cb.thr*spec*cb.isMirror),
                       va(vm(terrShade, cb.thr*cb.isTerr),
                          vm(sky(cb.d), cb.thr*cb.isMiss)))) AS acc,
         sel(cb.o, cb.shOrig, cb.isMirror) AS o,
         sel(cb.d, cb.rdir,   cb.isMirror) AS d,
         cb.thr * (1.0 - 0.28*cb.isMirror) AS thr,
         cb.isMirror AS alive
  FROM comb_b1 cb JOIN sterr_b1 se USING (idx) JOIN socc_b1 sc USING (idx) JOIN stori_b1 st USING (idx)
  , LATERAL (SELECT 1.0 - f01(se.occ OR sc.occ OR st.occ
                              OR sphT(cb.shOrig, cb.ldir, ARRAY[8.65,0.0,8.8]::double precision[], 0.5184) < cb.distL-0.05) AS lit) z1
  , LATERAL (SELECT power(greatest(vd(cb.ldir, cb.rdir),0.0), 60.0) * z1.lit AS spec,
                    greatest(vd(cb.ldir, cb.tN), 0.0) * z1.lit AS lambert,
                    least(1.0, greatest(0.0, (cb.tHit-70.0)/160.0)) AS fog) z2
  , LATERAL (SELECT va(vm(satb(vmul(terrCol(cb.hp[3]),
                          va(vm(ARRAY[0.45,0.56,0.8]::double precision[], 0.26 + 0.18*greatest(cb.tN[3],0.0)),
                             vm(ARRAY[1.06,0.97,0.82]::double precision[], 1.45*z2.lambert)))), 1.0 - z2.fog),
                      vm(ARRAY[0.66,0.78,0.96]::double precision[], z2.fog)) AS terrShade) z3
),
rays_b1 AS (
  SELECT idx, o, d, thr, acc, alive FROM shade_b1
  UNION ALL
  SELECT idx, o, d, thr, acc, 0.0 AS alive FROM px WHERE alive <= 0.5
),
-- ============================ bounce b2 ============================
in_b2 AS (SELECT idx, o, d, thr, acc FROM rays_b1 WHERE alive > 0.5),

-- terrain height-field march (lockstep)
m_b2 AS (
  SELECT idx, o, d,
         CASE WHEN d[3] < -0.001 THEN greatest(0.05, (o[3]-1.55)/(-d[3])) ELSE 0.05 END AS t,
         0.0::double precision AS prevT, 1e9::double precision AS prevDiff,
         1e9::double precision AS result, 0 AS done, 0 AS iter
  FROM in_b2
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
        FROM m_b2 WHERE done = 0 AND iter < 110) s
),
terr_b2 AS (SELECT idx, min(CASE WHEN done = 1 THEN result ELSE 1e9 END) AS tTerr FROM m_b2 GROUP BY idx),

-- tori sphere-trace march (48 fixed steps)
tmar_b2 AS (
  SELECT idx, o, d, 0.02::double precision AS t, 0 AS iter FROM in_b2
  UNION ALL
  SELECT idx, o, d, t + toriAt(o, d, t), iter + 1 FROM tmar_b2 WHERE iter < 48
),
tori_b2 AS (
  SELECT idx, tTorus, toriN(pt(o, d, least(tTorus, 5000.0))) AS nTorus
  FROM (SELECT idx, o, d, CASE WHEN toriAt(o, d, t) < 0.01 AND t > 0.002 AND t < 260.0 THEN t ELSE 1e9 END AS tTorus
        FROM tmar_b2 WHERE iter = 48) z
),

-- nearest cylinder per pixel
cyl_b2 AS (
  SELECT idx, t AS tCyl, cylN(o, d, t, a, b, r) AS nCyl
  FROM (SELECT *, row_number() OVER (PARTITION BY idx ORDER BY t) AS rn
        FROM (SELECT p.idx, p.o, p.d, c.a, c.b, c.r, cylT(p.o, p.d, c.a, c.b, c.r) AS t
              FROM in_b2 p CROSS JOIN cyls c) y) z
  WHERE rn = 1
),

-- planet: sphere csgA with a spherical cavity csgB
planet_b2 AS (
  SELECT p.idx, least(cEnter, cCav) AS tC,
         sel(vn(vs(ARRAY[24.0,6.6,17.0]::double precision[], pt(p.o, p.d, least(cEnter,cCav)))),
             vn(vs(pt(p.o, p.d, least(cEnter,cCav)), ARRAY[24.0,12.0,17.5]::double precision[])),
             f01(cEnter <= cCav)) AS nC
  FROM in_b2 p
  , LATERAL (SELECT vs(p.o, ARRAY[24.0,12.0,17.5]::double precision[]) AS ocA, vs(p.o, ARRAY[24.0,6.6,17.0]::double precision[]) AS ocB) q0
  , LATERAL (SELECT vd(q0.ocA,p.d) AS bA, vd(q0.ocA,q0.ocA)-36.0 AS cA,
                    vd(q0.ocB,p.d) AS bB, vd(q0.ocB,q0.ocB)-19.36 AS cB) q1
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
comb_b2 AS (
  SELECT p.idx, p.o, p.d, p.thr, p.acc, h.tHit, h.isMirror, h.isTerr, h.isMiss, h.hp,
         n.tN, n.rdir, n.ldir, n.distL, va(h.hp, vm(sel(h.sn, n.tN, h.isTerr), 0.02)) AS shOrig
  FROM in_b2 p
  JOIN tori_b2 th USING (idx) JOIN cyl_b2 ch USING (idx)
  JOIN planet_b2 pl USING (idx) JOIN terr_b2 tr USING (idx)
  , LATERAL (SELECT sphT(p.o, p.d, ARRAY[8.65,0.0,8.8]::double precision[], 0.5184) AS tSph) sh
  , LATERAL (SELECT least(ch.tCyl, least(sh.tSph, th.tTorus)) AS tLet) a0
  , LATERAL (SELECT least(a0.tLet, pl.tC) AS tM) a1
  , LATERAL (SELECT least(a1.tM, tr.tTerr) AS tHit,
                    pt(p.o, p.d, least(least(a1.tM, tr.tTerr), 5000.0)) AS hp,
                    f01(a1.tM < tr.tTerr AND a1.tM < 1e8) AS isMirror,
                    f01(tr.tTerr <= a1.tM AND tr.tTerr < 1e8) AS isTerr,
                    f01(a1.tM >= 1e8 AND tr.tTerr >= 1e8) AS isMiss,
                    sel(sel(sel(vn(vs(pt(p.o, p.d, sh.tSph), ARRAY[8.65,0.0,8.8]::double precision[])), ch.nCyl, f01(ch.tCyl<=sh.tSph)),
                            th.nTorus, f01(th.tTorus<=ch.tCyl AND th.tTorus<=sh.tSph)),
                        pl.nC, f01(pl.tC<a0.tLet)) AS sn) h
  , LATERAL (SELECT terrN(h.hp[1], h.hp[2]) AS tN, vref(p.d, h.sn) AS rdir,
                    vn(vs(ARRAY[9.0,-30.0,52.0]::double precision[], h.hp)) AS ldir,
                    sqrt(vd(vs(ARRAY[9.0,-30.0,52.0]::double precision[], h.hp), vs(ARRAY[9.0,-30.0,52.0]::double precision[], h.hp))) AS distL) n
),

-- shadow ray: terrain (24 fixed steps), cylinders, tori (march); sphere in shade_b2
sterr_b2 AS (
  SELECT cb.idx, bool_or(
           (0.3::double precision + i*0.6::double precision) < cb.distL-0.05 AND
           cb.shOrig[3] + (0.3::double precision + i*0.6::double precision)*cb.ldir[3] <
             terrH(cb.shOrig[1] + (0.3::double precision + i*0.6::double precision)*cb.ldir[1], cb.shOrig[2] + (0.3::double precision + i*0.6::double precision)*cb.ldir[2])
         ) AS occ
  FROM comb_b2 cb CROSS JOIN generate_series(0,23) i
  GROUP BY cb.idx
),
stmar_b2 AS (
  SELECT idx, shOrig AS o, ldir AS d, distL, 0.02::double precision AS t, 0 AS iter FROM comb_b2
  UNION ALL
  SELECT idx, o, d, distL, t + toriAt(o, d, t), iter + 1 FROM stmar_b2 WHERE iter < 48
),
socc_b2 AS (
  SELECT cb.idx, bool_or(cylT(cb.shOrig, cb.ldir, c.a, c.b, c.r) < cb.distL-0.05) AS occ
  FROM comb_b2 cb CROSS JOIN cyls c GROUP BY cb.idx
),
stori_b2 AS (
  SELECT idx, toriAt(o, d, t) < 0.01 AND t > 0.002 AND t < 260.0 AND t < distL-0.05 AS occ
  FROM stmar_b2 WHERE iter = 48
),

-- shading, accumulation, next ray
shade_b2 AS (
  SELECT cb.idx,
         va(cb.acc, va(vm(ARRAY[1.0,1.0,1.0]::double precision[], cb.thr*spec*cb.isMirror),
                       va(vm(terrShade, cb.thr*cb.isTerr),
                          vm(sky(cb.d), cb.thr*cb.isMiss)))) AS acc,
         sel(cb.o, cb.shOrig, cb.isMirror) AS o,
         sel(cb.d, cb.rdir,   cb.isMirror) AS d,
         cb.thr * (1.0 - 0.28*cb.isMirror) AS thr,
         cb.isMirror AS alive
  FROM comb_b2 cb JOIN sterr_b2 se USING (idx) JOIN socc_b2 sc USING (idx) JOIN stori_b2 st USING (idx)
  , LATERAL (SELECT 1.0 - f01(se.occ OR sc.occ OR st.occ
                              OR sphT(cb.shOrig, cb.ldir, ARRAY[8.65,0.0,8.8]::double precision[], 0.5184) < cb.distL-0.05) AS lit) z1
  , LATERAL (SELECT power(greatest(vd(cb.ldir, cb.rdir),0.0), 60.0) * z1.lit AS spec,
                    greatest(vd(cb.ldir, cb.tN), 0.0) * z1.lit AS lambert,
                    least(1.0, greatest(0.0, (cb.tHit-70.0)/160.0)) AS fog) z2
  , LATERAL (SELECT va(vm(satb(vmul(terrCol(cb.hp[3]),
                          va(vm(ARRAY[0.45,0.56,0.8]::double precision[], 0.26 + 0.18*greatest(cb.tN[3],0.0)),
                             vm(ARRAY[1.06,0.97,0.82]::double precision[], 1.45*z2.lambert)))), 1.0 - z2.fog),
                      vm(ARRAY[0.66,0.78,0.96]::double precision[], z2.fog)) AS terrShade) z3
),
rays_b2 AS (
  SELECT idx, o, d, thr, acc, alive FROM shade_b2
  UNION ALL
  SELECT idx, o, d, thr, acc, 0.0 AS alive FROM rays_b1 WHERE alive <= 0.5
)
SELECT idx,
  round(clampS(0.0,1.0, power(greatest(col[1],0.0)*1.15::double precision, 1.0::double precision/2.2::double precision))*255.0::double precision)::int AS r,
  round(clampS(0.0,1.0, power(greatest(col[2],0.0)*1.15::double precision, 1.0::double precision/2.2::double precision))*255.0::double precision)::int AS g,
  round(clampS(0.0,1.0, power(greatest(col[3],0.0)*1.15::double precision, 1.0::double precision/2.2::double precision))*255.0::double precision)::int AS b
FROM (
  SELECT idx, va(acc, vm(sky(d), thr*alive)) AS col FROM rays_b2
) f
ORDER BY idx
) TO STDOUT WITH (FORMAT csv, DELIMITER E'\t', HEADER false);
