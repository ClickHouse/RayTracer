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
  'SELECT ((((g % 2560) + 0.5) / 2560.0 * 2.0 - 1.0) * 2.13333333 * 0.3249197)::double precision';
CREATE OR REPLACE FUNCTION camV(g bigint) RETURNS double precision LANGUAGE sql AS
  'SELECT ((1.0 - ((g / 2560)::int + 0.5) / 1200.0 * 2.0) * 0.3249197)::double precision';
CREATE OR REPLACE FUNCTION tonemap(c double precision) RETURNS bigint LANGUAGE sql AS
  'SELECT round(clamp01(power(greatest(c, 0.0) * 1.15, 1.0/2.2)) * 255)::bigint';
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
CREATE OR REPLACE FUNCTION toriGx(px double precision, py double precision, pz double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT toriSDF(px + 0.0009, py, pz) - toriSDF(px - 0.0009, py, pz)';
CREATE OR REPLACE FUNCTION toriGy(px double precision, py double precision, pz double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT toriSDF(px, py + 0.0009, pz) - toriSDF(px, py - 0.0009, pz)';
CREATE OR REPLACE FUNCTION toriGz(px double precision, py double precision, pz double precision) RETURNS double precision LANGUAGE sql AS
  'SELECT toriSDF(px, py, pz + 0.0009) - toriSDF(px, py, pz - 0.0009)';
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
step(0.9).
step(1.5).
step(2.1).
step(2.7).
step(3.3).
step(3.9).
step(4.5).
step(5.1).
step(5.7).
step(6.3).
step(6.9).
step(7.5).
step(8.1).
step(8.7).
step(9.3).
step(9.9).
step(10.5).
step(11.1).
step(11.7).
step(12.3).
step(12.9).
step(13.5).
step(14.1).

rays_b1(I, 24.0, -45.0, 12.0, (V12 * V16), (V13 * V16), (V14 * V16), 1.0, 0.0, 0.0, 0.0) :-
    I = range(0, 3072000),
    V1 = @camu(I),
    V5 = @camv(I),
    V12 = 0.0 + ((1.0 * V1) + (0.0 * V5)),
    V13 = 0.9912279 + ((0.0 * V1) + (0.13216372 * V5)),
    V14 = -0.13216372 + ((0.0 * V1) + (0.9912279 * V5)),
    V16 = 1.0 / @sqrt(max((V12 * V12 + V13 * V13 + V14 * V14), 1e-18)).

rod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz) :- rays_b1(I, Ox, Oy, Oz, Dx, Dy, Dz, Thr, Accx, Accy, Accz).

march_b1(I, max(0.05, (Oz - 1.55) / (-Dz)), 0.0, 1e9, 0) :- rod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz), Dz < -0.001.

march_b1(I, 0.05, 0.0, 1e9, 0) :- rod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz), !(Dz < -0.001).

marcheval_b1(I, T, PT, PD, It, Oz + T * Dz - @terrh(Ox + T * Dx, Oy + T * Dy)) :-
    march_b1(I, T, PT, PD, It), It < 110, rod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz).

terr_b1_hit(I, PT + (T - PT) * PD / (PD - DC)) :- marcheval_b1(I, T, PT, PD, It, DC), PD > 0.0, DC <= 0.0.

march_b1(I, T + max(0.06, T * 0.035), T, DC, It + 1) :-
    marcheval_b1(I, T, PT, PD, It, DC), rod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz), !(PD > 0.0, DC <= 0.0), !(Oz + T * Dz > 1.55, Dz >= 0.0).

terr_b1(I, T) :- terr_b1_hit(I, T).

terr_b1(I, 1e9) :- rod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz), !terr_b1_hit(I, _).

tmar_b1(I, 0.02, 0) :- rod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz).

tmar_b1(I, T + @toriat(Ox, Oy, Oz, Dx, Dy, Dz, T), It + 1) :- tmar_b1(I, T, It), It < 48, rod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz).

