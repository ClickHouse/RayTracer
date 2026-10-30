-- ====================================================================
-- ClickHouse-over-terrain benchmark, SereneDB port  (2560x1200, depth 2)
--   terrain + analytic letters + tori march + planet + shadows + bounces
-- ====================================================================
-- the portable hash overflows BIGINT for rays that miss the terrain; wrap, as ClickHouse does
SET integer_overflow = 'wrap';

-- scene constants
CREATE OR REPLACE MACRO eye()        AS (24.0::DOUBLE, -45.0::DOUBLE, 12.0::DOUBLE);
CREATE OR REPLACE MACRO target()     AS (24.0::DOUBLE, 0.0::DOUBLE, 6.0::DOUBLE);
CREATE OR REPLACE MACRO lightPos()   AS (9.0::DOUBLE, -30.0::DOUBLE, 52.0::DOUBLE);
CREATE OR REPLACE MACRO hazeColor()  AS (0.66::DOUBLE, 0.78::DOUBLE, 0.96::DOUBLE);
CREATE OR REPLACE MACRO skyTop()     AS (0.30::DOUBLE, 0.50::DOUBLE, 0.85::DOUBLE);
CREATE OR REPLACE MACRO skyAmb()     AS (0.45::DOUBLE, 0.56::DOUBLE, 0.80::DOUBLE);
CREATE OR REPLACE MACRO sunCol()     AS (1.06::DOUBLE, 0.97::DOUBLE, 0.82::DOUBLE);
CREATE OR REPLACE MACRO specColor()  AS (1.0::DOUBLE, 1.0::DOUBLE, 1.0::DOUBLE);
CREATE OR REPLACE MACRO csgA()       AS (24.0::DOUBLE, 12.0::DOUBLE, 17.5::DOUBLE);
CREATE OR REPLACE MACRO csgB()       AS (24.0::DOUBLE, 6.6::DOUBLE, 17.0::DOUBLE);
CREATE OR REPLACE MACRO csgAr()      AS 6.0::DOUBLE;
CREATE OR REPLACE MACRO csgBr()      AS 4.4::DOUBLE;
CREATE OR REPLACE MACRO eps()        AS 0.002::DOUBLE;
CREATE OR REPLACE MACRO reflect_k()  AS 0.72::DOUBLE;
CREATE OR REPLACE MACRO shininess()  AS 60.0::DOUBLE;
CREATE OR REPLACE MACRO exposure()   AS 1.15::DOUBLE;
CREATE OR REPLACE MACRO gamma_()     AS 2.2::DOUBLE;
CREATE OR REPLACE MACRO fovDeg()     AS 36.0::DOUBLE;
CREATE OR REPLACE MACRO imgW()       AS 2560.0::DOUBLE;
CREATE OR REPLACE MACRO imgH()       AS 1200.0::DOUBLE;
CREATE OR REPLACE MACRO maxDepth()   AS 2;
CREATE OR REPLACE MACRO marchSteps() AS 48;
CREATE OR REPLACE MACRO marchEps()   AS 0.01::DOUBLE;
CREATE OR REPLACE MACRO marchMax()   AS 260.0::DOUBLE;
CREATE OR REPLACE MACRO tAmp()       AS 2.4::DOUBLE;
CREATE OR REPLACE MACRO tscale()     AS 0.05::DOUBLE;
CREATE OR REPLACE MACRO tBias()      AS 0.5::DOUBLE;
CREATE OR REPLACE MACRO maxTerrH()   AS 1.55::DOUBLE;
CREATE OR REPLACE MACRO terrSteps()      AS 110;
CREATE OR REPLACE MACRO terrShadowSteps() AS 24;
CREATE OR REPLACE MACRO fogStart()   AS 70.0::DOUBLE;
CREATE OR REPLACE MACRO fogRange()   AS 160.0::DOUBLE;

