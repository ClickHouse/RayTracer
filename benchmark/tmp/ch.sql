-- ====================================================================
-- ClickHouse-over-terrain benchmark, CedarDB port (PHASE 1: terrain only)
-- ====================================================================

-- ---- vector helpers (double precision[3], 1-indexed) ----
CREATE OR REPLACE FUNCTION va(a double precision[], b double precision[]) RETURNS double precision[] LANGUAGE sql AS 'ARRAY[a[1]+b[1],a[2]+b[2],a[3]+b[3]]';
CREATE OR REPLACE FUNCTION vs(a double precision[], b double precision[]) RETURNS double precision[] LANGUAGE sql AS 'ARRAY[a[1]-b[1],a[2]-b[2],a[3]-b[3]]';
CREATE OR REPLACE FUNCTION vm(a double precision[], s double precision) RETURNS double precision[] LANGUAGE sql AS 'ARRAY[a[1]*s,a[2]*s,a[3]*s]';
CREATE OR REPLACE FUNCTION vd(a double precision[], b double precision[]) RETURNS double precision LANGUAGE sql AS 'a[1]*b[1]+a[2]*b[2]+a[3]*b[3]';
CREATE OR REPLACE FUNCTION vmul(a double precision[], b double precision[]) RETURNS double precision[] LANGUAGE sql AS 'ARRAY[a[1]*b[1],a[2]*b[2],a[3]*b[3]]';
CREATE OR REPLACE FUNCTION vn(a double precision[]) RETURNS double precision[] LANGUAGE sql AS 'vm(a, 1.0/sqrt(vd(a,a)))';
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

-- ====================================================================
--  render
-- ====================================================================

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
-- terrain height-field march; all rays advance in lockstep.
-- done: 0 = keep marching, 1 = hit (result=t), 2 = escaped above terrain.
-- (no LATERAL in the recursive term: CedarDB's array runtime asserts on it,
--  so the per-step expressions are inlined instead.)
m AS (
  SELECT idx, o, d,
         CASE WHEN d[3] < -0.001 THEN greatest(0.05, (o[3]-1.55)/(-d[3])) ELSE 0.05 END AS t,
         0.0::double precision AS prevT,
         1e9::double precision  AS prevDiff,
         1e9::double precision  AS result,
         0 AS done, 0 AS iter
  FROM px
  UNION ALL
  SELECT idx, o, d,
    CASE WHEN prevDiff > 0.0 AND dc <= 0.0 THEN t ELSE t + greatest(0.06, t*0.035) END AS t,
    t AS prevT,
    dc AS prevDiff,
    CASE WHEN prevDiff > 0.0 AND dc <= 0.0
              THEN prevT + (t - prevT) * prevDiff / (prevDiff - dc)
         ELSE 1e9 END AS result,
    CASE WHEN prevDiff > 0.0 AND dc <= 0.0 THEN 1
         WHEN o[3] + t*d[3] > 1.55 AND d[3] >= 0.0 THEN 2
         ELSE 0 END AS done,
    iter + 1
  FROM (
    SELECT idx, o, d, t, prevT, prevDiff, iter,
           o[3] + t*d[3] - terrH(o[1] + t*d[1], o[2] + t*d[2]) AS dc
    FROM m WHERE done = 0 AND iter < 110
  ) s
),
terr AS (
  SELECT idx, min(CASE WHEN done = 1 THEN result ELSE 1e9 END) AS tHit
  FROM m GROUP BY idx
),
hit AS (
  SELECT p.idx, p.o, p.d, t.tHit,
         va(p.o, vm(p.d, t.tHit)) AS hp
  FROM px p JOIN terr t USING (idx)
),
shade AS (
  SELECT idx,
    CASE WHEN tHit > 1e8 THEN sky(d)
         ELSE
           satb(vmul(terrCol(hp[3]),
                     va(vm(ARRAY[0.45,0.56,0.80]::double precision[],
                            0.26 + 0.18*greatest((terrN(hp[1], hp[2]))[3], 0.0)),
                        vm(ARRAY[1.06,0.97,0.82]::double precision[],
                            1.45*greatest(vd(vn(vs(ARRAY[9.0,-30.0,52.0]::double precision[], hp)),
                                             terrN(hp[1], hp[2])), 0.0)))))
    END AS col
  FROM hit
),
c1 AS (SELECT idx, col, col[1] AS cr FROM shade),
     c2 AS (SELECT idx, col, cr, col[2] AS cg FROM c1),
     c3 AS (SELECT idx, cr, cg, col[3] AS cb FROM c2)
SELECT idx, cr, cg, cb FROM c3 ORDER BY idx LIMIT 4;