torus_b1(I, V20, (V28 * V32), (V29 * V32), (V30 * V32)) :-
    tmar_b1(I, T, 48),
    rod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz),
    V20 = @torust(Ox, Oy, Oz, Dx, Dy, Dz, T),
    V21 = min(V20, 5000.0),
    V25 = Ox + (Dx * V21),
    V26 = Oy + (Dy * V21),
    V27 = Oz + (Dz * V21),
    V28 = @torigx(V25, V26, V27),
    V29 = @torigy(V25, V26, V27),
    V30 = @torigz(V25, V26, V27),
    V32 = 1.0 / @sqrt(max((V28 * V28 + V29 * V29 + V30 * V30), 1e-18)).

cyl_b1(I, Id, V36, V37, min(V36, min(V37, @cylcap(Ox, Oy, Oz, Dx, Dy, Dz, Ax, Ay, Az, Bx, By, Bz, Bx, By, Bz, R)))) :-
    rod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz),
    cyl(Id, Ax, Ay, Az, Bx, By, Bz, R),
    V36 = @cylbody(Ox, Oy, Oz, Dx, Dy, Dz, Ax, Ay, Az, Bx, By, Bz, R),
    V37 = @cylcap(Ox, Oy, Oz, Dx, Dy, Dz, Ax, Ay, Az, Bx, By, Bz, Ax, Ay, Az, R).

cylmin_b1(I, T) :- rod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz), T = min X : { cyl_b1(I, _, _, _, X) }.

cylpick_b1(I, Id) :- cylmin_b1(I, T), Id = min K : { cyl_b1(I, K, _, _, T) }.

cyln_b1(I, (V67 + (((V82 * V86) - V67) * V90)), (V68 + (((V83 * V86) - V68) * V90)), (V69 + (((V84 * V86) - V69) * V90))) :-
    cylpick_b1(I, Id),
    cylmin_b1(I, T),
    rod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz),
    cyl(Id, Ax, Ay, Az, Bx, By, Bz, R),
    cyl_b1(I, Id, TB, TA, _),
    V42 = Ox + (Dx * T),
    V43 = Oy + (Dy * T),
    V44 = Oz + (Dz * T),
    V45 = Bx - Ax,
    V46 = By - Ay,
    V47 = Bz - Az,
    V49 = 1.0 / @sqrt(max((V45 * V45 + V46 * V46 + V47 * V47), 1e-18)),
    V50 = V45 * V49,
    V51 = V46 * V49,
    V52 = V47 * V49,
    V53 = V45 * -1.0,
    V54 = V46 * -1.0,
    V55 = V47 * -1.0,
    V57 = 1.0 / @sqrt(max((V53 * V53 + V54 * V54 + V55 * V55), 1e-18)),
    V67 = V50 + (((V53 * V57) - V50) * @eq01(T, TA)),
    V68 = V51 + (((V54 * V57) - V51) * @eq01(T, TA)),
    V69 = V52 + (((V55 * V57) - V52) * @eq01(T, TA)),
    V75 = ((V42 - Ax) * V45 + (V43 - Ay) * V46 + (V44 - Az) * V47) / (V45 * V45 + V46 * V46 + V47 * V47),
    V82 = V42 - (Ax + (V45 * V75)),
    V83 = V43 - (Ay + (V46 * V75)),
    V84 = V44 - (Az + (V47 * V75)),
    V86 = 1.0 / @sqrt(max((V82 * V82 + V83 * V83 + V84 * V84), 1e-18)),
    V90 = @eq01(T, TB).

sph_b1(I, @spht(Ox, Oy, Oz, Dx, Dy, Dz, 8.65, 0.0, 8.8, 0.5184)) :- rod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz).

