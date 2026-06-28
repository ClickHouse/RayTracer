#!/usr/bin/env python3
"""MySQL PHASE-1 validation: JSON-vector functions + recursive-CTE terrain march
+ primary-ray terrain render. Proves the MySQL mechanics (JSON vectors survive
recursive CTEs, the inlined march, stored functions, TSV output) before the full
scene. Usage: gen_mysql_phase1.py [W] [H]  (default 32 16)
"""
import sys, math
W = int(sys.argv[1]) if len(sys.argv) > 1 else 32
H = int(sys.argv[2]) if len(sys.argv) > 2 else 16
def f(v): return repr(round(float(v), 8))
def J(xs): return "JSON_ARRAY(" + ",".join(f(x) for x in xs) + ")"

def sub(a,b): return [a[0]-b[0],a[1]-b[1],a[2]-b[2]]
def cross(a,b): return [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]]
def norm(a):
    l=math.sqrt(sum(c*c for c in a)); return [c/l for c in a]
EYE=[24.0,-45.0,12.0]; TARGET=[24.0,0.0,6.0]
FWD=norm(sub(TARGET,EYE)); RIGHT=norm(cross(FWD,[0.0,0.0,1.0])); UP=cross(RIGHT,FWD)
TANH=math.tan(36.0*0.5*math.pi/180.0); ASPECT=W/H

# JSON vec helpers: e(v,i) reads element i (0-based) as DOUBLE
def e(v,i): return f"JSON_VALUE({v},'$[{i}]' RETURNING DOUBLE)"