-- geometry
CREATE OR REPLACE MACRO cyls() AS [(5.75::DOUBLE,0.0::DOUBLE,2.5::DOUBLE,5.75::DOUBLE,0.0::DOUBLE,9.5::DOUBLE,0.62::DOUBLE), (8.65::DOUBLE,0.0::DOUBLE,2.5::DOUBLE,8.65::DOUBLE,0.0::DOUBLE,7.5::DOUBLE,0.62::DOUBLE), (16.8::DOUBLE,0.0::DOUBLE,2.5::DOUBLE,16.8::DOUBLE,0.0::DOUBLE,9.5::DOUBLE,0.62::DOUBLE), (17.15::DOUBLE,0.0::DOUBLE,5.0::DOUBLE,20.05::DOUBLE,0.0::DOUBLE,7.6::DOUBLE,0.62::DOUBLE), (17.35::DOUBLE,0.0::DOUBLE,5.1::DOUBLE,20.05::DOUBLE,0.0::DOUBLE,2.5::DOUBLE,0.62::DOUBLE), (22.4::DOUBLE,0.0::DOUBLE,2.5::DOUBLE,22.4::DOUBLE,0.0::DOUBLE,9.5::DOUBLE,0.62::DOUBLE), (26.15::DOUBLE,0.0::DOUBLE,2.5::DOUBLE,26.15::DOUBLE,0.0::DOUBLE,9.5::DOUBLE,0.62::DOUBLE), (22.35::DOUBLE,0.0::DOUBLE,6.0::DOUBLE,26.15::DOUBLE,0.0::DOUBLE,6.0::DOUBLE,0.62::DOUBLE), (34.82::DOUBLE,0.0::DOUBLE,3.5::DOUBLE,34.82::DOUBLE,0.0::DOUBLE,7.5::DOUBLE,0.62::DOUBLE), (37.72::DOUBLE,0.0::DOUBLE,3.5::DOUBLE,37.72::DOUBLE,0.0::DOUBLE,7.5::DOUBLE,0.62::DOUBLE), (45.35::DOUBLE,0.0::DOUBLE,4.6::DOUBLE,48.85::DOUBLE,0.0::DOUBLE,4.6::DOUBLE,0.41333::DOUBLE)];
CREATE OR REPLACE MACRO sphs() AS [(8.65::DOUBLE,0.0::DOUBLE,8.8::DOUBLE,0.72::DOUBLE)];
CREATE OR REPLACE MACRO tori() AS [(1.3::DOUBLE,5.4::DOUBLE,2.28::DOUBLE,0.62::DOUBLE,4.425::DOUBLE,0.0::DOUBLE,5.4::DOUBLE,3.025::DOUBLE,100.0::DOUBLE,1.5::DOUBLE), (12.95::DOUBLE,4.5::DOUBLE,1.425::DOUBLE,0.575::DOUBLE,16.45::DOUBLE,0.0::DOUBLE,4.5::DOUBLE,3.4::DOUBLE,100.0::DOUBLE,0.94::DOUBLE), (30.4::DOUBLE,4.5::DOUBLE,1.475::DOUBLE,0.525::DOUBLE,1000000.0::DOUBLE,0.0::DOUBLE,1000000.0::DOUBLE,0.1::DOUBLE,0.1::DOUBLE,0.1::DOUBLE), (36.27::DOUBLE,4.0::DOUBLE,1.45::DOUBLE,0.62::DOUBLE,33.95::DOUBLE,0.0::DOUBLE,7.75::DOUBLE,9.0::DOUBLE,100.0::DOUBLE,3.75::DOUBLE), (41.9::DOUBLE,6.0::DOUBLE,1.025::DOUBLE,0.425::DOUBLE,45.375::DOUBLE,0.0::DOUBLE,-0.25::DOUBLE,3.475::DOUBLE,100.0::DOUBLE,6.25::DOUBLE), (41.9::DOUBLE,3.9::DOUBLE,1.025::DOUBLE,0.425::DOUBLE,36.375::DOUBLE,0.0::DOUBLE,7.7::DOUBLE,5.525::DOUBLE,100.0::DOUBLE,3.8::DOUBLE), (47.25::DOUBLE,4.55::DOUBLE,1.585::DOUBLE,0.465::DOUBLE,50.8::DOUBLE,0.0::DOUBLE,3.87::DOUBLE,3.25::DOUBLE,100.0::DOUBLE,0.32::DOUBLE)];