planet_b1(I, V106, (V118 + (((V121 * V125) - V118) * V129)), (V119 + (((V122 * V125) - V119) * V129)), (V120 + (((V123 * V125) - V120) * V129))) :-
    rod_b1(I, Ox, Oy, Oz, Dx, Dy, Dz),
    V100 = @sphnear(Ox, Oy, Oz, Dx, Dy, Dz, 24.0, 12.0, 17.5, 36.0),
    V102 = @sphnear(Ox, Oy, Oz, Dx, Dy, Dz, 24.0, 6.6, 17.0, 19.36),
    V103 = @sphfar(Ox, Oy, Oz, Dx, Dy, Dz, 24.0, 6.6, 17.0, 19.36),
    V104 = @planetentry(V100, V102, V103),
    V105 = @planetcavity(V100, @sphfar(Ox, Oy, Oz, Dx, Dy, Dz, 24.0, 12.0, 17.5, 36.0), V102, V103),
    V106 = min(V104, V105),
    V110 = Ox + (Dx * V106),
    V111 = Oy + (Dy * V106),
    V112 = Oz + (Dz * V106),
    V113 = 24.0 - V110,
    V114 = 6.6 - V111,
    V115 = 17.0 - V112,
    V117 = 1.0 / @sqrt(max((V113 * V113 + V114 * V114 + V115 * V115), 1e-18)),
    V118 = V113 * V117,
    V119 = V114 * V117,
    V120 = V115 * V117,
    V121 = V110 - 24.0,
    V122 = V111 - 12.0,
    V123 = V112 - 17.5,
    V125 = 1.0 / @sqrt(max((V121 * V121 + V122 * V122 + V123 * V123), 1e-18)),
    V129 = @le01(V104, V105).

comb_b1(I, (as(V149, number) + 2 * as(V150, number)), V141, V146, V147, V148, V199, V200, V201, (Dx - (V192 * V203)), (Dy - (V193 * V203)), (Dz - (V194 * V203)), (V210 * V214), (V211 * V214), (V212 * V214), @sqrt((V210 * V210 + V211 * V211 + V212 * V212)), (V146 + ((V192 + ((V199 - V192) * V150)) * 0.02)), (V147 + ((V193 + ((V200 - V193) * V150)) * 0.02)), (V148 + ((V194 + ((V201 - V194) * V150)) * 0.02)), V149) :-
    rays_b1(I, Ox, Oy, Oz, Dx, Dy, Dz, Thr, Accx, Accy, Accz),
    terr_b1(I, TTerr),
    torus_b1(I, TTor, NTx, NTy, NTz),
    cylmin_b1(I, TCyl),
    cyln_b1(I, NCx, NCy, NCz),
    sph_b1(I, TSph),
    planet_b1(I, TC, NPx, NPy, NPz),
    V139 = min(TCyl, min(TSph, TTor)),
    V140 = min(V139, TC),
    V141 = min(V140, TTerr),
    V142 = min(V141, 5000.0),
    V146 = Ox + (Dx * V142),
    V147 = Oy + (Dy * V142),
    V148 = Oz + (Dz * V142),
    V149 = @lt01(V140, TTerr) * @lt01(V140, 1e8),
    V150 = @le01(TTerr, V140) * @lt01(TTerr, 1e8),
    V158 = (Ox + (Dx * TSph)) - 8.65,
    V159 = (Oy + (Dy * TSph)) - 0.0,
    V160 = (Oz + (Dz * TSph)) - 8.8,
    V162 = 1.0 / @sqrt(max((V158 * V158 + V159 * V159 + V160 * V160), 1e-18)),
    V163 = V158 * V162,
    V164 = V159 * V162,
    V165 = V160 * V162,
    V172 = V163 + ((NCx - V163) * @le01(TCyl, TSph)),
    V173 = V164 + ((NCy - V164) * @le01(TCyl, TSph)),
    V174 = V165 + ((NCz - V165) * @le01(TCyl, TSph)),
    V175 = @le01(TTor, TCyl) * @le01(TTor, TSph),
    V182 = V172 + ((NTx - V172) * V175),
    V183 = V173 + ((NTy - V173) * V175),
    V184 = V174 + ((NTz - V174) * V175),
    V185 = @lt01(TC, V139),
    V192 = V182 + ((NPx - V182) * V185),
    V193 = V183 + ((NPy - V183) * V185),
    V194 = V184 + ((NPz - V184) * V185),
    V195 = @terrgx(V146, V147),
    V196 = @terrgy(V146, V147),
    V198 = 1.0 / @sqrt(max((V195 * V195 + V196 * V196 + 1.0 * 1.0), 1e-18)),
    V199 = V195 * V198,
    V200 = V196 * V198,
    V201 = 1.0 * V198,
    V203 = 2.0 * (Dx * V192 + Dy * V193 + Dz * V194),
    V210 = 9.0 - V146,
    V211 = -30.0 - V147,
    V212 = 52.0 - V148,
    V214 = 1.0 / @sqrt(max((V210 * V210 + V211 * V211 + V212 * V212), 1e-18)).

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