SCRIPT = f"""\
SET SESSION cte_max_recursion_depth = 100000;

DROP FUNCTION IF EXISTS va; DROP FUNCTION IF EXISTS vs; DROP FUNCTION IF EXISTS vm;
DROP FUNCTION IF EXISTS vd; DROP FUNCTION IF EXISTS vmul; DROP FUNCTION IF EXISTS vn;
DROP FUNCTION IF EXISTS mix; DROP FUNCTION IF EXISTS lerpS; DROP FUNCTION IF EXISTS clampS;
DROP FUNCTION IF EXISTS satb; DROP FUNCTION IF EXISTS hashf; DROP FUNCTION IF EXISTS fade;
DROP FUNCTION IF EXISTS vnoise; DROP FUNCTION IF EXISTS fbm; DROP FUNCTION IF EXISTS terrH;
DROP FUNCTION IF EXISTS terrN; DROP FUNCTION IF EXISTS terrCol; DROP FUNCTION IF EXISTS sky;

CREATE FUNCTION va(a JSON,b JSON) RETURNS JSON DETERMINISTIC RETURN JSON_ARRAY({e('a',0)}+{e('b',0)}, {e('a',1)}+{e('b',1)}, {e('a',2)}+{e('b',2)});
CREATE FUNCTION vs(a JSON,b JSON) RETURNS JSON DETERMINISTIC RETURN JSON_ARRAY({e('a',0)}-{e('b',0)}, {e('a',1)}-{e('b',1)}, {e('a',2)}-{e('b',2)});
CREATE FUNCTION vm(a JSON,s DOUBLE) RETURNS JSON DETERMINISTIC RETURN JSON_ARRAY({e('a',0)}*s, {e('a',1)}*s, {e('a',2)}*s);
CREATE FUNCTION vd(a JSON,b JSON) RETURNS DOUBLE DETERMINISTIC RETURN {e('a',0)}*{e('b',0)}+{e('a',1)}*{e('b',1)}+{e('a',2)}*{e('b',2)};
CREATE FUNCTION vmul(a JSON,b JSON) RETURNS JSON DETERMINISTIC RETURN JSON_ARRAY({e('a',0)}*{e('b',0)}, {e('a',1)}*{e('b',1)}, {e('a',2)}*{e('b',2)});
CREATE FUNCTION vn(a JSON) RETURNS JSON DETERMINISTIC RETURN vm(a, 1.0/sqrt(greatest(vd(a,a),1e-18)));
CREATE FUNCTION mix(a JSON,b JSON,t DOUBLE) RETURNS JSON DETERMINISTIC RETURN va(a, vm(vs(b,a), t));
CREATE FUNCTION lerpS(a DOUBLE,b DOUBLE,t DOUBLE) RETURNS DOUBLE DETERMINISTIC RETURN a*(1.0-t)+b*t;
CREATE FUNCTION clampS(lo DOUBLE,hi DOUBLE,x DOUBLE) RETURNS DOUBLE DETERMINISTIC RETURN greatest(lo, least(hi, x));
CREATE FUNCTION satb(c JSON) RETURNS JSON DETERMINISTIC RETURN mix(JSON_ARRAY({e('c',0)}*0.30+{e('c',1)}*0.59+{e('c',2)}*0.11, {e('c',0)}*0.30+{e('c',1)}*0.59+{e('c',2)}*0.11, {e('c',0)}*0.30+{e('c',1)}*0.59+{e('c',2)}*0.11), c, 1.45);

CREATE FUNCTION hashf(ix BIGINT,iy BIGINT) RETURNS DOUBLE DETERMINISTIC RETURN ((((((ix+4096)+(iy+4096)*8192)*1103515245+12345)%2147483648)*1103515245+12345)%2147483648%65536)/65536.0;
CREATE FUNCTION fade(t DOUBLE) RETURNS DOUBLE DETERMINISTIC RETURN t*t*t*(t*(t*6.0-15.0)+10.0);
CREATE FUNCTION vnoise(x DOUBLE,y DOUBLE) RETURNS DOUBLE DETERMINISTIC RETURN
  lerpS(lerpS(hashf(floor(x),floor(y)), hashf(floor(x)+1,floor(y)), fade(x-floor(x))),
        lerpS(hashf(floor(x),floor(y)+1), hashf(floor(x)+1,floor(y)+1), fade(x-floor(x))),
        fade(y-floor(y)));
CREATE FUNCTION fbm(x DOUBLE,y DOUBLE) RETURNS DOUBLE DETERMINISTIC RETURN
  (vnoise(x,y)*0.5 + vnoise(x*2.0,y*2.0)*0.25 + vnoise(x*4.0,y*4.0)*0.125 + vnoise(x*8.0,y*8.0)*0.0625)/0.9375;
CREATE FUNCTION terrH(x DOUBLE,y DOUBLE) RETURNS DOUBLE DETERMINISTIC RETURN 2.4*(fbm(x*0.05,y*0.05)-0.5);
CREATE FUNCTION terrN(x DOUBLE,y DOUBLE) RETURNS JSON DETERMINISTIC RETURN vn(JSON_ARRAY((terrH(x-0.25,y)-terrH(x+0.25,y))/0.5, (terrH(x,y-0.25)-terrH(x,y+0.25))/0.5, 1.0));
CREATE FUNCTION terrCol(h DOUBLE) RETURNS JSON DETERMINISTIC RETURN
  mix(mix(mix(mix(JSON_ARRAY(0.06,0.24,0.55), JSON_ARRAY(0.84,0.68,0.32), clampS(0.0,1.0,(h+0.6)/0.4)),
                  JSON_ARRAY(0.16,0.52,0.09), clampS(0.0,1.0,(h+0.1)/0.5)),
              JSON_ARRAY(0.46,0.32,0.22), clampS(0.0,1.0,(h-0.6)/0.4)),
          JSON_ARRAY(0.97,0.98,1.0), clampS(0.0,1.0,(h-1.0)/0.3));
CREATE FUNCTION sky(d JSON) RETURNS JSON DETERMINISTIC RETURN mix(JSON_ARRAY(0.66,0.78,0.96), JSON_ARRAY(0.30,0.50,0.85), greatest(0.0, least(1.0, {e('d',2)}*1.5)));

WITH RECURSIVE
seq(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM seq WHERE i < {W*H-1}),
px AS (
  SELECT i AS idx,
         CAST({J(EYE)} AS JSON) AS o,
         vn(va(CAST({J(FWD)} AS JSON),
                va(vm(CAST({J(RIGHT)} AS JSON), (((i % {W}) + 0.5)/{f(W)}*2.0-1.0)*{f(ASPECT)}*{f(TANH)}),
                   vm(CAST({J(UP)} AS JSON), (1.0 - (FLOOR(i/{W})+0.5)/{f(H)}*2.0)*{f(TANH)})))) AS d
  FROM seq
),
m AS (
  SELECT idx, o, d,
         CASE WHEN {e('d',2)} < -0.001 THEN greatest(0.05, ({e('o',2)}-1.55)/(-{e('d',2)})) ELSE 0.05 END AS t,
         CAST(0.0 AS DOUBLE) AS prevT, CAST(1e9 AS DOUBLE) AS prevDiff,
         CAST(1e9 AS DOUBLE) AS result, 0 AS done, 0 AS iter
  FROM px
  UNION ALL
  SELECT idx, o, d,
    CASE WHEN prevDiff>0.0 AND ({e('o',2)}+t*{e('d',2)}-terrH({e('o',0)}+t*{e('d',0)},{e('o',1)}+t*{e('d',1)}))<=0.0 THEN t ELSE t+greatest(0.06,t*0.035) END,
    t,
    ({e('o',2)}+t*{e('d',2)}-terrH({e('o',0)}+t*{e('d',0)},{e('o',1)}+t*{e('d',1)})),
    CASE WHEN prevDiff>0.0 AND ({e('o',2)}+t*{e('d',2)}-terrH({e('o',0)}+t*{e('d',0)},{e('o',1)}+t*{e('d',1)}))<=0.0
              THEN prevT + (t-prevT)*prevDiff/(prevDiff-({e('o',2)}+t*{e('d',2)}-terrH({e('o',0)}+t*{e('d',0)},{e('o',1)}+t*{e('d',1)}))) ELSE 1e9 END,
    CASE WHEN prevDiff>0.0 AND ({e('o',2)}+t*{e('d',2)}-terrH({e('o',0)}+t*{e('d',0)},{e('o',1)}+t*{e('d',1)}))<=0.0 THEN 1
         WHEN {e('o',2)}+t*{e('d',2)} > 1.55 AND {e('d',2)}>=0.0 THEN 2 ELSE 0 END,
    iter+1
  FROM m WHERE done=0 AND iter<110
),
terr AS (SELECT idx, MIN(CASE WHEN done=1 THEN result ELSE 1e9 END) AS tTerr FROM m GROUP BY idx),
hit AS (
  SELECT p.idx, p.o, p.d, t.tTerr, va(p.o, vm(p.d, least(t.tTerr,5000.0))) AS hp
  FROM px p JOIN terr t ON p.idx=t.idx
),
shade AS (
  SELECT idx,
    mix(satb(vmul(terrCol({e('hp',2)}),
                  va(vm(CAST(JSON_ARRAY(0.45,0.56,0.80) AS JSON), 0.26+0.18*greatest(JSON_VALUE(terrN({e('hp',0)},{e('hp',1)}),'$[2]' RETURNING DOUBLE),0.0)),
                     vm(CAST(JSON_ARRAY(1.06,0.97,0.82) AS JSON),
                        1.45*greatest(vd(vn(vs(CAST(JSON_ARRAY(9.0,-30.0,52.0) AS JSON), hp)), terrN({e('hp',0)},{e('hp',1)})),0.0))))),
        sky(d),
        CASE WHEN tTerr>1e8 THEN 1.0 ELSE 0.0 END) AS col
  FROM hit
)
SELECT idx,
  CAST(ROUND(clampS(0.0,1.0, POWER(greatest({e('col',0)},0.0)*1.15, 1.0/2.2))*255) AS SIGNED) AS r,
  CAST(ROUND(clampS(0.0,1.0, POWER(greatest({e('col',1)},0.0)*1.15, 1.0/2.2))*255) AS SIGNED) AS g,
  CAST(ROUND(clampS(0.0,1.0, POWER(greatest({e('col',2)},0.0)*1.15, 1.0/2.2))*255) AS SIGNED) AS b
FROM shade ORDER BY idx;
"""
sys.stdout.write(SCRIPT)