-- vector helpers
CREATE OR REPLACE MACRO va(a,b)  AS (a[1]+b[1], a[2]+b[2], a[3]+b[3]);
CREATE OR REPLACE MACRO vs(a,b)  AS (a[1]-b[1], a[2]-b[2], a[3]-b[3]);
CREATE OR REPLACE MACRO vm(a,s)  AS (a[1]*s, a[2]*s, a[3]*s);
CREATE OR REPLACE MACRO vd(a,b)  AS a[1]*b[1] + a[2]*b[2] + a[3]*b[3];
CREATE OR REPLACE MACRO vmul(a,b) AS (a[1]*b[1], a[2]*b[2], a[3]*b[3]);
CREATE OR REPLACE MACRO vn(a)    AS vm(a, 1.0::DOUBLE/sqrt(vd(a,a)));
CREATE OR REPLACE MACRO vc(a,b)  AS (a[2]*b[3]-a[3]*b[2], a[3]*b[1]-a[1]*b[3], a[1]*b[2]-a[2]*b[1]);
CREATE OR REPLACE MACRO vref(d,n) AS vs(d, vm(n, 2.0::DOUBLE*vd(d,n)));
CREATE OR REPLACE MACRO mix(a,b,t) AS va(a, vm(vs(b,a), t));
CREATE OR REPLACE MACRO lerpS(a,b,t) AS a*(1.0::DOUBLE-t) + b*t;
CREATE OR REPLACE MACRO clamp3(lo,hi,x) AS greatest(lo, least(hi, x));

-- camera basis
CREATE OR REPLACE MACRO camFwd()   AS vn(vs(target(), eye()));
CREATE OR REPLACE MACRO camRight() AS vn(vc(camFwd(), (0.0::DOUBLE,0.0::DOUBLE,1.0::DOUBLE)));
CREATE OR REPLACE MACRO camUp()    AS vc(camRight(), camFwd());
CREATE OR REPLACE MACRO tanHalf()  AS tan(fovDeg()*0.5::DOUBLE*pi()/180.0::DOUBLE);
CREATE OR REPLACE MACRO aspect()   AS imgW()/imgH();

-- nearest sphere root, or 1e9
CREATE OR REPLACE MACRO sphT(O,D,C,r) AS
  if(vd(vs(O,C),D)*vd(vs(O,C),D) - (vd(vs(O,C),vs(O,C))-r*r) > 0.0::DOUBLE
     AND -vd(vs(O,C),D) - sqrt(greatest(vd(vs(O,C),D)*vd(vs(O,C),D)-(vd(vs(O,C),vs(O,C))-r*r),0.0::DOUBLE)) > eps(),
     -vd(vs(O,C),D) - sqrt(greatest(vd(vs(O,C),D)*vd(vs(O,C),D)-(vd(vs(O,C),vs(O,C))-r*r),0.0::DOUBLE)), 1e9);
-- sphere near/far parameters (planet), (1e9,-1e9) if missed
CREATE OR REPLACE MACRO sphPair(o,d,c,rad) AS
  if(vd(vs(o,c),d)*vd(vs(o,c),d) - (vd(vs(o,c),vs(o,c))-rad*rad) > 0.0::DOUBLE,
     (-vd(vs(o,c),d) - sqrt(greatest(vd(vs(o,c),d)*vd(vs(o,c),d)-(vd(vs(o,c),vs(o,c))-rad*rad),0.0::DOUBLE)),
      -vd(vs(o,c),d) + sqrt(greatest(vd(vs(o,c),d)*vd(vs(o,c),d)-(vd(vs(o,c),vs(o,c))-rad*rad),0.0::DOUBLE))),
     (1e9, -1e9));