rays_b2(I, (Ox + ((SOx - Ox) * IsMirror)), (Oy + ((SOy - Oy) * IsMirror)), (Oz + ((SOz - Oz) * IsMirror)), (Dx + ((RDx - Dx) * IsMirror)), (Dy + ((RDy - Dy) * IsMirror)), (Dz + ((RDz - Dz) * IsMirror)), (Thr * (1.0 - 0.28 * IsMirror)), (Accx + V237), (Accy + V237), (Accz + V237)) :-
    rays_b1(I, Ox, Oy, Oz, Dx, Dy, Dz, Thr, Accx, Accy, Accz),
    comb_b1(I, Kind, THit, HPx, HPy, HPz, TNx, TNy, TNz, RDx, RDy, RDz, LDx, LDy, LDz, DistL, SOx, SOy, SOz, IsMirror),
    Kind = 1,
    lit_b1(I, Lit),
    V237 = 1.0 * (Thr * (@power(max((LDx * RDx + LDy * RDy + LDz * RDz), 0.0), 60.0) * Lit) * IsMirror).

done(I, (Accx + (((@satbc(V274, V275, V276, V274) * V277) + (0.66 * V262)) * Thr)), (Accy + (((@satbc(V274, V275, V276, V275) * V277) + (0.78 * V262)) * Thr)), (Accz + (((@satbc(V274, V275, V276, V276) * V277) + (0.96 * V262)) * Thr))) :-
    rays_b1(I, Ox, Oy, Oz, Dx, Dy, Dz, Thr, Accx, Accy, Accz),
    comb_b1(I, Kind, THit, HPx, HPy, HPz, TNx, TNy, TNz, RDx, RDy, RDz, LDx, LDy, LDz, DistL, SOx, SOy, SOz, IsMirror),
    Kind = 2,
    lit_b1(I, Lit),
    V262 = min(1.0, max(0.0, (THit - 70.0) / 160.0)),
    V263 = 0.26 + 0.18 * max(TNz, 0.0),
    V267 = 1.45 * (max((LDx * TNx + LDy * TNy + LDz * TNz), 0.0) * Lit),
    V274 = @terrcolx(HPz) * ((0.45 * V263) + (1.06 * V267)),
    V275 = @terrcoly(HPz) * ((0.56 * V263) + (0.97 * V267)),
    V276 = @terrcolz(HPz) * ((0.8 * V263) + (0.82 * V267)),
    V277 = 1.0 - V262.

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

march_b2(I, T + max(0.06, T * 0.035), T, DC, It + 1) :-
    marcheval_b2(I, T, PT, PD, It, DC), rod_b2(I, Ox, Oy, Oz, Dx, Dy, Dz), !(PD > 0.0, DC <= 0.0), !(Oz + T * Dz > 1.55, Dz >= 0.0).

terr_b2(I, T) :- terr_b2_hit(I, T).

terr_b2(I, 1e9) :- rod_b2(I, Ox, Oy, Oz, Dx, Dy, Dz), !terr_b2_hit(I, _).

tmar_b2(I, 0.02, 0) :- rod_b2(I, Ox, Oy, Oz, Dx, Dy, Dz).

tmar_b2(I, T + @toriat(Ox, Oy, Oz, Dx, Dy, Dz, T), It + 1) :- tmar_b2(I, T, It), It < 48, rod_b2(I, Ox, Oy, Oz, Dx, Dy, Dz).

