-- ====================================================================
-- ClickHouse-over-terrain benchmark, Umbra Datalog port  (2560x1200, depth 2)
--   terrain + analytic letters + tori march + planet + shadows + bounces
-- ====================================================================
-- the scalar helpers
CREATE OR REPLACE FUNCTION mixS(a double precision, b double precision, t double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT a + (b - a) * t';
CREATE OR REPLACE FUNCTION lerpS(a double precision, b double precision, t double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT a * (1.0 - t) + b * t';
CREATE OR REPLACE FUNCTION clamp01(x double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT greatest(0.0, least(1.0, x))';
CREATE OR REPLACE FUNCTION lt01(x double precision, y double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT CASE WHEN x < y THEN 1.0::double precision ELSE 0.0::double precision END';
CREATE OR REPLACE FUNCTION le01(x double precision, y double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT CASE WHEN x <= y THEN 1.0::double precision ELSE 0.0::double precision END';
CREATE OR REPLACE FUNCTION eq01(x double precision, y double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT CASE WHEN x = y THEN 1.0::double precision ELSE 0.0::double precision END';
CREATE OR REPLACE FUNCTION camU(g bigint) RETURNS double precision LANGUAGE sql AS
  'SELECT (((g % 2560)::double precision + 0.5) / 2560.0::double precision * 2.0 - 1.0) * (2560.0::double precision / 1200.0::double precision) * tan(36.0::double precision * 0.5 * pi() / 180.0)';
CREATE OR REPLACE FUNCTION camV(g bigint) RETURNS double precision LANGUAGE sql AS
  'SELECT (1.0 - ((g / 2560)::double precision + 0.5) / 1200.0::double precision * 2.0) * tan(36.0::double precision * 0.5 * pi() / 180.0)';
CREATE OR REPLACE FUNCTION tonemap(c double precision) RETURNS bigint LANGUAGE sql AS
  'SELECT round(clamp01(power(greatest(c, 0.0) * 1.15::double precision, 1.0::double precision / 2.2::double precision)) * 255.0::double precision)::bigint';
CREATE OR REPLACE FUNCTION hashf(ix bigint, iy bigint) RETURNS double precision LANGUAGE sql AS
  'SELECT ((((((ix + 4096) + (iy + 4096) * 8192) * 1103515245 + 12345) % 2147483648) * 1103515245 + 12345) % 2147483648 % 65536)::double precision / 65536.0';
CREATE OR REPLACE FUNCTION fade(t double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT t * t * t * (t * (t * 6.0 - 15.0) + 10.0)';
CREATE OR REPLACE FUNCTION vnoise3(ix bigint, iy bigint, tx double precision, ty double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT lerpS(lerpS(hashf(ix, iy), hashf(ix + 1, iy), tx), lerpS(hashf(ix, iy + 1), hashf(ix + 1, iy + 1), tx), ty)';
CREATE OR REPLACE FUNCTION vnoise2(x double precision, y double precision, fx double precision, fy double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT vnoise3(fx::bigint, fy::bigint, fade(x - fx), fade(y - fy))';
CREATE OR REPLACE FUNCTION vnoise(x double precision, y double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT vnoise2(x, y, floor(x), floor(y))';
CREATE OR REPLACE FUNCTION fbm(x double precision, y double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT (vnoise(x, y) * 0.5 + vnoise(x * 2.0, y * 2.0) * 0.25 + vnoise(x * 4.0, y * 4.0) * 0.125 + vnoise(x * 8.0, y * 8.0) * 0.0625) / 0.9375';
CREATE OR REPLACE FUNCTION terrH(x double precision, y double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT 2.4 * (fbm(x * 0.05, y * 0.05) - 0.5)';
CREATE OR REPLACE FUNCTION terrGx(x double precision, y double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT (terrH(x - 0.25, y) - terrH(x + 0.25, y)) / 0.5';
CREATE OR REPLACE FUNCTION terrGy(x double precision, y double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT (terrH(x, y - 0.25) - terrH(x, y + 0.25)) / 0.5';
CREATE OR REPLACE FUNCTION terrColC(h double precision, c0 double precision, c1 double precision, c2 double precision, c3 double precision, c4 double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT mixS(mixS(mixS(mixS(c0, c1, clamp01((h + 0.6) / 0.4)), c2, clamp01((h + 0.1) / 0.5)), c3, clamp01((h - 0.6) / 0.4)), c4, clamp01((h - 1.0) / 0.3))';
CREATE OR REPLACE FUNCTION terrColx(h double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT terrColC(h, 0.06, 0.84, 0.16, 0.46, 0.97)';
CREATE OR REPLACE FUNCTION terrColy(h double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT terrColC(h, 0.24, 0.68, 0.52, 0.32, 0.98)';
CREATE OR REPLACE FUNCTION terrColz(h double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT terrColC(h, 0.55, 0.32, 0.09, 0.22, 1.0)';
CREATE OR REPLACE FUNCTION satbC(r double precision, g double precision, b double precision, c double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT mixS(r * 0.3 + g * 0.59 + b * 0.11, c, 1.45)';
CREATE OR REPLACE FUNCTION skyx(dz double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT mixS(0.66, 0.3, greatest(0.0, least(1.0, dz * 1.5)))';
CREATE OR REPLACE FUNCTION skyy(dz double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT mixS(0.78, 0.5, greatest(0.0, least(1.0, dz * 1.5)))';
CREATE OR REPLACE FUNCTION skyz(dz double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT mixS(0.96, 0.85, greatest(0.0, least(1.0, dz * 1.5)))';
CREATE OR REPLACE FUNCTION tsdf5(ring double precision, py double precision, rr double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT sqrt(ring * ring + py * py) - rr';
CREATE OR REPLACE FUNCTION tsdf4(qx double precision, qz double precision, py double precision, r double precision, rr double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT tsdf5(sqrt(qx * qx + qz * qz) - r, py, rr)';
CREATE OR REPLACE FUNCTION tsdf3(px double precision, py double precision, pz double precision, cx double precision, cz double precision, r double precision, rr double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT tsdf4(px - cx, pz - cz, py, r, rr)';
CREATE OR REPLACE FUNCTION bsdf4(ax double precision, ay double precision, az double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT sqrt(greatest(ax, 0.0) * greatest(ax, 0.0) + greatest(ay, 0.0) * greatest(ay, 0.0) + greatest(az, 0.0) * greatest(az, 0.0)) + least(greatest(ax, greatest(ay, az)), 0.0)';
CREATE OR REPLACE FUNCTION bsdf3(px double precision, py double precision, pz double precision, cx double precision, cy double precision, cz double precision, hx double precision, hy double precision, hz double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT bsdf4(abs(px - cx) - hx, abs(py - cy) - hy, abs(pz - cz) - hz)';
CREATE OR REPLACE FUNCTION toriSDF(px double precision, py double precision, pz double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT least(greatest(tsdf3(px, py, pz, 1.3, 5.4, 2.28, 0.62), -bsdf3(px, py, pz, 4.425, 0.0, 5.4, 3.025, 100.0, 1.5)),
    least(greatest(tsdf3(px, py, pz, 12.95, 4.5, 1.425, 0.575), -bsdf3(px, py, pz, 16.45, 0.0, 4.5, 3.4, 100.0, 0.94)),
    least(greatest(tsdf3(px, py, pz, 30.4, 4.5, 1.475, 0.525), -bsdf3(px, py, pz, 1000000.0, 0.0, 1000000.0, 0.1, 0.1, 0.1)),
    least(greatest(tsdf3(px, py, pz, 36.27, 4.0, 1.45, 0.62), -bsdf3(px, py, pz, 33.95, 0.0, 7.75, 9.0, 100.0, 3.75)),
    least(greatest(tsdf3(px, py, pz, 41.9, 6.0, 1.025, 0.425), -bsdf3(px, py, pz, 45.375, 0.0, -0.25, 3.475, 100.0, 6.25)),
    least(greatest(tsdf3(px, py, pz, 41.9, 3.9, 1.025, 0.425), -bsdf3(px, py, pz, 36.375, 0.0, 7.7, 5.525, 100.0, 3.8)),
    greatest(tsdf3(px, py, pz, 47.25, 4.55, 1.585, 0.465), -bsdf3(px, py, pz, 50.8, 0.0, 3.87, 3.25, 100.0, 0.32))))))))';
CREATE OR REPLACE FUNCTION toriAt(ox double precision, oy double precision, oz double precision, dx double precision, dy double precision, dz double precision, t double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT toriSDF(ox + dx * t, oy + dy * t, oz + dz * t)';
CREATE OR REPLACE FUNCTION toriGx(a double precision, b double precision, c double precision, d double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT (a - b) + (d - c)';
CREATE OR REPLACE FUNCTION toriGy(a double precision, b double precision, c double precision, d double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT (-a - b) + (c + d)';
CREATE OR REPLACE FUNCTION toriGz(a double precision, b double precision, c double precision, d double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT (b - a) + (d - c)';
CREATE OR REPLACE FUNCTION torusT(ox double precision, oy double precision, oz double precision, dx double precision, dy double precision, dz double precision, t double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT CASE WHEN toriAt(ox, oy, oz, dx, dy, dz, t) < 0.01 AND t > 0.002 AND t < 260.0 THEN t ELSE 1e9 END';
CREATE OR REPLACE FUNCTION sphT2(bb double precision, cc double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT CASE WHEN bb * bb - cc > 0.0 AND -bb - sqrt(greatest(bb * bb - cc, 0.0)) > 0.002 THEN -bb - sqrt(greatest(bb * bb - cc, 0.0)) ELSE 1e9 END';
CREATE OR REPLACE FUNCTION sphT1(ocx double precision, ocy double precision, ocz double precision, dx double precision, dy double precision, dz double precision, rr double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT sphT2(ocx * dx + ocy * dy + ocz * dz, ocx * ocx + ocy * ocy + ocz * ocz - rr)';
CREATE OR REPLACE FUNCTION sphT(ox double precision, oy double precision, oz double precision, dx double precision, dy double precision, dz double precision, cx double precision, cy double precision, cz double precision, rr double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT sphT1(ox - cx, oy - cy, oz - cz, dx, dy, dz, rr)';
CREATE OR REPLACE FUNCTION sphNF2(bq double precision, disc double precision, s double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT CASE WHEN disc > 0.0 THEN -bq + s * sqrt(disc) ELSE -s * 1e9 END';
CREATE OR REPLACE FUNCTION sphNF1(ocx double precision, ocy double precision, ocz double precision, dx double precision, dy double precision, dz double precision, rr double precision, s double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT sphNF2(ocx * dx + ocy * dy + ocz * dz, (ocx * dx + ocy * dy + ocz * dz) * (ocx * dx + ocy * dy + ocz * dz) - (ocx * ocx + ocy * ocy + ocz * ocz - rr), s)';
CREATE OR REPLACE FUNCTION sphNear(ox double precision, oy double precision, oz double precision, dx double precision, dy double precision, dz double precision, cx double precision, cy double precision, cz double precision, rr double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT sphNF1(ox - cx, oy - cy, oz - cz, dx, dy, dz, rr, -1.0)';
CREATE OR REPLACE FUNCTION sphFar(ox double precision, oy double precision, oz double precision, dx double precision, dy double precision, dz double precision, cx double precision, cy double precision, cz double precision, rr double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT sphNF1(ox - cx, oy - cy, oz - cz, dx, dy, dz, rr, 1.0)';
CREATE OR REPLACE FUNCTION planetEntry(an double precision, bn double precision, bf double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT CASE WHEN an > 0.002 AND an < 1e8 AND NOT (bn <= an AND an <= bf) THEN an ELSE 1e9 END';
CREATE OR REPLACE FUNCTION planetCavity(an double precision, af double precision, bn double precision, bf double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT CASE WHEN bn < 1e8 AND bf > 0.002 AND an <= bf AND bf <= af THEN bf ELSE 1e9 END';
CREATE OR REPLACE FUNCTION cylBody3(tb double precision, hh double precision, aa double precision, baba double precision, bard double precision, baoa double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT CASE WHEN hh >= 0.0 AND aa > 1e-9 AND tb > 0.002 AND baoa + tb * bard > 0.0 AND baoa + tb * bard < baba THEN tb ELSE 1e9 END';
CREATE OR REPLACE FUNCTION cylBody2(aa double precision, bb double precision, cc double precision, baba double precision, bard double precision, baoa double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT cylBody3((-bb - sqrt(greatest(bb * bb - aa * cc, 0.0))) / aa, bb * bb - aa * cc, aa, baba, bard, baoa)';
CREATE OR REPLACE FUNCTION cylBody1(baba double precision, bard double precision, baoa double precision, doa double precision, oaoa double precision, r double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT cylBody2(baba - bard * bard, baba * doa - baoa * bard, baba * oaoa - baoa * baoa - r * r * baba, baba, bard, baoa)';
CREATE OR REPLACE FUNCTION cylBodyV(bax double precision, bay double precision, baz double precision, oax double precision, oay double precision, oaz double precision, dx double precision, dy double precision, dz double precision, r double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT cylBody1(bax * bax + bay * bay + baz * baz, bax * dx + bay * dy + baz * dz, bax * oax + bay * oay + baz * oaz, dx * oax + dy * oay + dz * oaz, oax * oax + oay * oay + oaz * oaz, r)';
CREATE OR REPLACE FUNCTION cylBody(ox double precision, oy double precision, oz double precision, dx double precision, dy double precision, dz double precision, ax double precision, ay double precision, az double precision, bx double precision, by double precision, bz double precision, r double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT cylBodyV(bx - ax, by - ay, bz - az, ox - ax, oy - ay, oz - az, dx, dy, dz, r)';
CREATE OR REPLACE FUNCTION cylCap3(den double precision, ta double precision, qx double precision, qy double precision, qz double precision, r double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT CASE WHEN abs(den) > 1e-9 AND ta > 0.002 AND qx * qx + qy * qy + qz * qz <= r * r THEN ta ELSE 1e9 END';
CREATE OR REPLACE FUNCTION cylCap2(ox double precision, oy double precision, oz double precision, dx double precision, dy double precision, dz double precision, cx double precision, cy double precision, cz double precision, r double precision, den double precision, ta double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT cylCap3(den, ta, ox + dx * ta - cx, oy + dy * ta - cy, oz + dz * ta - cz, r)';
CREATE OR REPLACE FUNCTION cylCap1(ox double precision, oy double precision, oz double precision, dx double precision, dy double precision, dz double precision, cx double precision, cy double precision, cz double precision, r double precision, den double precision, num double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT cylCap2(ox, oy, oz, dx, dy, dz, cx, cy, cz, r, den, num / CASE WHEN abs(den) < 1e-12 THEN 1e-12 ELSE den END)';
CREATE OR REPLACE FUNCTION cylCapV(ox double precision, oy double precision, oz double precision, dx double precision, dy double precision, dz double precision, bax double precision, bay double precision, baz double precision, cx double precision, cy double precision, cz double precision, r double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT cylCap1(ox, oy, oz, dx, dy, dz, cx, cy, cz, r, bax * dx + bay * dy + baz * dz, bax * (cx - ox) + bay * (cy - oy) + baz * (cz - oz))';
CREATE OR REPLACE FUNCTION cylCap(ox double precision, oy double precision, oz double precision, dx double precision, dy double precision, dz double precision, ax double precision, ay double precision, az double precision, bx double precision, by double precision, bz double precision, cx double precision, cy double precision, cz double precision, r double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT cylCapV(ox, oy, oz, dx, dy, dz, bx - ax, by - ay, bz - az, cx, cy, cz, r)';
CREATE OR REPLACE FUNCTION cylT(ox double precision, oy double precision, oz double precision, dx double precision, dy double precision, dz double precision, ax double precision, ay double precision, az double precision, bx double precision, by double precision, bz double precision, r double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT least(cylBody(ox, oy, oz, dx, dy, dz, ax, ay, az, bx, by, bz, r), least(cylCap(ox, oy, oz, dx, dy, dz, ax, ay, az, bx, by, bz, ax, ay, az, r), cylCap(ox, oy, oz, dx, dy, dz, ax, ay, az, bx, by, bz, bx, by, bz, r)))';

SET debug.datalog.use64bit = on;
COPY (
SELECT * FROM umbra.datalog($DATALOG$
.decl cyl(id: number, ax: float8, ay: float8, az: float8, bx: float8, by: float8, bz: float8, r: float8)
.decl step(s: float8)
.decl done(i: number, accx: float8, accy: float8, accz: float8)
.decl rays_b1(i: number, ox: float8, oy: float8, oz: float8, dx: float8, dy: float8, dz: float8, thr: float8, accx: float8, accy: float8, accz: float8)
.decl rod_b1(i: number, ox: float8, oy: float8, oz: float8, dx: float8, dy: float8, dz: float8)
.decl march_b1(i: number, t: float8, prevt: float8, prevdiff: float8, it: number)
.decl marcheval_b1(i: number, t: float8, prevt: float8, prevdiff: float8, it: number, dc: float8)
.decl terr_b1_hit(i: number, t: float8)
.decl terr_b1(i: number, t: float8)
.decl tmar_b1(i: number, t: float8, it: number)
.decl torus_b1(i: number, t: float8, x: float8, y: float8, z: float8)
.decl cyl_b1(i: number, id: number, tb: float8, ta: float8, t: float8)
.decl cylmin_b1(i: number, t: float8)
.decl cylpick_b1(i: number, id: number)
.decl cyln_b1(i: number, x: float8, y: float8, z: float8)
.decl sph_b1(i: number, t: float8)
.decl planet_b1(i: number, t: float8, x: float8, y: float8, z: float8)
.decl comb_b1(i: number, kind: number, thit: float8, hpx: float8, hpy: float8, hpz: float8, tnx: float8, tny: float8, tnz: float8, rdx: float8, rdy: float8, rdz: float8, ldx: float8, ldy: float8, ldz: float8, distl: float8, sox: float8, soy: float8, soz: float8, ismirror: float8)
.decl srod_b1(i: number, ox: float8, oy: float8, oz: float8, dx: float8, dy: float8, dz: float8, distl: float8)
.decl shadow_b1(i: number)
.decl srays_b1(i: number, ox: float8, oy: float8, oz: float8, dx: float8, dy: float8, dz: float8)
.decl stmar_b1(i: number, t: float8, it: number)
.decl lit_b1(i: number, lit: float8)
.decl rays_b2(i: number, ox: float8, oy: float8, oz: float8, dx: float8, dy: float8, dz: float8, thr: float8, accx: float8, accy: float8, accz: float8)
.decl rod_b2(i: number, ox: float8, oy: float8, oz: float8, dx: float8, dy: float8, dz: float8)
.decl march_b2(i: number, t: float8, prevt: float8, prevdiff: float8, it: number)
.decl marcheval_b2(i: number, t: float8, prevt: float8, prevdiff: float8, it: number, dc: float8)
.decl terr_b2_hit(i: number, t: float8)
.decl terr_b2(i: number, t: float8)
.decl tmar_b2(i: number, t: float8, it: number)
.decl torus_b2(i: number, t: float8, x: float8, y: float8, z: float8)
.decl cyl_b2(i: number, id: number, tb: float8, ta: float8, t: float8)
.decl cylmin_b2(i: number, t: float8)
.decl cylpick_b2(i: number, id: number)
.decl cyln_b2(i: number, x: float8, y: float8, z: float8)
.decl sph_b2(i: number, t: float8)
.decl planet_b2(i: number, t: float8, x: float8, y: float8, z: float8)
.decl comb_b2(i: number, kind: number, thit: float8, hpx: float8, hpy: float8, hpz: float8, tnx: float8, tny: float8, tnz: float8, rdx: float8, rdy: float8, rdz: float8, ldx: float8, ldy: float8, ldz: float8, distl: float8, sox: float8, soy: float8, soz: float8, ismirror: float8)
.decl srod_b2(i: number, ox: float8, oy: float8, oz: float8, dx: float8, dy: float8, dz: float8, distl: float8)
.decl shadow_b2(i: number)
.decl srays_b2(i: number, ox: float8, oy: float8, oz: float8, dx: float8, dy: float8, dz: float8)
.decl stmar_b2(i: number, t: float8, it: number)
.decl lit_b2(i: number, lit: float8)
.decl rays_b3(i: number, ox: float8, oy: float8, oz: float8, dx: float8, dy: float8, dz: float8, thr: float8, accx: float8, accy: float8, accz: float8)
.decl pixel(i: number, r: number, g: number, b: number)

cyl(0, 5.75, 0.0, 2.5, 5.75, 0.0, 9.5, 0.62).
cyl(1, 8.65, 0.0, 2.5, 8.65, 0.0, 7.5, 0.62).
cyl(2, 16.8, 0.0, 2.5, 16.8, 0.0, 9.5, 0.62).
cyl(3, 17.15, 0.0, 5.0, 20.05, 0.0, 7.6, 0.62).
cyl(4, 17.35, 0.0, 5.1, 20.05, 0.0, 2.5, 0.62).
cyl(5, 22.4, 0.0, 2.5, 22.4, 0.0, 9.5, 0.62).
cyl(6, 26.15, 0.0, 2.5, 26.15, 0.0, 9.5, 0.62).
cyl(7, 22.35, 0.0, 6.0, 26.15, 0.0, 6.0, 0.62).
cyl(8, 34.82, 0.0, 3.5, 34.82, 0.0, 7.5, 0.62).
cyl(9, 37.72, 0.0, 3.5, 37.72, 0.0, 7.5, 0.62).
cyl(10, 45.35, 0.0, 4.6, 48.85, 0.0, 4.6, 0.41333333).
step(0.3).
step(0.8999999999999999).
step(1.5).
step(2.0999999999999996).
step(2.6999999999999997).
step(3.3).
step(3.8999999999999995).
step(4.5).
step(5.1).
step(5.699999999999999).
step(6.3).
step(6.8999999999999995).
step(7.499999999999999).
step(8.1).
step(8.700000000000001).
step(9.3).
step(9.9).
step(10.5).
step(11.1).
step(11.700000000000001).
step(12.3).
step(12.9).
step(13.5).
step(14.1).

rays_b1(I, 24.0, -45.0, 12.0, (V31 * V35), (V32 * V35), (V33 * V35), 1.0, 0.0, 0.0, 0.0) :-
    I = range(0, 3072000),
    V1 = 24.0 - 24.0,
    V2 = 0.0 - -45.0,
    V3 = 6.0 - 12.0,
    V5 = 1.0 / @sqrt(max((V1 * V1 + V2 * V2 + V3 * V3), 1e-18)),
    V6 = V1 * V5,
    V7 = V2 * V5,
    V8 = V3 * V5,
    V9 = V7 * 1.0 - V8 * 0.0,
    V10 = V8 * 0.0 - V6 * 1.0,
    V11 = V6 * 0.0 - V7 * 0.0,
    V13 = 1.0 / @sqrt(max((V9 * V9 + V10 * V10 + V11 * V11), 1e-18)),
    V14 = V9 * V13,
    V15 = V10 * V13,
    V16 = V11 * V13,
    V20 = @camu(I),
    V24 = @camv(I),
    V31 = V6 + ((V14 * V20) + ((V15 * V8 - V16 * V7) * V24)),
    V32 = V7 + ((V15 * V20) + ((V16 * V6 - V14 * V8) * V24)),
    V33 = V8 + ((V16 * V20) + ((V14 * V7 - V15 * V6) * V24)),
    V35 = 1.0 / @sqrt(max((V31 * V31 + V32 * V32 + V33 * V33), 1e-18)).

rod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz) :- rays_b1(I, Ox, Oy, Oz, Dx, Dy, Dz, Thr, Accx, Accy, Accz).

march_b1(I, max(0.05, (Oz - 1.55) / (-Dz)), 0.0, 1e9, 0) :- rod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz), Dz < -0.001.

march_b1(I, 0.05, 0.0, 1e9, 0) :- rod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz), !(Dz < -0.001).

marcheval_b1(I, T, PT, PD, It, Oz + T * Dz - @terrh(Ox + T * Dx, Oy + T * Dy)) :-
    march_b1(I, T, PT, PD, It), It < 110, rod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz).

terr_b1_hit(I, PT + (T - PT) * PD / (PD - DC)) :- marcheval_b1(I, T, PT, PD, It, DC), PD > 0.0, DC <= 0.0.

march_b1(I, T + max(0.45, T * 0.008), T, DC, It + 1) :-
    marcheval_b1(I, T, PT, PD, It, DC), rod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz), !(PD > 0.0, DC <= 0.0), !(Oz + T * Dz > 1.55, Dz >= 0.0).

terr_b1(I, T) :- terr_b1_hit(I, T).

terr_b1(I, 1e9) :- rod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz), !terr_b1_hit(I, _).

tmar_b1(I, 0.02, 0) :- rod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz).

tmar_b1(I, T + @toriat(Ox, Oy, Oz, Dx, Dy, Dz, T), It + 1) :- tmar_b1(I, T, It), It < 48, rod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz).

torus_b1(I, V39, (V51 * V55), (V52 * V55), (V53 * V55)) :-
    tmar_b1(I, T, 48),
    rod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz),
    V39 = @torust(Ox, Oy, Oz, Dx, Dy, Dz, T),
    V40 = min(V39, 5000.0),
    V44 = Ox + (Dx * V40),
    V45 = Oy + (Dy * V40),
    V46 = Oz + (Dz * V40),
    V47 = @torisdf(V44 + 0.0009, V45 - 0.0009, V46 - 0.0009),
    V48 = @torisdf(V44 - 0.0009, V45 - 0.0009, V46 + 0.0009),
    V49 = @torisdf(V44 - 0.0009, V45 + 0.0009, V46 - 0.0009),
    V50 = @torisdf(V44 + 0.0009, V45 + 0.0009, V46 + 0.0009),
    V51 = @torigx(V47, V48, V49, V50),
    V52 = @torigy(V47, V48, V49, V50),
    V53 = @torigz(V47, V48, V49, V50),
    V55 = 1.0 / @sqrt(max((V51 * V51 + V52 * V52 + V53 * V53), 1e-18)).

cyl_b1(I, Id, V59, V60, min(V59, min(V60, @cylcap(Ox, Oy, Oz, Dx, Dy, Dz, Ax, Ay, Az, Bx, By, Bz, Bx, By, Bz, R)))) :-
    rod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz),
    cyl(Id, Ax, Ay, Az, Bx, By, Bz, R),
    V59 = @cylbody(Ox, Oy, Oz, Dx, Dy, Dz, Ax, Ay, Az, Bx, By, Bz, R),
    V60 = @cylcap(Ox, Oy, Oz, Dx, Dy, Dz, Ax, Ay, Az, Bx, By, Bz, Ax, Ay, Az, R).

cylmin_b1(I, T) :- rod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz), T = min X : { cyl_b1(I, _, _, _, X) }.

cylpick_b1(I, Id) :- cylmin_b1(I, T), Id = min K : { cyl_b1(I, K, _, _, T) }.

cyln_b1(I, (((((V68 * V72) * (1.0 - @eq01(T, TA))) + ((V76 * V80) * @eq01(T, TA))) * (1.0 - V113)) + ((V105 * V109) * V113)), (((((V69 * V72) * (1.0 - @eq01(T, TA))) + ((V77 * V80) * @eq01(T, TA))) * (1.0 - V113)) + ((V106 * V109) * V113)), (((((V70 * V72) * (1.0 - @eq01(T, TA))) + ((V78 * V80) * @eq01(T, TA))) * (1.0 - V113)) + ((V107 * V109) * V113))) :-
    cylpick_b1(I, Id),
    cylmin_b1(I, T),
    rod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz),
    cyl(Id, Ax, Ay, Az, Bx, By, Bz, R),
    cyl_b1(I, Id, TB, TA, _),
    V65 = Ox + (Dx * T),
    V66 = Oy + (Dy * T),
    V67 = Oz + (Dz * T),
    V68 = Bx - Ax,
    V69 = By - Ay,
    V70 = Bz - Az,
    V72 = 1.0 / @sqrt(max((V68 * V68 + V69 * V69 + V70 * V70), 1e-18)),
    V76 = V68 * -1.0,
    V77 = V69 * -1.0,
    V78 = V70 * -1.0,
    V80 = 1.0 / @sqrt(max((V76 * V76 + V77 * V77 + V78 * V78), 1e-18)),
    V98 = ((V65 - Ax) * V68 + (V66 - Ay) * V69 + (V67 - Az) * V70) / (V68 * V68 + V69 * V69 + V70 * V70),
    V105 = V65 - (Ax + (V68 * V98)),
    V106 = V66 - (Ay + (V69 * V98)),
    V107 = V67 - (Az + (V70 * V98)),
    V109 = 1.0 / @sqrt(max((V105 * V105 + V106 * V106 + V107 * V107), 1e-18)),
    V113 = @eq01(T, TB).

sph_b1(I, @spht(Ox, Oy, Oz, Dx, Dy, Dz, 8.65, 0.0, 8.8, 0.5184)) :- rod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz).

planet_b1(I, V129, (((V136 * V140) * (1.0 - V152)) + ((V144 * V148) * V152)), (((V137 * V140) * (1.0 - V152)) + ((V145 * V148) * V152)), (((V138 * V140) * (1.0 - V152)) + ((V146 * V148) * V152))) :-
    rod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz),
    V123 = @sphnear(Ox, Oy, Oz, Dx, Dy, Dz, 24.0, 12.0, 17.5, 36.0),
    V125 = @sphnear(Ox, Oy, Oz, Dx, Dy, Dz, 24.0, 6.6, 17.0, 19.36),
    V126 = @sphfar(Ox, Oy, Oz, Dx, Dy, Dz, 24.0, 6.6, 17.0, 19.36),
    V127 = @planetentry(V123, V125, V126),
    V128 = @planetcavity(V123, @sphfar(Ox, Oy, Oz, Dx, Dy, Dz, 24.0, 12.0, 17.5, 36.0), V125, V126),
    V129 = min(V127, V128),
    V133 = Ox + (Dx * V129),
    V134 = Oy + (Dy * V129),
    V135 = Oz + (Dz * V129),
    V136 = 24.0 - V133,
    V137 = 6.6 - V134,
    V138 = 17.0 - V135,
    V140 = 1.0 / @sqrt(max((V136 * V136 + V137 * V137 + V138 * V138), 1e-18)),
    V144 = V133 - 24.0,
    V145 = V134 - 12.0,
    V146 = V135 - 17.5,
    V148 = 1.0 / @sqrt(max((V144 * V144 + V145 * V145 + V146 * V146), 1e-18)),
    V152 = @le01(V127, V128).

comb_b1(I, (as(V172, number) + 2 * as(V173, number)), V164, V169, V170, V171, V222, V223, V224, (Dx - (V215 * V226)), (Dy - (V216 * V226)), (Dz - (V217 * V226)), (V233 * V237), (V234 * V237), (V235 * V237), @sqrt((V233 * V233 + V234 * V234 + V235 * V235)), (V169 + (((V215 * (1.0 - V173)) + (V222 * V173)) * 0.02)), (V170 + (((V216 * (1.0 - V173)) + (V223 * V173)) * 0.02)), (V171 + (((V217 * (1.0 - V173)) + (V224 * V173)) * 0.02)), V172) :-
    rays_b1(I, Ox, Oy, Oz, Dx, Dy, Dz, Thr, Accx, Accy, Accz),
    terr_b1(I, TTerr),
    torus_b1(I, TTor, NTx, NTy, NTz),
    cylmin_b1(I, TCyl),
    cyln_b1(I, NCx, NCy, NCz),
    sph_b1(I, TSph),
    planet_b1(I, TC, NPx, NPy, NPz),
    V162 = min(TCyl, min(TSph, TTor)),
    V163 = min(V162, TC),
    V164 = min(V163, TTerr),
    V165 = min(V164, 5000.0),
    V169 = Ox + (Dx * V165),
    V170 = Oy + (Dy * V165),
    V171 = Oz + (Dz * V165),
    V172 = @lt01(V163, TTerr) * @lt01(V163, 1e8),
    V173 = @le01(TTerr, V163) * @lt01(TTerr, 1e8),
    V181 = (Ox + (Dx * TSph)) - 8.65,
    V182 = (Oy + (Dy * TSph)) - 0.0,
    V183 = (Oz + (Dz * TSph)) - 8.8,
    V185 = 1.0 / @sqrt(max((V181 * V181 + V182 * V182 + V183 * V183), 1e-18)),
    V198 = @le01(TTor, TCyl) * @le01(TTor, TSph),
    V208 = @lt01(TC, V162),
    V215 = ((((((V181 * V185) * (1.0 - @le01(TCyl, TSph))) + (NCx * @le01(TCyl, TSph))) * (1.0 - V198)) + (NTx * V198)) * (1.0 - V208)) + (NPx * V208),
    V216 = ((((((V182 * V185) * (1.0 - @le01(TCyl, TSph))) + (NCy * @le01(TCyl, TSph))) * (1.0 - V198)) + (NTy * V198)) * (1.0 - V208)) + (NPy * V208),
    V217 = ((((((V183 * V185) * (1.0 - @le01(TCyl, TSph))) + (NCz * @le01(TCyl, TSph))) * (1.0 - V198)) + (NTz * V198)) * (1.0 - V208)) + (NPz * V208),
    V218 = @terrgx(V169, V170),
    V219 = @terrgy(V169, V170),
    V221 = 1.0 / @sqrt(max((V218 * V218 + V219 * V219 + 1.0 * 1.0), 1e-18)),
    V222 = V218 * V221,
    V223 = V219 * V221,
    V224 = 1.0 * V221,
    V226 = 2.0 * (Dx * V215 + Dy * V216 + Dz * V217),
    V233 = 9.0 - V169,
    V234 = -30.0 - V170,
    V235 = 52.0 - V171,
    V237 = 1.0 / @sqrt(max((V233 * V233 + V234 * V234 + V235 * V235), 1e-18)).

srod_b1(I, SOx, SOy, SOz, LDx, LDy, LDz, DistL) :- comb_b1(I, Kind, THit, HPx, HPy, HPz, TNx, TNy, TNz, RDx, RDy, RDz, LDx, LDy, LDz, DistL, SOx, SOy, SOz, IsMirror), Kind > 0.

shadow_b1(I) :- srod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz, DistL), step(S), S < DistL - 0.05, Oz + S * Dz < @terrh(Ox + S * Dx, Oy + S * Dy).

shadow_b1(I) :- srod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz, DistL), cyl(Id, Ax, Ay, Az, Bx, By, Bz, R), @cylt(Ox, Oy, Oz, Dx, Dy, Dz, Ax, Ay, Az, Bx, By, Bz, R) < DistL - 0.05.

shadow_b1(I) :- srod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz, DistL), @spht(Ox, Oy, Oz, Dx, Dy, Dz, 8.65, 0.0, 8.8, 0.5184) < DistL - 0.05.

srays_b1(I, Ox, Oy, Oz, Dx, Dy, Dz) :- srod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz, DistL).

stmar_b1(I, 0.02, 0) :- srays_b1(I, Ox, Oy, Oz, Dx, Dy, Dz).

stmar_b1(I, T + @toriat(Ox, Oy, Oz, Dx, Dy, Dz, T), It + 1) :- stmar_b1(I, T, It), It < 48, srays_b1(I, Ox, Oy, Oz, Dx, Dy, Dz).

shadow_b1(I) :- stmar_b1(I, T, 48), srod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz, DistL), @torust(Ox, Oy, Oz, Dx, Dy, Dz, T) < DistL - 0.05.

lit_b1(I, 0.0) :- shadow_b1(I).

lit_b1(I, 1.0) :- srod_b1(I, _, _, _, _, _, _, _), !shadow_b1(I).

rays_b2(I, ((Ox * (1.0 - IsMirror)) + (SOx * IsMirror)), ((Oy * (1.0 - IsMirror)) + (SOy * IsMirror)), ((Oz * (1.0 - IsMirror)) + (SOz * IsMirror)), ((Dx * (1.0 - IsMirror)) + (RDx * IsMirror)), ((Dy * (1.0 - IsMirror)) + (RDy * IsMirror)), ((Dz * (1.0 - IsMirror)) + (RDz * IsMirror)), (Thr * (1.0 - 0.28 * IsMirror)), (Accx + V260), (Accy + V260), (Accz + V260)) :-
    rays_b1(I, Ox, Oy, Oz, Dx, Dy, Dz, Thr, Accx, Accy, Accz),
    comb_b1(I, Kind, THit, HPx, HPy, HPz, TNx, TNy, TNz, RDx, RDy, RDz, LDx, LDy, LDz, DistL, SOx, SOy, SOz, IsMirror),
    Kind = 1,
    lit_b1(I, Lit),
    V260 = 1.0 * (Thr * (@power(max((LDx * RDx + LDy * RDy + LDz * RDz), 0.0), 60.0) * Lit) * IsMirror).

done(I, (Accx + (((@satbc(V297, V298, V299, V297) * V300) + (0.66 * V285)) * Thr)), (Accy + (((@satbc(V297, V298, V299, V298) * V300) + (0.78 * V285)) * Thr)), (Accz + (((@satbc(V297, V298, V299, V299) * V300) + (0.96 * V285)) * Thr))) :-
    rays_b1(I, Ox, Oy, Oz, Dx, Dy, Dz, Thr, Accx, Accy, Accz),
    comb_b1(I, Kind, THit, HPx, HPy, HPz, TNx, TNy, TNz, RDx, RDy, RDz, LDx, LDy, LDz, DistL, SOx, SOy, SOz, IsMirror),
    Kind = 2,
    lit_b1(I, Lit),
    V285 = min(1.0, max(0.0, (THit - 70.0) / 160.0)),
    V286 = 0.26 + 0.18 * max(TNz, 0.0),
    V290 = 1.45 * (max((LDx * TNx + LDy * TNy + LDz * TNz), 0.0) * Lit),
    V297 = @terrcolx(HPz) * ((0.45 * V286) + (1.06 * V290)),
    V298 = @terrcoly(HPz) * ((0.56 * V286) + (0.97 * V290)),
    V299 = @terrcolz(HPz) * ((0.8 * V286) + (0.82 * V290)),
    V300 = 1.0 - V285.

done(I, (Accx + (@skyx(Dz) * Thr)), (Accy + (@skyy(Dz) * Thr)), (Accz + (@skyz(Dz) * Thr))) :-
    rays_b1(I, Ox, Oy, Oz, Dx, Dy, Dz, Thr, Accx, Accy, Accz),
    comb_b1(I, Kind, THit, HPx, HPy, HPz, TNx, TNy, TNz, RDx, RDy, RDz, LDx, LDy, LDz, DistL, SOx, SOy, SOz, IsMirror),
    Kind = 0.

rod_b2(I, Ox, Oy, Oz, Dx, Dy, Dz) :- rays_b2(I, Ox, Oy, Oz, Dx, Dy, Dz, Thr, Accx, Accy, Accz).

march_b2(I, max(0.05, (Oz - 1.55) / (-Dz)), 0.0, 1e9, 0) :- rod_b2(I, Ox, Oy, Oz, Dx, Dy, Dz), Dz < -0.001.

march_b2(I, 0.05, 0.0, 1e9, 0) :- rod_b2(I, Ox, Oy, Oz, Dx, Dy, Dz), !(Dz < -0.001).

marcheval_b2(I, T, PT, PD, It, Oz + T * Dz - @terrh(Ox + T * Dx, Oy + T * Dy)) :-
    march_b2(I, T, PT, PD, It), It < 110, rod_b2(I, Ox, Oy, Oz, Dx, Dy, Dz).

terr_b2_hit(I, PT + (T - PT) * PD / (PD - DC)) :- marcheval_b2(I, T, PT, PD, It, DC), PD > 0.0, DC <= 0.0.

march_b2(I, T + max(0.45, T * 0.008), T, DC, It + 1) :-
    marcheval_b2(I, T, PT, PD, It, DC), rod_b2(I, Ox, Oy, Oz, Dx, Dy, Dz), !(PD > 0.0, DC <= 0.0), !(Oz + T * Dz > 1.55, Dz >= 0.0).

terr_b2(I, T) :- terr_b2_hit(I, T).

terr_b2(I, 1e9) :- rod_b2(I, Ox, Oy, Oz, Dx, Dy, Dz), !terr_b2_hit(I, _).

tmar_b2(I, 0.02, 0) :- rod_b2(I, Ox, Oy, Oz, Dx, Dy, Dz).

tmar_b2(I, T + @toriat(Ox, Oy, Oz, Dx, Dy, Dz, T), It + 1) :- tmar_b2(I, T, It), It < 48, rod_b2(I, Ox, Oy, Oz, Dx, Dy, Dz).

torus_b2(I, V322, (V334 * V338), (V335 * V338), (V336 * V338)) :-
    tmar_b2(I, T, 48),
    rod_b2(I, Ox, Oy, Oz, Dx, Dy, Dz),
    V322 = @torust(Ox, Oy, Oz, Dx, Dy, Dz, T),
    V323 = min(V322, 5000.0),
    V327 = Ox + (Dx * V323),
    V328 = Oy + (Dy * V323),
    V329 = Oz + (Dz * V323),
    V330 = @torisdf(V327 + 0.0009, V328 - 0.0009, V329 - 0.0009),
    V331 = @torisdf(V327 - 0.0009, V328 - 0.0009, V329 + 0.0009),
    V332 = @torisdf(V327 - 0.0009, V328 + 0.0009, V329 - 0.0009),
    V333 = @torisdf(V327 + 0.0009, V328 + 0.0009, V329 + 0.0009),
    V334 = @torigx(V330, V331, V332, V333),
    V335 = @torigy(V330, V331, V332, V333),
    V336 = @torigz(V330, V331, V332, V333),
    V338 = 1.0 / @sqrt(max((V334 * V334 + V335 * V335 + V336 * V336), 1e-18)).

cyl_b2(I, Id, V342, V343, min(V342, min(V343, @cylcap(Ox, Oy, Oz, Dx, Dy, Dz, Ax, Ay, Az, Bx, By, Bz, Bx, By, Bz, R)))) :-
    rod_b2(I, Ox, Oy, Oz, Dx, Dy, Dz),
    cyl(Id, Ax, Ay, Az, Bx, By, Bz, R),
    V342 = @cylbody(Ox, Oy, Oz, Dx, Dy, Dz, Ax, Ay, Az, Bx, By, Bz, R),
    V343 = @cylcap(Ox, Oy, Oz, Dx, Dy, Dz, Ax, Ay, Az, Bx, By, Bz, Ax, Ay, Az, R).

cylmin_b2(I, T) :- rod_b2(I, Ox, Oy, Oz, Dx, Dy, Dz), T = min X : { cyl_b2(I, _, _, _, X) }.

cylpick_b2(I, Id) :- cylmin_b2(I, T), Id = min K : { cyl_b2(I, K, _, _, T) }.

cyln_b2(I, (((((V351 * V355) * (1.0 - @eq01(T, TA))) + ((V359 * V363) * @eq01(T, TA))) * (1.0 - V396)) + ((V388 * V392) * V396)), (((((V352 * V355) * (1.0 - @eq01(T, TA))) + ((V360 * V363) * @eq01(T, TA))) * (1.0 - V396)) + ((V389 * V392) * V396)), (((((V353 * V355) * (1.0 - @eq01(T, TA))) + ((V361 * V363) * @eq01(T, TA))) * (1.0 - V396)) + ((V390 * V392) * V396))) :-
    cylpick_b2(I, Id),
    cylmin_b2(I, T),
    rod_b2(I, Ox, Oy, Oz, Dx, Dy, Dz),
    cyl(Id, Ax, Ay, Az, Bx, By, Bz, R),
    cyl_b2(I, Id, TB, TA, _),
    V348 = Ox + (Dx * T),
    V349 = Oy + (Dy * T),
    V350 = Oz + (Dz * T),
    V351 = Bx - Ax,
    V352 = By - Ay,
    V353 = Bz - Az,
    V355 = 1.0 / @sqrt(max((V351 * V351 + V352 * V352 + V353 * V353), 1e-18)),
    V359 = V351 * -1.0,
    V360 = V352 * -1.0,
    V361 = V353 * -1.0,
    V363 = 1.0 / @sqrt(max((V359 * V359 + V360 * V360 + V361 * V361), 1e-18)),
    V381 = ((V348 - Ax) * V351 + (V349 - Ay) * V352 + (V350 - Az) * V353) / (V351 * V351 + V352 * V352 + V353 * V353),
    V388 = V348 - (Ax + (V351 * V381)),
    V389 = V349 - (Ay + (V352 * V381)),
    V390 = V350 - (Az + (V353 * V381)),
    V392 = 1.0 / @sqrt(max((V388 * V388 + V389 * V389 + V390 * V390), 1e-18)),
    V396 = @eq01(T, TB).

sph_b2(I, @spht(Ox, Oy, Oz, Dx, Dy, Dz, 8.65, 0.0, 8.8, 0.5184)) :- rod_b2(I, Ox, Oy, Oz, Dx, Dy, Dz).

planet_b2(I, V412, (((V419 * V423) * (1.0 - V435)) + ((V427 * V431) * V435)), (((V420 * V423) * (1.0 - V435)) + ((V428 * V431) * V435)), (((V421 * V423) * (1.0 - V435)) + ((V429 * V431) * V435))) :-
    rod_b2(I, Ox, Oy, Oz, Dx, Dy, Dz),
    V406 = @sphnear(Ox, Oy, Oz, Dx, Dy, Dz, 24.0, 12.0, 17.5, 36.0),
    V408 = @sphnear(Ox, Oy, Oz, Dx, Dy, Dz, 24.0, 6.6, 17.0, 19.36),
    V409 = @sphfar(Ox, Oy, Oz, Dx, Dy, Dz, 24.0, 6.6, 17.0, 19.36),
    V410 = @planetentry(V406, V408, V409),
    V411 = @planetcavity(V406, @sphfar(Ox, Oy, Oz, Dx, Dy, Dz, 24.0, 12.0, 17.5, 36.0), V408, V409),
    V412 = min(V410, V411),
    V416 = Ox + (Dx * V412),
    V417 = Oy + (Dy * V412),
    V418 = Oz + (Dz * V412),
    V419 = 24.0 - V416,
    V420 = 6.6 - V417,
    V421 = 17.0 - V418,
    V423 = 1.0 / @sqrt(max((V419 * V419 + V420 * V420 + V421 * V421), 1e-18)),
    V427 = V416 - 24.0,
    V428 = V417 - 12.0,
    V429 = V418 - 17.5,
    V431 = 1.0 / @sqrt(max((V427 * V427 + V428 * V428 + V429 * V429), 1e-18)),
    V435 = @le01(V410, V411).

comb_b2(I, (as(V455, number) + 2 * as(V456, number)), V447, V452, V453, V454, V505, V506, V507, (Dx - (V498 * V509)), (Dy - (V499 * V509)), (Dz - (V500 * V509)), (V516 * V520), (V517 * V520), (V518 * V520), @sqrt((V516 * V516 + V517 * V517 + V518 * V518)), (V452 + (((V498 * (1.0 - V456)) + (V505 * V456)) * 0.02)), (V453 + (((V499 * (1.0 - V456)) + (V506 * V456)) * 0.02)), (V454 + (((V500 * (1.0 - V456)) + (V507 * V456)) * 0.02)), V455) :-
    rays_b2(I, Ox, Oy, Oz, Dx, Dy, Dz, Thr, Accx, Accy, Accz),
    terr_b2(I, TTerr),
    torus_b2(I, TTor, NTx, NTy, NTz),
    cylmin_b2(I, TCyl),
    cyln_b2(I, NCx, NCy, NCz),
    sph_b2(I, TSph),
    planet_b2(I, TC, NPx, NPy, NPz),
    V445 = min(TCyl, min(TSph, TTor)),
    V446 = min(V445, TC),
    V447 = min(V446, TTerr),
    V448 = min(V447, 5000.0),
    V452 = Ox + (Dx * V448),
    V453 = Oy + (Dy * V448),
    V454 = Oz + (Dz * V448),
    V455 = @lt01(V446, TTerr) * @lt01(V446, 1e8),
    V456 = @le01(TTerr, V446) * @lt01(TTerr, 1e8),
    V464 = (Ox + (Dx * TSph)) - 8.65,
    V465 = (Oy + (Dy * TSph)) - 0.0,
    V466 = (Oz + (Dz * TSph)) - 8.8,
    V468 = 1.0 / @sqrt(max((V464 * V464 + V465 * V465 + V466 * V466), 1e-18)),
    V481 = @le01(TTor, TCyl) * @le01(TTor, TSph),
    V491 = @lt01(TC, V445),
    V498 = ((((((V464 * V468) * (1.0 - @le01(TCyl, TSph))) + (NCx * @le01(TCyl, TSph))) * (1.0 - V481)) + (NTx * V481)) * (1.0 - V491)) + (NPx * V491),
    V499 = ((((((V465 * V468) * (1.0 - @le01(TCyl, TSph))) + (NCy * @le01(TCyl, TSph))) * (1.0 - V481)) + (NTy * V481)) * (1.0 - V491)) + (NPy * V491),
    V500 = ((((((V466 * V468) * (1.0 - @le01(TCyl, TSph))) + (NCz * @le01(TCyl, TSph))) * (1.0 - V481)) + (NTz * V481)) * (1.0 - V491)) + (NPz * V491),
    V501 = @terrgx(V452, V453),
    V502 = @terrgy(V452, V453),
    V504 = 1.0 / @sqrt(max((V501 * V501 + V502 * V502 + 1.0 * 1.0), 1e-18)),
    V505 = V501 * V504,
    V506 = V502 * V504,
    V507 = 1.0 * V504,
    V509 = 2.0 * (Dx * V498 + Dy * V499 + Dz * V500),
    V516 = 9.0 - V452,
    V517 = -30.0 - V453,
    V518 = 52.0 - V454,
    V520 = 1.0 / @sqrt(max((V516 * V516 + V517 * V517 + V518 * V518), 1e-18)).

srod_b2(I, SOx, SOy, SOz, LDx, LDy, LDz, DistL) :- comb_b2(I, Kind, THit, HPx, HPy, HPz, TNx, TNy, TNz, RDx, RDy, RDz, LDx, LDy, LDz, DistL, SOx, SOy, SOz, IsMirror), Kind > 0.

shadow_b2(I) :- srod_b2(I, Ox, Oy, Oz, Dx, Dy, Dz, DistL), step(S), S < DistL - 0.05, Oz + S * Dz < @terrh(Ox + S * Dx, Oy + S * Dy).

shadow_b2(I) :- srod_b2(I, Ox, Oy, Oz, Dx, Dy, Dz, DistL), cyl(Id, Ax, Ay, Az, Bx, By, Bz, R), @cylt(Ox, Oy, Oz, Dx, Dy, Dz, Ax, Ay, Az, Bx, By, Bz, R) < DistL - 0.05.

shadow_b2(I) :- srod_b2(I, Ox, Oy, Oz, Dx, Dy, Dz, DistL), @spht(Ox, Oy, Oz, Dx, Dy, Dz, 8.65, 0.0, 8.8, 0.5184) < DistL - 0.05.

srays_b2(I, Ox, Oy, Oz, Dx, Dy, Dz) :- srod_b2(I, Ox, Oy, Oz, Dx, Dy, Dz, DistL).

stmar_b2(I, 0.02, 0) :- srays_b2(I, Ox, Oy, Oz, Dx, Dy, Dz).

stmar_b2(I, T + @toriat(Ox, Oy, Oz, Dx, Dy, Dz, T), It + 1) :- stmar_b2(I, T, It), It < 48, srays_b2(I, Ox, Oy, Oz, Dx, Dy, Dz).

shadow_b2(I) :- stmar_b2(I, T, 48), srod_b2(I, Ox, Oy, Oz, Dx, Dy, Dz, DistL), @torust(Ox, Oy, Oz, Dx, Dy, Dz, T) < DistL - 0.05.

lit_b2(I, 0.0) :- shadow_b2(I).

lit_b2(I, 1.0) :- srod_b2(I, _, _, _, _, _, _, _), !shadow_b2(I).

rays_b3(I, ((Ox * (1.0 - IsMirror)) + (SOx * IsMirror)), ((Oy * (1.0 - IsMirror)) + (SOy * IsMirror)), ((Oz * (1.0 - IsMirror)) + (SOz * IsMirror)), ((Dx * (1.0 - IsMirror)) + (RDx * IsMirror)), ((Dy * (1.0 - IsMirror)) + (RDy * IsMirror)), ((Dz * (1.0 - IsMirror)) + (RDz * IsMirror)), (Thr * (1.0 - 0.28 * IsMirror)), (Accx + V543), (Accy + V543), (Accz + V543)) :-
    rays_b2(I, Ox, Oy, Oz, Dx, Dy, Dz, Thr, Accx, Accy, Accz),
    comb_b2(I, Kind, THit, HPx, HPy, HPz, TNx, TNy, TNz, RDx, RDy, RDz, LDx, LDy, LDz, DistL, SOx, SOy, SOz, IsMirror),
    Kind = 1,
    lit_b2(I, Lit),
    V543 = 1.0 * (Thr * (@power(max((LDx * RDx + LDy * RDy + LDz * RDz), 0.0), 60.0) * Lit) * IsMirror).

done(I, (Accx + (((@satbc(V580, V581, V582, V580) * V583) + (0.66 * V568)) * Thr)), (Accy + (((@satbc(V580, V581, V582, V581) * V583) + (0.78 * V568)) * Thr)), (Accz + (((@satbc(V580, V581, V582, V582) * V583) + (0.96 * V568)) * Thr))) :-
    rays_b2(I, Ox, Oy, Oz, Dx, Dy, Dz, Thr, Accx, Accy, Accz),
    comb_b2(I, Kind, THit, HPx, HPy, HPz, TNx, TNy, TNz, RDx, RDy, RDz, LDx, LDy, LDz, DistL, SOx, SOy, SOz, IsMirror),
    Kind = 2,
    lit_b2(I, Lit),
    V568 = min(1.0, max(0.0, (THit - 70.0) / 160.0)),
    V569 = 0.26 + 0.18 * max(TNz, 0.0),
    V573 = 1.45 * (max((LDx * TNx + LDy * TNy + LDz * TNz), 0.0) * Lit),
    V580 = @terrcolx(HPz) * ((0.45 * V569) + (1.06 * V573)),
    V581 = @terrcoly(HPz) * ((0.56 * V569) + (0.97 * V573)),
    V582 = @terrcolz(HPz) * ((0.8 * V569) + (0.82 * V573)),
    V583 = 1.0 - V568.

done(I, (Accx + (@skyx(Dz) * Thr)), (Accy + (@skyy(Dz) * Thr)), (Accz + (@skyz(Dz) * Thr))) :-
    rays_b2(I, Ox, Oy, Oz, Dx, Dy, Dz, Thr, Accx, Accy, Accz),
    comb_b2(I, Kind, THit, HPx, HPy, HPz, TNx, TNy, TNz, RDx, RDy, RDz, LDx, LDy, LDz, DistL, SOx, SOy, SOz, IsMirror),
    Kind = 0.

done(I, (Accx + (@skyx(Dz) * V605)), (Accy + (@skyy(Dz) * V605)), (Accz + (@skyz(Dz) * V605))) :-
    rays_b3(I, Ox, Oy, Oz, Dx, Dy, Dz, Thr, Accx, Accy, Accz),
    V605 = Thr * 1.0.

pixel(I, @tonemap(Accx), @tonemap(Accy), @tonemap(Accz)) :- done(I, Accx, Accy, Accz).
.output pixel
$DATALOG$)
ORDER BY 1
) TO STDOUT WITH (FORMAT csv, DELIMITER E'\t', HEADER false);