-- finite cylinder (rod): lateral body, two flat disk caps; nearest entry or 1e9
CREATE OR REPLACE MACRO cylBodyT(O,D,A,B,r) AS list_transform([vs(B,A)], ba -> list_transform([vs(O,A)], oa -> list_transform([vd(ba,ba)], baba -> list_transform([vd(ba,D)], bard -> list_transform([vd(ba,oa)], baoa -> list_transform([baba - bard*bard], aa -> list_transform([baba*vd(D,oa) - baoa*bard], bb -> list_transform([baba*vd(oa,oa) - baoa*baoa - r*r*baba], cc -> list_transform([bb*bb - aa*cc], hh -> list_transform([(-bb - sqrt(greatest(hh,0.0::DOUBLE)))/aa], t -> list_transform([baoa + t*bard], y -> if(hh >= 0.0::DOUBLE AND aa > 1e-9 AND t > eps() AND y > 0.0::DOUBLE AND y < baba, t, 1e9))[1])[1])[1])[1])[1])[1])[1])[1])[1])[1])[1];
CREATE OR REPLACE MACRO diskT(O,D,P,ax,r) AS list_transform([vd(ax, D)], den -> list_transform([vd(ax, vs(P,O))/den], t -> list_transform([va(O, vm(D, t))], hp -> if(abs(den) > 1e-9 AND t > eps() AND vd(vs(hp,P), vs(hp,P)) <= r*r, t, 1e9))[1])[1])[1];
CREATE OR REPLACE MACRO rodT(O,D,A,B,r) AS least(cylBodyT(O,D,A,B,r), least(diskT(O,D,A,vs(B,A),r), diskT(O,D,B,vs(B,A),r)));
CREATE OR REPLACE MACRO rodN(O,D,A,B,r) AS list_transform([vs(B,A)], ba -> list_transform([cylBodyT(O,D,A,B,r)], tL -> list_transform([diskT(O,D,A,ba,r)], tA -> list_transform([diskT(O,D,B,ba,r)], tB -> list_transform([least(tL, least(tA,tB))], tm -> list_transform([va(O, vm(D,tm))], hp -> if(tm = tL, vn(vs(hp, va(A, vm(ba, vd(vs(hp,A),ba)/vd(ba,ba))))), if(tm = tA, vn(vm(ba,-1.0::DOUBLE)), vn(ba))))[1])[1])[1])[1])[1])[1];

-- tori, via signed-distance ray marching.  tl = (cx,cz,R,r, bcx,bcy,bcz, bhx,bhy,bhz)
CREATE OR REPLACE MACRO tsdf(p,tl) AS sqrt(pow(sqrt((p[1]-tl[1])*(p[1]-tl[1])+(p[3]-tl[2])*(p[3]-tl[2])) - tl[3], 2) + p[2]*p[2]) - tl[4];
CREATE OR REPLACE MACRO bsdf(p,C,Hh) AS
  sqrt(pow(greatest(abs(p[1]-C[1])-Hh[1],0.0::DOUBLE),2) + pow(greatest(abs(p[2]-C[2])-Hh[2],0.0::DOUBLE),2) + pow(greatest(abs(p[3]-C[3])-Hh[3],0.0::DOUBLE),2))
  + least(greatest(abs(p[1]-C[1])-Hh[1], greatest(abs(p[2]-C[2])-Hh[2], abs(p[3]-C[3])-Hh[3])), 0.0::DOUBLE);
CREATE OR REPLACE MACRO toriSDF(p) AS list_min(list_transform(tori(), tl -> greatest(tsdf(p, tl), -bsdf(p, (tl[5],tl[6],tl[7]), (tl[8],tl[9],tl[10])))));
-- NB: bind the marched point with a 1-element list_transform before calling
-- toriSDF, else the macro (call-by-name) re-expands va(O,vm(D,t)) ~9x.
CREATE OR REPLACE MACRO marchTorus(O,D) AS
  list_transform([list_reduce(range(marchSteps()),
                              (t,jj) -> t + list_transform([va(O, vm(D, t))], p -> toriSDF(p))[1],
                              0.02::DOUBLE)],
                 tfin -> if(list_transform([va(O, vm(D, tfin))], p -> toriSDF(p))[1] < marchEps() AND tfin > eps() AND tfin < marchMax(), tfin, 1e9))[1];
CREATE OR REPLACE MACRO torusN(O,D,t) AS
  list_transform([va(O, vm(D, t))], p -> vn(va(va(vm((1.0::DOUBLE,-1.0::DOUBLE,-1.0::DOUBLE), toriSDF(va(p, (0.0009::DOUBLE,-0.0009::DOUBLE,-0.0009::DOUBLE)))),
                                                  vm((-1.0::DOUBLE,-1.0::DOUBLE,1.0::DOUBLE), toriSDF(va(p, (-0.0009::DOUBLE,-0.0009::DOUBLE,0.0009::DOUBLE))))),
                                               va(vm((-1.0::DOUBLE,1.0::DOUBLE,-1.0::DOUBLE), toriSDF(va(p, (-0.0009::DOUBLE,0.0009::DOUBLE,-0.0009::DOUBLE)))),
                                                  vm((1.0::DOUBLE,1.0::DOUBLE,1.0::DOUBLE), toriSDF(va(p, (0.0009::DOUBLE,0.0009::DOUBLE,0.0009::DOUBLE))))))))[1];