torus_b2(I, V299, (V307 * V311), (V308 * V311), (V309 * V311)) :-
    tmar_b2(I, T, 48),
    rod_b2(I, Ox, Oy, Oz, Dx, Dy, Dz),
    V299 = @torust(Ox, Oy, Oz, Dx, Dy, Dz, T),
    V300 = min(V299, 5000.0),
    V304 = Ox + (Dx * V300),
    V305 = Oy + (Dy * V300),
    V306 = Oz + (Dz * V300),
    V307 = @torigx(V304, V305, V306),
    V308 = @torigy(V304, V305, V306),
    V309 = @torigz(V304, V305, V306),
    V311 = 1.0 / @sqrt(max((V307 * V307 + V308 * V308 + V309 * V309), 1e-18)).

cyl_b2(I, Id, V315, V316, min(V315, min(V316, @cylcap(Ox, Oy, Oz, Dx, Dy, Dz, Ax, Ay, Az, Bx, By, Bz, Bx, By, Bz, R)))) :-
    rod_b2(I, Ox, Oy, Oz, Dx, Dy, Dz),
    cyl(Id, Ax, Ay, Az, Bx, By, Bz, R),
    V315 = @cylbody(Ox, Oy, Oz, Dx, Dy, Dz, Ax, Ay, Az, Bx, By, Bz, R),
    V316 = @cylcap(Ox, Oy, Oz, Dx, Dy, Dz, Ax, Ay, Az, Bx, By, Bz, Ax, Ay, Az, R).

cylmin_b2(I, T) :- rod_b2(I, Ox, Oy, Oz, Dx, Dy, Dz), T = min X : { cyl_b2(I, _, _, _, X) }.

cylpick_b2(I, Id) :- cylmin_b2(I, T), Id = min K : { cyl_b2(I, K, _, _, T) }.

cyln_b2(I, (V346 + (((V361 * V365) - V346) * V369)), (V347 + (((V362 * V365) - V347) * V369)), (V348 + (((V363 * V365) - V348) * V369))) :-
    cylpick_b2(I, Id),
    cylmin_b2(I, T),
    rod_b2(I, Ox, Oy, Oz, Dx, Dy, Dz),
    cyl(Id, Ax, Ay, Az, Bx, By, Bz, R),
    cyl_b2(I, Id, TB, TA, _),
    V321 = Ox + (Dx * T),
    V322 = Oy + (Dy * T),
    V323 = Oz + (Dz * T),
    V324 = Bx - Ax,
    V325 = By - Ay,
    V326 = Bz - Az,
    V328 = 1.0 / @sqrt(max((V324 * V324 + V325 * V325 + V326 * V326), 1e-18)),
    V329 = V324 * V328,
    V330 = V325 * V328,
    V331 = V326 * V328,
    V332 = V324 * -1.0,
    V333 = V325 * -1.0,
    V334 = V326 * -1.0,
    V336 = 1.0 / @sqrt(max((V332 * V332 + V333 * V333 + V334 * V334), 1e-18)),
    V346 = V329 + (((V332 * V336) - V329) * @eq01(T, TA)),
    V347 = V330 + (((V333 * V336) - V330) * @eq01(T, TA)),
    V348 = V331 + (((V334 * V336) - V331) * @eq01(T, TA)),
    V354 = ((V321 - Ax) * V324 + (V322 - Ay) * V325 + (V323 - Az) * V326) / (V324 * V324 + V325 * V325 + V326 * V326),
    V361 = V321 - (Ax + (V324 * V354)),
    V362 = V322 - (Ay + (V325 * V354)),
    V363 = V323 - (Az + (V326 * V354)),
    V365 = 1.0 / @sqrt(max((V361 * V361 + V362 * V362 + V363 * V363), 1e-18)),
    V369 = @eq01(T, TB).

sph_b2(I, @spht(Ox, Oy, Oz, Dx, Dy, Dz, 8.65, 0.0, 8.8, 0.5184)) :- rod_b2(I, Ox, Oy, Oz, Dx, Dy, Dz).