-- shadow test against cylinders, tori, spheres
CREATE OR REPLACE MACRO occluded(o,d,maxd) AS
  len(list_filter(cyls(), c -> rodT(o, d, (c[1],c[2],c[3]), (c[4],c[5],c[6]), c[7]) < maxd)) > 0
  OR len(list_filter(sphs(), sp -> sphT(o, d, (sp[1],sp[2],sp[3]), sp[4]) < maxd)) > 0
  OR (marchTorus(o, d) < maxd);
CREATE OR REPLACE MACRO sky(d) AS mix(hazeColor(), skyTop(), greatest(0.0::DOUBLE, least(1.0::DOUBLE, d[3]*1.5::DOUBLE)));

-- portable terrain noise (identical to the ClickHouse version; never overflows int64)
CREATE OR REPLACE MACRO hashf(ix,iy) AS ((((((ix + 4096) + (iy + 4096) * 8192) * 1103515245 + 12345) % 2147483648) * 1103515245 + 12345) % 2147483648 % 65536) / 65536.0::DOUBLE;
CREATE OR REPLACE MACRO fade(t) AS t*t*t*(t*(t*6.0::DOUBLE-15.0::DOUBLE)+10.0::DOUBLE);
CREATE OR REPLACE MACRO vnoise(x,y) AS
  lerpS(lerpS(hashf(CAST(floor(x) AS BIGINT),   CAST(floor(y) AS BIGINT)),   hashf(CAST(floor(x) AS BIGINT)+1, CAST(floor(y) AS BIGINT)),   fade(x-floor(x))),
        lerpS(hashf(CAST(floor(x) AS BIGINT),   CAST(floor(y) AS BIGINT)+1), hashf(CAST(floor(x) AS BIGINT)+1, CAST(floor(y) AS BIGINT)+1), fade(x-floor(x))),
        fade(y-floor(y)));
CREATE OR REPLACE MACRO fbm(x,y) AS (vnoise(x,y)*0.5::DOUBLE + vnoise(x*2.0::DOUBLE,y*2.0::DOUBLE)*0.25::DOUBLE + vnoise(x*4.0::DOUBLE,y*4.0::DOUBLE)*0.125::DOUBLE + vnoise(x*8.0::DOUBLE,y*8.0::DOUBLE)*0.0625::DOUBLE)/0.9375::DOUBLE;
CREATE OR REPLACE MACRO terrH(x,y) AS tAmp()*(fbm(x*tscale(), y*tscale()) - tBias());
CREATE OR REPLACE MACRO terrN(x,y) AS vn(((terrH(x-0.25::DOUBLE,y)-terrH(x+0.25::DOUBLE,y))/0.5::DOUBLE, (terrH(x,y-0.25::DOUBLE)-terrH(x,y+0.25::DOUBLE))/0.5::DOUBLE, 1.0::DOUBLE));
CREATE OR REPLACE MACRO satb(c) AS mix((c[1]*0.30::DOUBLE+c[2]*0.59::DOUBLE+c[3]*0.11::DOUBLE, c[1]*0.30::DOUBLE+c[2]*0.59::DOUBLE+c[3]*0.11::DOUBLE, c[1]*0.30::DOUBLE+c[2]*0.59::DOUBLE+c[3]*0.11::DOUBLE), c, 1.45::DOUBLE);
CREATE OR REPLACE MACRO terrCol(h) AS
  mix(mix(mix(mix((0.06::DOUBLE,0.24::DOUBLE,0.55::DOUBLE), (0.84::DOUBLE,0.68::DOUBLE,0.32::DOUBLE), clamp3(0.0::DOUBLE,1.0::DOUBLE,(h+0.6::DOUBLE)/0.4::DOUBLE)),
              (0.16::DOUBLE,0.52::DOUBLE,0.09::DOUBLE), clamp3(0.0::DOUBLE,1.0::DOUBLE,(h+0.1::DOUBLE)/0.5::DOUBLE)),
          (0.46::DOUBLE,0.32::DOUBLE,0.22::DOUBLE), clamp3(0.0::DOUBLE,1.0::DOUBLE,(h-0.6::DOUBLE)/0.4::DOUBLE)),
      (0.97::DOUBLE,0.98::DOUBLE,1.0::DOUBLE), clamp3(0.0::DOUBLE,1.0::DOUBLE,(h-1.0::DOUBLE)/0.3::DOUBLE));