planet_b2(I, V385, (V397 + (((V400 * V404) - V397) * V408)), (V398 + (((V401 * V404) - V398) * V408)), (V399 + (((V402 * V404) - V399) * V408))) :-
    rod_b2(I, Ox, Oy, Oz, Dx, Dy, Dz),
    V379 = @sphnear(Ox, Oy, Oz, Dx, Dy, Dz, 24.0, 12.0, 17.5, 36.0),
    V381 = @sphnear(Ox, Oy, Oz, Dx, Dy, Dz, 24.0, 6.6, 17.0, 19.36),
    V382 = @sphfar(Ox, Oy, Oz, Dx, Dy, Dz, 24.0, 6.6, 17.0, 19.36),
    V383 = @planetentry(V379, V381, V382),
    V384 = @planetcavity(V379, @sphfar(Ox, Oy, Oz, Dx, Dy, Dz, 24.0, 12.0, 17.5, 36.0), V381, V382),
    V385 = min(V383, V384),
    V389 = Ox + (Dx * V385),
    V390 = Oy + (Dy * V385),
    V391 = Oz + (Dz * V385),
    V392 = 24.0 - V389,
    V393 = 6.6 - V390,
    V394 = 17.0 - V391,
    V396 = 1.0 / @sqrt(max((V392 * V392 + V393 * V393 + V394 * V394), 1e-18)),
    V397 = V392 * V396,
    V398 = V393 * V396,
    V399 = V394 * V396,
    V400 = V389 - 24.0,
    V401 = V390 - 12.0,
    V402 = V391 - 17.5,
    V404 = 1.0 / @sqrt(max((V400 * V400 + V401 * V401 + V402 * V402), 1e-18)),
    V408 = @le01(V383, V384).

comb_b2(I, (as(V428, number) + 2 * as(V429, number)), V420, V425, V426, V427, V478, V479, V480, (Dx - (V471 * V482)), (Dy - (V472 * V482)), (Dz - (V473 * V482)), (V489 * V493), (V490 * V493), (V491 * V493), @sqrt((V489 * V489 + V490 * V490 + V491 * V491)), (V425 + ((V471 + ((V478 - V471) * V429)) * 0.02)), (V426 + ((V472 + ((V479 - V472) * V429)) * 0.02)), (V427 + ((V473 + ((V480 - V473) * V429)) * 0.02)), V428) :-
    rays_b2(I, Ox, Oy, Oz, Dx, Dy, Dz, Thr, Accx, Accy, Accz),
    terr_b2(I, TTerr),
    torus_b2(I, TTor, NTx, NTy, NTz),
    cylmin_b2(I, TCyl),
    cyln_b2(I, NCx, NCy, NCz),
    sph_b2(I, TSph),
    planet_b2(I, TC, NPx, NPy, NPz),
    V418 = min(TCyl, min(TSph, TTor)),
    V419 = min(V418, TC),
    V420 = min(V419, TTerr),
    V421 = min(V420, 5000.0),
    V425 = Ox + (Dx * V421),
    V426 = Oy + (Dy * V421),
    V427 = Oz + (Dz * V421),
    V428 = @lt01(V419, TTerr) * @lt01(V419, 1e8),
    V429 = @le01(TTerr, V419) * @lt01(TTerr, 1e8),
    V437 = (Ox + (Dx * TSph)) - 8.65,
    V438 = (Oy + (Dy * TSph)) - 0.0,
    V439 = (Oz + (Dz * TSph)) - 8.8,
    V441 = 1.0 / @sqrt(max((V437 * V437 + V438 * V438 + V439 * V439), 1e-18)),
    V442 = V437 * V441,
    V443 = V438 * V441,
    V444 = V439 * V441,
    V451 = V442 + ((NCx - V442) * @le01(TCyl, TSph)),
    V452 = V443 + ((NCy - V443) * @le01(TCyl, TSph)),
    V453 = V444 + ((NCz - V444) * @le01(TCyl, TSph)),
    V454 = @le01(TTor, TCyl) * @le01(TTor, TSph),
    V461 = V451 + ((NTx - V451) * V454),
    V462 = V452 + ((NTy - V452) * V454),
    V463 = V453 + ((NTz - V453) * V454),
    V464 = @lt01(TC, V418),
    V471 = V461 + ((NPx - V461) * V464),
    V472 = V462 + ((NPy - V462) * V464),
    V473 = V463 + ((NPz - V463) * V464),
    V474 = @terrgx(V425, V426),
    V475 = @terrgy(V425, V426),
    V477 = 1.0 / @sqrt(max((V474 * V474 + V475 * V475 + 1.0 * 1.0), 1e-18)),
    V478 = V474 * V477,
    V479 = V475 * V477,
    V480 = 1.0 * V477,
    V482 = 2.0 * (Dx * V471 + Dy * V472 + Dz * V473),
    V489 = 9.0 - V425,
    V490 = -30.0 - V426,
    V491 = 52.0 - V427,
    V493 = 1.0 / @sqrt(max((V489 * V489 + V490 * V490 + V491 * V491), 1e-18)).

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

rays_b3(I, (Ox + ((SOx - Ox) * IsMirror)), (Oy + ((SOy - Oy) * IsMirror)), (Oz + ((SOz - Oz) * IsMirror)), (Dx + ((RDx - Dx) * IsMirror)), (Dy + ((RDy - Dy) * IsMirror)), (Dz + ((RDz - Dz) * IsMirror)), (Thr * (1.0 - 0.28 * IsMirror)), (Accx + V516), (Accy + V516), (Accz + V516)) :-
    rays_b2(I, Ox, Oy, Oz, Dx, Dy, Dz, Thr, Accx, Accy, Accz),
    comb_b2(I, Kind, THit, HPx, HPy, HPz, TNx, TNy, TNz, RDx, RDy, RDz, LDx, LDy, LDz, DistL, SOx, SOy, SOz, IsMirror),
    Kind = 1,
    lit_b2(I, Lit),
    V516 = 1.0 * (Thr * (@power(max((LDx * RDx + LDy * RDy + LDz * RDz), 0.0), 60.0) * Lit) * IsMirror).

done(I, (Accx + (((@satbc(V553, V554, V555, V553) * V556) + (0.66 * V541)) * Thr)), (Accy + (((@satbc(V553, V554, V555, V554) * V556) + (0.78 * V541)) * Thr)), (Accz + (((@satbc(V553, V554, V555, V555) * V556) + (0.96 * V541)) * Thr))) :-
    rays_b2(I, Ox, Oy, Oz, Dx, Dy, Dz, Thr, Accx, Accy, Accz),
    comb_b2(I, Kind, THit, HPx, HPy, HPz, TNx, TNy, TNz, RDx, RDy, RDz, LDx, LDy, LDz, DistL, SOx, SOy, SOz, IsMirror),
    Kind = 2,
    lit_b2(I, Lit),
    V541 = min(1.0, max(0.0, (THit - 70.0) / 160.0)),
    V542 = 0.26 + 0.18 * max(TNz, 0.0),
    V546 = 1.45 * (max((LDx * TNx + LDy * TNy + LDz * TNz), 0.0) * Lit),
    V553 = @terrcolx(HPz) * ((0.45 * V542) + (1.06 * V546)),
    V554 = @terrcoly(HPz) * ((0.56 * V542) + (0.97 * V546)),
    V555 = @terrcolz(HPz) * ((0.8 * V542) + (0.82 * V546)),
    V556 = 1.0 - V541.

done(I, (Accx + (@skyx(Dz) * Thr)), (Accy + (@skyy(Dz) * Thr)), (Accz + (@skyz(Dz) * Thr))) :-
    rays_b2(I, Ox, Oy, Oz, Dx, Dy, Dz, Thr, Accx, Accy, Accz),
    comb_b2(I, Kind, THit, HPx, HPy, HPz, TNx, TNy, TNz, RDx, RDy, RDz, LDx, LDy, LDz, DistL, SOx, SOy, SOz, IsMirror),
    Kind = 0.

done(I, (Accx + (@skyx(Dz) * V578)), (Accy + (@skyy(Dz) * V578)), (Accz + (@skyz(Dz) * V578))) :-
    rays_b3(I, Ox, Oy, Oz, Dx, Dy, Dz, Thr, Accx, Accy, Accz),
    V578 = Thr * 1.0.

pixel(I, @tonemap(Accx), @tonemap(Accy), @tonemap(Accz)) :- done(I, Accx, Accy, Accz).
.output pixel
$DATALOG$)
ORDER BY 1
) TO STDOUT WITH (FORMAT csv, DELIMITER E'\t', HEADER false);