-- march the height field; state list (t, prevT, prevDiff, result)
CREATE OR REPLACE MACRO marchTerr(O,D) AS
  list_transform([list_reduce(
       range(terrSteps()),
       (st,jj) -> if(st[4] < 1e8 OR st[4] > 1.5e9, st,
         list_transform([O[3] + st[1]*D[3] - terrH(O[1] + st[1]*D[1], O[2] + st[1]*D[2])], dc ->
            if(st[3] > 0.0::DOUBLE AND dc <= 0.0::DOUBLE, (st[1], st[1], dc, st[2] + (st[1]-st[2])*st[3]/(st[3]-dc)),
               if(O[3] + st[1]*D[3] > maxTerrH() AND D[3] >= 0.0::DOUBLE, (st[1],st[1],dc,2e9),
                  (st[1] + greatest(0.45::DOUBLE, st[1]*0.008::DOUBLE), st[1], dc, 1e9))))[1]),
       (if(D[3] < -0.001::DOUBLE, greatest(0.05::DOUBLE, (O[3] - maxTerrH())/(-D[3])), 0.05::DOUBLE), 0.0::DOUBLE, 1e9, 1e9))],
     rr -> if(rr[4] < 1e8, rr[4], 1e9))[1];
CREATE OR REPLACE MACRO terrShadow(P,dir,maxd) AS
  len(list_filter(range(terrShadowSteps()),
        i -> ((0.3::DOUBLE + i*0.6::DOUBLE) < maxd) AND (P[3] + (0.3::DOUBLE+i*0.6::DOUBLE)*dir[3] < terrH(P[1] + (0.3::DOUBLE+i*0.6::DOUBLE)*dir[1], P[2] + (0.3::DOUBLE+i*0.6::DOUBLE)*dir[2])))) > 0;

COPY (
  WITH
b0 AS MATERIALIZED (
  SELECT idx,
    eye() AS o,
    vn(va(camFwd(), va(vm(camRight(), (((idx % 2560) + 0.5::DOUBLE) / imgW() * 2.0::DOUBLE - 1.0::DOUBLE) * aspect() * tanHalf()),
                       vm(camUp(),    (1.0::DOUBLE - (idx // 2560 + 0.5::DOUBLE) / imgH() * 2.0::DOUBLE) * tanHalf())))) AS d,
    1.0::DOUBLE AS thr, (0.0::DOUBLE,0.0::DOUBLE,0.0::DOUBLE) AS acc, 1.0::DOUBLE AS alive
  FROM (SELECT range AS idx FROM range(2560*1200))
),
b1 AS MATERIALIZED (
  SELECT idx, o2 AS o, d2 AS d, thr2 AS thr, acc2 AS acc, alive2 AS alive FROM (
    SELECT idx, o, d, thr, acc, alive,
        list_transform(cyls(), c -> rodT(o, d, (c[1],c[2],c[3]), (c[4],c[5],c[6]), c[7])) AS cylHits,
        list_transform(sphs(), sp -> sphT(o, d, (sp[1],sp[2],sp[3]), sp[4])) AS sphHits,
        marchTorus(o, d) AS tTorus,
        list_min(cylHits) AS tCyl,
        list_min(sphHits) AS tSph,
        least(tCyl, least(tSph, tTorus)) AS tLet,
        marchTerr(o, d) AS tTerr,
        sphPair(o, d, csgA(), csgAr()) AS pairA,
        sphPair(o, d, csgB(), csgBr()) AS pairB,
        if(pairA[1] > eps() AND pairA[1] < 1e8 AND NOT (pairB[1] <= pairA[1] AND pairA[1] <= pairB[2]), pairA[1], 1e9) AS cEnter,
        if(pairB[1] < 1e8 AND pairB[2] > eps() AND pairA[1] <= pairB[2] AND pairB[2] <= pairA[2], pairB[2], 1e9) AS cCav,
        least(cEnter, cCav) AS tC,
        least(tLet, tC) AS tM,
        least(tM, tTerr) AS tHit,
        va(o, vm(d, tHit)) AS hp,
        cyls()[list_position(cylHits, tCyl)] AS cWin,
        if(tTorus <= tCyl AND tTorus <= tSph, torusN(o, d, tTorus), if(tCyl <= tSph, rodN(o, d, (cWin[1],cWin[2],cWin[3]), (cWin[4],cWin[5],cWin[6]), cWin[7]),    vn(vs(hp, list_transform([sphs()[list_position(sphHits, tSph)]], q -> (q[1],q[2],q[3]))[1])))) AS letN,
        if(tC < tLet, if(cEnter <= cCav, vn(vs(hp, csgA())), vn(vs(csgB(), hp))), letN) AS sn,
        (tM < tTerr) AND (tM < 1e8) AS isMirror,
        (tTerr <= tM) AND (tTerr < 1e8) AS isTerr,
        (tM >= 1e8) AND (tTerr >= 1e8) AS isMiss,
        terrN(hp[1], hp[2]) AS tN,
        if(isTerr, tN, sn) AS nrm,
        va(hp, vm(nrm, 0.02::DOUBLE)) AS shOrig,
        vref(d, sn) AS rdir,
        vn(vs(lightPos(), hp)) AS ldir,
        sqrt(vd(vs(lightPos(), hp), vs(lightPos(), hp))) AS distL,
        occluded(shOrig, ldir, distL - 0.05::DOUBLE) OR terrShadow(shOrig, ldir, distL - 0.05::DOUBLE) AS shadowed,
        pow(greatest(vd(ldir, rdir), 0.0::DOUBLE), shininess()) * if(shadowed, 0.0::DOUBLE, 1.0::DOUBLE) AS spec,
        greatest(vd(ldir, tN), 0.0::DOUBLE) * if(shadowed, 0.0::DOUBLE, 1.0::DOUBLE) AS lambert,
        least(1.0::DOUBLE, greatest(0.0::DOUBLE, (tHit - fogStart()) / fogRange())) AS fog,
        va(vm(satb(vmul(terrCol(hp[3]), va(vm(skyAmb(), 0.26::DOUBLE + 0.18::DOUBLE*greatest(tN[3],0.0::DOUBLE)), vm(sunCol(), 1.45::DOUBLE*lambert)))), 1.0::DOUBLE - fog), vm(hazeColor(), fog)) AS terrShade,
        if(isMirror, shOrig, o) AS o2,
        if(isMirror, rdir, d) AS d2,
        if(isMirror, thr * reflect_k(), thr) AS thr2,
        va(acc, va(if(isMirror, vm(specColor(), thr * spec), (0.0::DOUBLE,0.0::DOUBLE,0.0::DOUBLE)),
                   va(if(isTerr, vm(terrShade, thr), (0.0::DOUBLE,0.0::DOUBLE,0.0::DOUBLE)),
                      if(isMiss, vm(sky(d), thr), (0.0::DOUBLE,0.0::DOUBLE,0.0::DOUBLE))))) AS acc2,
        if(isMirror, 1.0::DOUBLE, 0.0::DOUBLE) AS alive2
    FROM b0 WHERE alive > 0.5::DOUBLE
  )
  UNION ALL
  SELECT idx, o, d, thr, acc, alive FROM b0 WHERE alive <= 0.5::DOUBLE
),
b2 AS MATERIALIZED (
  SELECT idx, o2 AS o, d2 AS d, thr2 AS thr, acc2 AS acc, alive2 AS alive FROM (
    SELECT idx, o, d, thr, acc, alive,
        list_transform(cyls(), c -> rodT(o, d, (c[1],c[2],c[3]), (c[4],c[5],c[6]), c[7])) AS cylHits,
        list_transform(sphs(), sp -> sphT(o, d, (sp[1],sp[2],sp[3]), sp[4])) AS sphHits,
        marchTorus(o, d) AS tTorus,
        list_min(cylHits) AS tCyl,
        list_min(sphHits) AS tSph,
        least(tCyl, least(tSph, tTorus)) AS tLet,
        marchTerr(o, d) AS tTerr,
        sphPair(o, d, csgA(), csgAr()) AS pairA,
        sphPair(o, d, csgB(), csgBr()) AS pairB,
        if(pairA[1] > eps() AND pairA[1] < 1e8 AND NOT (pairB[1] <= pairA[1] AND pairA[1] <= pairB[2]), pairA[1], 1e9) AS cEnter,
        if(pairB[1] < 1e8 AND pairB[2] > eps() AND pairA[1] <= pairB[2] AND pairB[2] <= pairA[2], pairB[2], 1e9) AS cCav,
        least(cEnter, cCav) AS tC,
        least(tLet, tC) AS tM,
        least(tM, tTerr) AS tHit,
        va(o, vm(d, tHit)) AS hp,
        cyls()[list_position(cylHits, tCyl)] AS cWin,
        if(tTorus <= tCyl AND tTorus <= tSph, torusN(o, d, tTorus), if(tCyl <= tSph, rodN(o, d, (cWin[1],cWin[2],cWin[3]), (cWin[4],cWin[5],cWin[6]), cWin[7]),    vn(vs(hp, list_transform([sphs()[list_position(sphHits, tSph)]], q -> (q[1],q[2],q[3]))[1])))) AS letN,
        if(tC < tLet, if(cEnter <= cCav, vn(vs(hp, csgA())), vn(vs(csgB(), hp))), letN) AS sn,
        (tM < tTerr) AND (tM < 1e8) AS isMirror,
        (tTerr <= tM) AND (tTerr < 1e8) AS isTerr,
        (tM >= 1e8) AND (tTerr >= 1e8) AS isMiss,
        terrN(hp[1], hp[2]) AS tN,
        if(isTerr, tN, sn) AS nrm,
        va(hp, vm(nrm, 0.02::DOUBLE)) AS shOrig,
        vref(d, sn) AS rdir,
        vn(vs(lightPos(), hp)) AS ldir,
        sqrt(vd(vs(lightPos(), hp), vs(lightPos(), hp))) AS distL,
        occluded(shOrig, ldir, distL - 0.05::DOUBLE) OR terrShadow(shOrig, ldir, distL - 0.05::DOUBLE) AS shadowed,
        pow(greatest(vd(ldir, rdir), 0.0::DOUBLE), shininess()) * if(shadowed, 0.0::DOUBLE, 1.0::DOUBLE) AS spec,
        greatest(vd(ldir, tN), 0.0::DOUBLE) * if(shadowed, 0.0::DOUBLE, 1.0::DOUBLE) AS lambert,
        least(1.0::DOUBLE, greatest(0.0::DOUBLE, (tHit - fogStart()) / fogRange())) AS fog,
        va(vm(satb(vmul(terrCol(hp[3]), va(vm(skyAmb(), 0.26::DOUBLE + 0.18::DOUBLE*greatest(tN[3],0.0::DOUBLE)), vm(sunCol(), 1.45::DOUBLE*lambert)))), 1.0::DOUBLE - fog), vm(hazeColor(), fog)) AS terrShade,
        if(isMirror, shOrig, o) AS o2,
        if(isMirror, rdir, d) AS d2,
        if(isMirror, thr * reflect_k(), thr) AS thr2,
        va(acc, va(if(isMirror, vm(specColor(), thr * spec), (0.0::DOUBLE,0.0::DOUBLE,0.0::DOUBLE)),
                   va(if(isTerr, vm(terrShade, thr), (0.0::DOUBLE,0.0::DOUBLE,0.0::DOUBLE)),
                      if(isMiss, vm(sky(d), thr), (0.0::DOUBLE,0.0::DOUBLE,0.0::DOUBLE))))) AS acc2,
        if(isMirror, 1.0::DOUBLE, 0.0::DOUBLE) AS alive2
    FROM b1 WHERE alive > 0.5::DOUBLE
  )
  UNION ALL
  SELECT idx, o, d, thr, acc, alive FROM b1 WHERE alive <= 0.5::DOUBLE
)
  SELECT idx,
    CAST(round(clamp3(0.0::DOUBLE,1.0::DOUBLE, pow(greatest(col[1],0.0::DOUBLE)*exposure(), 1.0::DOUBLE/gamma_()))*255) AS INTEGER) AS r,
    CAST(round(clamp3(0.0::DOUBLE,1.0::DOUBLE, pow(greatest(col[2],0.0::DOUBLE)*exposure(), 1.0::DOUBLE/gamma_()))*255) AS INTEGER) AS g,
    CAST(round(clamp3(0.0::DOUBLE,1.0::DOUBLE, pow(greatest(col[3],0.0::DOUBLE)*exposure(), 1.0::DOUBLE/gamma_()))*255) AS INTEGER) AS b
  FROM (SELECT idx, va(acc, if(alive > 0.5::DOUBLE, vm(sky(d), thr), (0.0::DOUBLE,0.0::DOUBLE,0.0::DOUBLE))) AS col FROM b2)
  ORDER BY idx
) TO '/dev/stdout' (FORMAT csv, DELIMITER E'\t', HEADER false);
