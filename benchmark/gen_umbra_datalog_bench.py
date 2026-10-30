#!/usr/bin/env python3
"""Emit the benchmark scene as an Umbra Datalog program (umbra.datalog).

The same scene, rays and arithmetic as the Umbra SQL port (gen_umbra_bench.py),
written as Soufflé-style Datalog instead of SQL:

  scalar helpers (terrain noise,  -> SQL functions, called from the rules as
  tori SDF, ray/primitive hits,      @name(...); a hit test returns the 1e9
  camera, colour ramps, ...)         sentinel on a miss, as in the SQL port
  double precision[3] vectors     -> three float8 columns (x, y, z); the vector
                                     arithmetic is expanded by generator macros
                                     that bind shared values ("V = expr")
  WITH RECURSIVE ray-marches      -> recursive relations (one tuple per step)
  GROUP BY min / bool_or          -> min aggregates / plain derivation
  bounce loop                     -> unrolled per depth, like the SQL ports
                                     (an aggregate cannot sit in a recursion)

Datalog values cannot be arrays, so the SQL functions take and return scalars;
a vector-valued helper becomes one function per component (e.g. the torus
normal's gradient toriGx/Gy/Gz). Every floating-point operation mirrors the SQL
port, down to its double-precision camera arithmetic and the sentinel normals that
the SQL sel() chains read, so the image is byte-identical to the SQL port on the same
Umbra build.

The function bodies are queries (AS 'SELECT expr'), as in PostgreSQL; this needs
an Umbra build that takes a query as the body of a SQL function (master with
branch schmidt/sql-udf-select-body, or the 26.10 image from 2026-10-15 on),
earlier builds expect a bare expression.

Like the SQL port, the script creates or replaces the functions, leaves them in
place and runs the program. It runs outside a transaction: rolling back after a
query this size takes seconds. The
program needs 64-bit Soufflé domains (SET debug.datalog.use64bit = on, emitted
below): float is then float8, as in the SQL port, and number is bigint, which is
why the integer function parameters are bigint. The full 2560x1200 render peaks
at ~170 GB of allocations.

Usage:  gen_umbra_datalog_bench.py [W] [H] [DEPTH]   (default 48 24 2)
"""
import math, re, sys
import primfont2

W     = int(sys.argv[1]) if len(sys.argv) > 1 else 48
H     = int(sys.argv[2]) if len(sys.argv) > 2 else 24
DEPTH = int(sys.argv[3]) if len(sys.argv) > 3 else 2

def f(v):
    # the literal text the SQL ports use (repr of the value rounded to 8 digits), never -0.0
    s = repr(round(float(v), 8))
    return "0.0" if s == "-0.0" else s

# ---- geometry (world space), as in the other generators ----
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
CSGA, CSGB, RA, RB = [24.0, 12.0, 17.5], [24.0, 6.6, 17.0], 6.0, 4.4
SPHC, SPHRR = sph[0][:3], sph[0][3] * sph[0][3]
SENTINEL = "1e9"

def vec(xs): return tuple(f(x) for x in xs)

# ====================================================================
#  SQL functions: the scalar math. A helper's parameters bind values the body
#  uses more than once (e.g. vnoise2's fx = floor(x)), so they are computed once.
# ====================================================================
FUNCS = []
def sqlfn(name, params, body, returns="double precision"):
    ps = ", ".join(p if " " in p else f"{p} double precision" for p in params.split(", ")) if params else ""
    FUNCS.append((name, f"CREATE OR REPLACE FUNCTION {name}({ps}) RETURNS {returns} LANGUAGE sql AS\n  'SELECT {body}';"))

# -- small scalar helpers; the 0/1 weights are the SQL port's f01(predicate)
sqlfn("mixS",    "a, b, t", "a + (b - a) * t")
sqlfn("lerpS",   "a, b, t", "a * (1.0 - t) + b * t")
sqlfn("clamp01", "x",       "greatest(0.0, least(1.0, x))")
for name, op in (("lt01", "<"), ("le01", "<="), ("eq01", "=")):
    sqlfn(name, "x, y", f"CASE WHEN x {op} y THEN 1.0::double precision ELSE 0.0::double precision END")

# -- camera ray components (double precision, as in the SQL port and the reference) and tone mapping
DBL = "double precision"
sqlfn("camU", "g bigint", f"(((g % {W})::{DBL} + 0.5) / {W}.0::{DBL} * 2.0 - 1.0) * ({W}.0::{DBL} / {H}.0::{DBL})"
                          f" * tan(36.0::{DBL} * 0.5 * pi() / 180.0)")
sqlfn("camV", "g bigint", f"(1.0 - ((g / {W})::{DBL} + 0.5) / {H}.0::{DBL} * 2.0) * tan(36.0::{DBL} * 0.5 * pi() / 180.0)")
sqlfn("tonemap", "c", "round(clamp01(power(greatest(c, 0.0) * 1.15::double precision, 1.0::double precision / 2.2::double precision))"
                      " * 255.0::double precision)::bigint", returns="bigint")

# -- terrain: the integer LCG hash of every port, value noise, fbm, height, gradient
sqlfn("hashf", "ix bigint, iy bigint",
      "((((((ix + 4096) + (iy + 4096) * 8192) * 1103515245 + 12345) % 2147483648) * 1103515245 + 12345)"
      " % 2147483648 % 65536)::double precision / 65536.0")
sqlfn("fade", "t", "t * t * t * (t * (t * 6.0 - 15.0) + 10.0)")
sqlfn("vnoise3", "ix bigint, iy bigint, tx, ty",
      "lerpS(lerpS(hashf(ix, iy), hashf(ix + 1, iy), tx), lerpS(hashf(ix, iy + 1), hashf(ix + 1, iy + 1), tx), ty)")
sqlfn("vnoise2", "x, y, fx, fy", "vnoise3(fx::bigint, fy::bigint, fade(x - fx), fade(y - fy))")
sqlfn("vnoise",  "x, y", "vnoise2(x, y, floor(x), floor(y))")
sqlfn("fbm",     "x, y", "(vnoise(x, y) * 0.5 + vnoise(x * 2.0, y * 2.0) * 0.25"
                         " + vnoise(x * 4.0, y * 4.0) * 0.125 + vnoise(x * 8.0, y * 8.0) * 0.0625) / 0.9375")
sqlfn("terrH",   "x, y", "2.4 * (fbm(x * 0.05, y * 0.05) - 0.5)")
sqlfn("terrGx",  "x, y", "(terrH(x - 0.25, y) - terrH(x + 0.25, y)) / 0.5")
sqlfn("terrGy",  "x, y", "(terrH(x, y - 0.25) - terrH(x, y + 0.25)) / 0.5")

# -- colours, one component each: the terrain colour ramp, saturation boost, sky gradient
TERRCOLS = [[0.06,0.24,0.55], [0.84,0.68,0.32], [0.16,0.52,0.09], [0.46,0.32,0.22], [0.97,0.98,1.0]]
sqlfn("terrColC", "h, c0, c1, c2, c3, c4",
      "mixS(mixS(mixS(mixS(c0, c1, clamp01((h + 0.6) / 0.4)), c2, clamp01((h + 0.1) / 0.5)),"
      " c3, clamp01((h - 0.6) / 0.4)), c4, clamp01((h - 1.0) / 0.3))")
for k, axis in enumerate("xyz"):
    sqlfn(f"terrCol{axis}", "h", f"terrColC(h, {', '.join(f(c[k]) for c in TERRCOLS)})")
sqlfn("satbC", "r, g, b, c", "mixS(r * 0.3 + g * 0.59 + b * 0.11, c, 1.45)")
SKY0, SKY1 = [0.66, 0.78, 0.96], [0.30, 0.50, 0.85]
for k, axis in enumerate("xyz"):
    sqlfn(f"sky{axis}", "dz", f"mixS({f(SKY0[k])}, {f(SKY1[k])}, greatest(0.0, least(1.0, dz * 1.5)))")

# -- tori: torus and box SDFs, the scene's tori SDF, along a ray, gradient, hit after the march
sqlfn("tsdf5", "ring, py, rr", "sqrt(ring * ring + py * py) - rr")
sqlfn("tsdf4", "qx, qz, py, r, rr", "tsdf5(sqrt(qx * qx + qz * qz) - r, py, rr)")
sqlfn("tsdf3", "px, py, pz, cx, cz, r, rr", "tsdf4(px - cx, pz - cz, py, r, rr)")
sqlfn("bsdf4", "ax, ay, az", "sqrt(greatest(ax, 0.0) * greatest(ax, 0.0) + greatest(ay, 0.0) * greatest(ay, 0.0)"
                             " + greatest(az, 0.0) * greatest(az, 0.0)) + least(greatest(ax, greatest(ay, az)), 0.0)")
sqlfn("bsdf3", "px, py, pz, cx, cy, cz, hx, hy, hz", "bsdf4(abs(px - cx) - hx, abs(py - cy) - hy, abs(pz - cz) - hz)")
terms = [f"greatest(tsdf3(px, py, pz, {f(cx)}, {f(cz)}, {f(R)}, {f(rr)}), "
         f"-bsdf3(px, py, pz, {f(bcx)}, {f(bcy)}, {f(bcz)}, {f(bhx)}, {f(bhy)}, {f(bhz)}))"
         for (cx, cz, R, rr, bcx, bcy, bcz, bhx, bhy, bhz) in tori]
acc = terms[-1]
for t in reversed(terms[:-1]):
    acc = f"least({t},\n    {acc})"
sqlfn("toriSDF", "px, py, pz", acc)
sqlfn("toriAt", "ox, oy, oz, dx, dy, dz, t", "toriSDF(ox + dx * t, oy + dy * t, oz + dz * t)")
E = "0.0009"
# the normal's gradient by the reference's tetrahedral estimate: the SDF at
# p + (e,-e,-e), (-e,-e,e), (-e,e,-e), (e,e,e) (a, b, c, d), weighted by those signs
sqlfn("toriGx", "a, b, c, d", "(a - b) + (d - c)")
sqlfn("toriGy", "a, b, c, d", "(-a - b) + (c + d)")
sqlfn("toriGz", "a, b, c, d", "(b - a) + (d - c)")
sqlfn("torusT", "ox, oy, oz, dx, dy, dz, t",
      "CASE WHEN toriAt(ox, oy, oz, dx, dy, dz, t) < 0.01 AND t > 0.002 AND t < 260.0 THEN t ELSE 1e9 END")

# -- spheres: nearest hit of the i-dot; near / far intersection of the planet's two spheres
sqlfn("sphT2", "bb, cc", "CASE WHEN bb * bb - cc > 0.0 AND -bb - sqrt(greatest(bb * bb - cc, 0.0)) > 0.002"
                         " THEN -bb - sqrt(greatest(bb * bb - cc, 0.0)) ELSE 1e9 END")
sqlfn("sphT1", "ocx, ocy, ocz, dx, dy, dz, rr",
      "sphT2(ocx * dx + ocy * dy + ocz * dz, ocx * ocx + ocy * ocy + ocz * ocz - rr)")
sqlfn("sphT", "ox, oy, oz, dx, dy, dz, cx, cy, cz, rr", "sphT1(ox - cx, oy - cy, oz - cz, dx, dy, dz, rr)")
# s = -1: near (1e9 if missed), s = +1: far (-1e9 if missed)
sqlfn("sphNF2", "bq, disc, s", "CASE WHEN disc > 0.0 THEN -bq + s * sqrt(disc) ELSE -s * 1e9 END")
sqlfn("sphNF1", "ocx, ocy, ocz, dx, dy, dz, rr, s",
      "sphNF2(ocx * dx + ocy * dy + ocz * dz,"
      " (ocx * dx + ocy * dy + ocz * dz) * (ocx * dx + ocy * dy + ocz * dz) - (ocx * ocx + ocy * ocy + ocz * ocz - rr), s)")
sqlfn("sphNear", "ox, oy, oz, dx, dy, dz, cx, cy, cz, rr", "sphNF1(ox - cx, oy - cy, oz - cz, dx, dy, dz, rr, -1.0)")
sqlfn("sphFar",  "ox, oy, oz, dx, dy, dz, cx, cy, cz, rr", "sphNF1(ox - cx, oy - cy, oz - cz, dx, dy, dz, rr, 1.0)")
# the planet: sphere A minus sphere B, entered through A's surface or through the cavity's back wall
sqlfn("planetEntry",  "an, bn, bf", "CASE WHEN an > 0.002 AND an < 1e8 AND NOT (bn <= an AND an <= bf) THEN an ELSE 1e9 END")
sqlfn("planetCavity", "an, af, bn, bf", "CASE WHEN bn < 1e8 AND bf > 0.002 AND an <= bf AND bf <= af THEN bf ELSE 1e9 END")

# -- capped cylinder a-b, radius r: body (quadratic) and the end disk at c
O6, A3, B3 = "ox, oy, oz, dx, dy, dz", "ax, ay, az", "bx, by, bz"
sqlfn("cylBody3", "tb, hh, aa, baba, bard, baoa",
      "CASE WHEN hh >= 0.0 AND aa > 1e-9 AND tb > 0.002 AND baoa + tb * bard > 0.0 AND baoa + tb * bard < baba THEN tb ELSE 1e9 END")
sqlfn("cylBody2", "aa, bb, cc, baba, bard, baoa",
      "cylBody3((-bb - sqrt(greatest(bb * bb - aa * cc, 0.0))) / aa, bb * bb - aa * cc, aa, baba, bard, baoa)")
sqlfn("cylBody1", "baba, bard, baoa, doa, oaoa, r",
      "cylBody2(baba - bard * bard, baba * doa - baoa * bard, baba * oaoa - baoa * baoa - r * r * baba, baba, bard, baoa)")
sqlfn("cylBodyV", "bax, bay, baz, oax, oay, oaz, dx, dy, dz, r",
      "cylBody1(bax * bax + bay * bay + baz * baz, bax * dx + bay * dy + baz * dz, bax * oax + bay * oay + baz * oaz,"
      " dx * oax + dy * oay + dz * oaz, oax * oax + oay * oay + oaz * oaz, r)")
sqlfn("cylBody", f"{O6}, {A3}, {B3}, r", "cylBodyV(bx - ax, by - ay, bz - az, ox - ax, oy - ay, oz - az, dx, dy, dz, r)")
sqlfn("cylCap3", "den, ta, qx, qy, qz, r",
      "CASE WHEN abs(den) > 1e-9 AND ta > 0.002 AND qx * qx + qy * qy + qz * qz <= r * r THEN ta ELSE 1e9 END")
sqlfn("cylCap2", f"{O6}, cx, cy, cz, r, den, ta", "cylCap3(den, ta, ox + dx * ta - cx, oy + dy * ta - cy, oz + dz * ta - cz, r)")
sqlfn("cylCap1", f"{O6}, cx, cy, cz, r, den, num",
      f"cylCap2({O6}, cx, cy, cz, r, den, num / CASE WHEN abs(den) < 1e-12 THEN 1e-12 ELSE den END)")
sqlfn("cylCapV", f"{O6}, bax, bay, baz, cx, cy, cz, r",
      f"cylCap1({O6}, cx, cy, cz, r, bax * dx + bay * dy + baz * dz, bax * (cx - ox) + bay * (cy - oy) + baz * (cz - oz))")
sqlfn("cylCap", f"{O6}, {A3}, {B3}, cx, cy, cz, r", f"cylCapV({O6}, bx - ax, by - ay, bz - az, cx, cy, cz, r)")
sqlfn("cylT", f"{O6}, {A3}, {B3}, r",
      f"least(cylBody({O6}, {A3}, {B3}, r), least(cylCap({O6}, {A3}, {B3}, {A3}, r), cylCap({O6}, {A3}, {B3}, {B3}, r)))")

# ====================================================================
#  rule bodies: atoms, constraints and "let" bindings
# ====================================================================
class Body:
    """A rule body under construction; let() binds an expression to a fresh variable."""
    counter = 0
    def __init__(self, *atoms):
        self.items = list(atoms)
    def add(self, *items):
        self.items.extend(items)
        return self
    def let(self, expr):
        Body.counter += 1
        v = f"V{Body.counter}"
        self.items.append(f"{v} = {expr}")
        return v
    def vlet(self, xs):
        return tuple(self.let(x) for x in xs)
    def rule(self, head):
        # A variable used only once is inlined into its use, parenthesized so the evaluation
        # order (and so every float result) stays the same; only shared values stay bound.
        items = list(self.items)
        for k in range(len(items) - 1, -1, -1):
            m = LET.fullmatch(items[k])
            if not m: continue
            var, expr = m.groups()
            use = re.compile(rf"\b{var}\b")
            later = [j for j in range(k + 1, len(items)) if use.search(items[j])]
            n = sum(len(use.findall(items[j])) for j in later) + len(use.findall(head))
            if n > 1: continue
            if not atomic(expr): expr = f"({expr})"
            for j in later: items[j] = use.sub(lambda _: expr, items[j])
            head = use.sub(lambda _: expr, head)
            del items[k]
        return f"{head} :-\n    " + ",\n    ".join(items) + "."

LET = re.compile(r"(V\d+) = (.*)", re.S)
def atomic(expr):
    """Is expr a single operand (name, number, or one call spanning the whole text)?"""
    if re.fullmatch(r"-?[\w.]+", expr): return True
    m = re.match(r"@?\w+\(", expr)
    if not m or not expr.endswith(")"): return False
    depth = 0
    for i, ch in enumerate(expr):
        depth += (ch == "(") - (ch == ")")
        if depth == 0 and i >= m.end() - 1: return i == len(expr) - 1
    return False

# vector helpers, component-wise with the SQL helpers' operation order
def va(b, x, y):  return b.vlet([f"{x[i]} + {y[i]}" for i in range(3)])
def vs(b, x, y):  return b.vlet([f"{x[i]} - {y[i]}" for i in range(3)])
def vm(b, x, s):  return b.vlet([f"{x[i]} * {s}" for i in range(3)])
def vmul(b, x, y): return b.vlet([f"{x[i]} * {y[i]}" for i in range(3)])
def vd(b, x, y):  return b.let(f"{x[0]} * {y[0]} + {x[1]} * {y[1]} + {x[2]} * {y[2]}")
def vn(b, x):     return vm(b, x, b.let(f"1.0 / @sqrt(max({vd(b, x, x)}, 1e-18))"))
def vref(b, d, n): return vs(b, d, vm(b, n, b.let(f"2.0 * {vd(b, d, n)}")))
def mix(b, x, y, t): return va(b, x, vm(b, vs(b, y, x), t))
def sel(b, x, y, c): return va(b, vm(b, x, f"(1.0 - {c})"), vm(b, y, c))   # x (c = 0) or y (c = 1), exactly
def vc(b, x, y):  return b.vlet([f"{x[1]} * {y[2]} - {x[2]} * {y[1]}", f"{x[2]} * {y[0]} - {x[0]} * {y[2]}",
                                 f"{x[0]} * {y[1]} - {x[1]} * {y[0]}"])
def pt(b, o, d, t): return va(b, o, vm(b, d, t))
def call(fn, *args): return f"@{fn.lower()}({', '.join(args)})"    # SQL keeps unquoted names in lower case

# ====================================================================
#  relations
# ====================================================================
F3 = "x: float8, y: float8, z: float8"
def cols3(prefix): return f"{prefix}x: float8, {prefix}y: float8, {prefix}z: float8"
decls, rules = [], []
def decl(name, attrs): decls.append(f".decl {name}({attrs})")

RAY = "i: number, " + cols3("o") + ", " + cols3("d")
def ray_atom(rel):
    return f"{rel}(I, Ox, Oy, Oz, Dx, Dy, Dz)"
O, D = ("Ox", "Oy", "Oz"), ("Dx", "Dy", "Dz")
OD = (*O, *D)
CYL = "cyl(Id, Ax, Ay, Az, Bx, By, Bz, R)"
AB = ("Ax", "Ay", "Az", "Bx", "By", "Bz")

def emit_torus_march(name, rays):
    """The 48-step tori sphere-trace march of each ray in `rays`. A step tuple holds only the
    ray id and the march state; origin and direction are joined in, which keeps the
    recursive relation (every step of every ray) a third of the size."""
    decl(name, "i: number, t: float8, it: number")
    rules.append(f"{name}(I, 0.02, 0) :- {ray_atom(rays)}.")
    rules.append(f"{name}(I, T + {call('toriAt', *OD, 'T')}, It + 1) :- {name}(I, T, It), It < 48, {ray_atom(rays)}.")

# ====================================================================
#  one bounce: rays_S(i, o, d, thr, acc) -> rays of the next bounce and finished pixels
# ====================================================================
def emit_bounce(Sx):
    R = f"rays_{Sx}"
    rays_atom = f"{R}(I, Ox, Oy, Oz, Dx, Dy, Dz, Thr, Accx, Accy, Accz)"
    rod = f"rod_{Sx}"
    decl(rod, RAY)
    rules.append(f"{rod}(I, Ox, Oy, Oz, Dx, Dy, Dz) :- {rays_atom}.")

    # -- terrain height-field march: one tuple per step while the ray is active (the step tuples
    #    hold only the march state; origin and direction are joined in from the ray)
    m = f"march_{Sx}"
    decl(m, "i: number, t: float8, prevt: float8, prevdiff: float8, it: number")
    rules.append(f"{m}(I, max(0.05, (Oz - 1.55) / (-Dz)), 0.0, 1e9, 0) :- {ray_atom(rod)}, Dz < -0.001.")
    rules.append(f"{m}(I, 0.05, 0.0, 1e9, 0) :- {ray_atom(rod)}, !(Dz < -0.001).")
    me = f"marcheval_{Sx}"
    decl(me, "i: number, t: float8, prevt: float8, prevdiff: float8, it: number, dc: float8")
    rules.append(f"{me}(I, T, PT, PD, It, Oz + T * Dz - @terrh(Ox + T * Dx, Oy + T * Dy)) :-\n"
                 f"    {m}(I, T, PT, PD, It), It < 110, {ray_atom(rod)}.")
    me_atom = f"{me}(I, T, PT, PD, It, DC)"
    # crossing: interpolate the surface between the previous and the current step
    decl(f"terr_{Sx}_hit", "i: number, t: float8")
    rules.append(f"terr_{Sx}_hit(I, PT + (T - PT) * PD / (PD - DC)) :- {me_atom}, PD > 0.0, DC <= 0.0.")
    # no crossing and not escaping upwards: take the next step
    rules.append(f"{m}(I, T + max(0.45, T * 0.008), T, DC, It + 1) :-\n"
                 f"    {me_atom}, {ray_atom(rod)}, !(PD > 0.0, DC <= 0.0), !(Oz + T * Dz > 1.55, Dz >= 0.0).")
    # the hit, or the sentinel for a ray that never crosses the surface
    decl(f"terr_{Sx}", "i: number, t: float8")
    rules.append(f"terr_{Sx}(I, T) :- terr_{Sx}_hit(I, T).")
    rules.append(f"terr_{Sx}(I, {SENTINEL}) :- {ray_atom(rod)}, !terr_{Sx}_hit(I, _).")

    # -- tori: march, hit test after the last step, normal at the hit (or the sentinel point)
    emit_torus_march(f"tmar_{Sx}", rod)
    decl(f"torus_{Sx}", "i: number, t: float8, " + F3)
    b = Body(f"tmar_{Sx}(I, T, 48)", ray_atom(rod))
    tt = b.let(call("torusT", *OD, "T"))
    p = pt(b, O, D, b.let(f"min({tt}, 5000.0)"))
    sdf = [b.let(call("toriSDF", f"{p[0]} {sx} {E}", f"{p[1]} {sy} {E}", f"{p[2]} {sz} {E}"))
           for sx, sy, sz in (("+", "-", "-"), ("-", "-", "+"), ("-", "+", "-"), ("+", "+", "+"))]
    n = vn(b, tuple(b.let(call(g, *sdf)) for g in ("toriGx", "toriGy", "toriGz")))
    rules.append(b.rule(f"torus_{Sx}(I, {tt}, {', '.join(n)})"))

    # -- cylinders: body and cap hits per ray and cylinder, the nearest (ties: lowest id), its normal
    cy = f"cyl_{Sx}"
    decl(cy, "i: number, id: number, tb: float8, ta: float8, t: float8")
    b = Body(ray_atom(rod), CYL)
    tb, ta = b.let(call("cylBody", *OD, *AB, "R")), b.let(call("cylCap", *OD, *AB, "Ax", "Ay", "Az", "R"))
    tc = b.let(call("cylCap", *OD, *AB, "Bx", "By", "Bz", "R"))
    rules.append(b.rule(f"{cy}(I, Id, {tb}, {ta}, min({tb}, min({ta}, {tc})))"))
    decl(f"cylmin_{Sx}", "i: number, t: float8")
    rules.append(f"cylmin_{Sx}(I, T) :- {ray_atom(rod)}, T = min X : {{ {cy}(I, _, _, _, X) }}.")
    decl(f"cylpick_{Sx}", "i: number, id: number")
    rules.append(f"cylpick_{Sx}(I, Id) :- cylmin_{Sx}(I, T), Id = min K : {{ {cy}(I, K, _, _, T) }}.")
    decl(f"cyln_{Sx}", "i: number, " + F3)
    b = Body(f"cylpick_{Sx}(I, Id)", f"cylmin_{Sx}(I, T)", ray_atom(rod), CYL, f"{cy}(I, Id, TB, TA, _)")
    A, B = AB[:3], AB[3:]
    hp, ba = pt(b, O, D, "T"), vs(b, B, A)
    m1 = sel(b, vn(b, ba), vn(b, vm(b, ba, "-1.0")), call("eq01", "T", "TA"))
    side = vn(b, vs(b, hp, va(b, A, vm(b, ba, b.let(f"{vd(b, vs(b, hp, A), ba)} / {vd(b, ba, ba)}")))))
    n = sel(b, m1, side, b.let(call("eq01", "T", "TB")))
    rules.append(b.rule(f"cyln_{Sx}(I, {', '.join(n)})"))

    # -- the i-dot sphere and the planet (a sphere with a spherical cavity)
    decl(f"sph_{Sx}", "i: number, t: float8")
    rules.append(f"sph_{Sx}(I, {call('sphT', *OD, *vec(SPHC), f(SPHRR))}) :- {ray_atom(rod)}.")
    decl(f"planet_{Sx}", "i: number, t: float8, " + F3)
    b = Body(ray_atom(rod))
    an, af = (b.let(call(fn, *OD, *vec(CSGA), f(RA * RA))) for fn in ("sphNear", "sphFar"))
    bn, bf = (b.let(call(fn, *OD, *vec(CSGB), f(RB * RB))) for fn in ("sphNear", "sphFar"))
    ce, cc = b.let(call("planetEntry", an, bn, bf)), b.let(call("planetCavity", an, af, bn, bf))
    tc = b.let(f"min({ce}, {cc})")
    hp = pt(b, O, D, tc)
    n = sel(b, vn(b, vs(b, vec(CSGB), hp)), vn(b, vs(b, hp, vec(CSGA))), b.let(call("le01", ce, cc)))
    rules.append(b.rule(f"planet_{Sx}(I, {tc}, {', '.join(n)})"))

    # -- nearest hit, surface normal, shadow ray and reflected ray (SQL comb_*)
    cb = f"comb_{Sx}"
    decl(cb, "i: number, kind: number, thit: float8, " + cols3("hp") + ", " + cols3("tn") + ", " + cols3("rd")
         + ", " + cols3("ld") + ", distl: float8, " + cols3("so") + ", ismirror: float8")
    b = Body(rays_atom, f"terr_{Sx}(I, TTerr)", f"torus_{Sx}(I, TTor, NTx, NTy, NTz)",
             f"cylmin_{Sx}(I, TCyl)", f"cyln_{Sx}(I, NCx, NCy, NCz)", f"sph_{Sx}(I, TSph)",
             f"planet_{Sx}(I, TC, NPx, NPy, NPz)")
    tlet = b.let("min(TCyl, min(TSph, TTor))")
    tm = b.let(f"min({tlet}, TC)")
    thit = b.let(f"min({tm}, TTerr)")
    hp = pt(b, O, D, b.let(f"min({thit}, 5000.0)"))
    ismirror = b.let(f"{call('lt01', tm, 'TTerr')} * {call('lt01', tm, '1e8')}")
    isterr = b.let(f"{call('le01', 'TTerr', tm)} * {call('lt01', 'TTerr', '1e8')}")
    kind = b.let(f"as({ismirror}, number) + 2 * as({isterr}, number)")    # 1 mirror, 2 terrain, 0 miss
    nsph = vn(b, vs(b, pt(b, O, D, "TSph"), vec(SPHC)))
    sn = sel(b, nsph, ("NCx", "NCy", "NCz"), call("le01", "TCyl", "TSph"))
    sn = sel(b, sn, ("NTx", "NTy", "NTz"), b.let(f"{call('le01', 'TTor', 'TCyl')} * {call('le01', 'TTor', 'TSph')}"))
    sn = sel(b, sn, ("NPx", "NPy", "NPz"), b.let(call("lt01", "TC", tlet)))
    tn = vn(b, (b.let(call("terrGx", hp[0], hp[1])), b.let(call("terrGy", hp[0], hp[1])), "1.0"))
    rd = vref(b, D, sn)
    tol = vs(b, vec(LIGHT), hp)
    ld = vn(b, tol)
    distl = b.let(f"@sqrt({vd(b, tol, tol)})")
    so = va(b, hp, vm(b, sel(b, sn, tn, isterr), "0.02"))
    rules.append(b.rule(f"{cb}(I, {kind}, {thit}, {', '.join(hp)}, {', '.join(tn)}, {', '.join(rd)}, "
                        f"{', '.join(ld)}, {distl}, {', '.join(so)}, {ismirror})"))
    cb_atom = (f"{cb}(I, Kind, THit, HPx, HPy, HPz, TNx, TNy, TNz, RDx, RDy, RDz, LDx, LDy, LDz, DistL, "
               f"SOx, SOy, SOz, IsMirror)")

    # -- shadow rays of the hit rays: terrain (24 fixed steps), cylinders, sphere, tori
    srod = f"srod_{Sx}"
    decl(srod, RAY + ", distl: float8")
    rules.append(f"{srod}(I, SOx, SOy, SOz, LDx, LDy, LDz, DistL) :- {cb_atom}, Kind > 0.")
    sray = f"{srod}(I, Ox, Oy, Oz, Dx, Dy, Dz, DistL)"
    sh = f"shadow_{Sx}"
    decl(sh, "i: number")
    rules.append(f"{sh}(I) :- {sray}, step(S), S < DistL - 0.05, Oz + S * Dz < @terrh(Ox + S * Dx, Oy + S * Dy).")
    rules.append(f"{sh}(I) :- {sray}, {CYL}, {call('cylT', *OD, *AB, 'R')} < DistL - 0.05.")
    rules.append(f"{sh}(I) :- {sray}, {call('sphT', *OD, *vec(SPHC), f(SPHRR))} < DistL - 0.05.")
    srays = f"srays_{Sx}"
    decl(srays, RAY)
    rules.append(f"{srays}(I, Ox, Oy, Oz, Dx, Dy, Dz) :- {sray}.")
    emit_torus_march(f"stmar_{Sx}", srays)
    rules.append(f"{sh}(I) :- stmar_{Sx}(I, T, 48), {sray}, {call('torusT', *OD, 'T')} < DistL - 0.05.")
    decl(f"lit_{Sx}", "i: number, lit: float8")
    rules.append(f"lit_{Sx}(I, 0.0) :- {sh}(I).")
    rules.append(f"lit_{Sx}(I, 1.0) :- {srod}(I, _, _, _, _, _, _, _), !{sh}(I).")

    # -- shading: a mirror hit adds its highlight and continues reflected, terrain and sky end the ray
    nxt = f"rays_{Sx[0]}{int(Sx[1:]) + 1}"
    decl(nxt, RAY + ", thr: float8, " + cols3("acc"))
    b = Body(rays_atom, cb_atom, "Kind = 1", f"lit_{Sx}(I, Lit)")
    spec = b.let(f"@power(max({vd(b, ('LDx', 'LDy', 'LDz'), ('RDx', 'RDy', 'RDz'))}, 0.0), 60.0) * Lit")
    s = b.let(f"1.0 * (Thr * {spec} * IsMirror)")
    acc = va(b, ("Accx", "Accy", "Accz"), (s, s, s))
    o2 = sel(b, O, ("SOx", "SOy", "SOz"), "IsMirror")
    d2 = sel(b, D, ("RDx", "RDy", "RDz"), "IsMirror")
    thr2 = b.let("Thr * (1.0 - 0.28 * IsMirror)")
    rules.append(b.rule(f"{nxt}(I, {', '.join(o2)}, {', '.join(d2)}, {thr2}, {', '.join(acc)})"))
    b = Body(rays_atom, cb_atom, "Kind = 2", f"lit_{Sx}(I, Lit)")
    lam = b.let(f"max({vd(b, ('LDx', 'LDy', 'LDz'), ('TNx', 'TNy', 'TNz'))}, 0.0) * Lit")
    fog = b.let("min(1.0, max(0.0, (THit - 70.0) / 160.0))")
    light = va(b, vm(b, vec([0.45, 0.56, 0.80]), b.let("0.26 + 0.18 * max(TNz, 0.0)")),
               vm(b, vec([1.06, 0.97, 0.82]), b.let(f"1.45 * {lam}")))
    col = vmul(b, tuple(call(f"terrCol{a}", "HPz") for a in "xyz"), light)
    sat = tuple(call("satbC", *col, col[k]) for k in range(3))
    shade = va(b, vm(b, sat, b.let(f"1.0 - {fog}")), vm(b, vec([0.66, 0.78, 0.96]), fog))
    acc = va(b, ("Accx", "Accy", "Accz"), vm(b, shade, "Thr"))
    rules.append(b.rule(f"done(I, {', '.join(acc)})"))
    b = Body(rays_atom, cb_atom, "Kind = 0")
    acc = va(b, ("Accx", "Accy", "Accz"), vm(b, sky(), "Thr"))
    rules.append(b.rule(f"done(I, {', '.join(acc)})"))
    return nxt

def sky(): return tuple(call(f"sky{a}", "Dz") for a in "xyz")

# ---- facts: cylinders and the shadow-march steps (the exact decimals of 0.3 + i*0.6) ----
decl("cyl", "id: number, " + cols3("a") + ", " + cols3("b") + ", r: float8")
facts = [f"cyl({k}, {', '.join(vec(c[:3]))}, {', '.join(vec(c[3:6]))}, {f(c[6])})." for k, c in enumerate(cyls)]
decl("step", "s: float8")
facts += [f"step({repr(0.3 + i * 0.6)})." for i in range(24)]   # in double precision, as the reference
decl("done", "i: number, " + cols3("acc"))

# ---- camera: primary rays through the pixel centres ----
decl("rays_b1", RAY + ", thr: float8, " + cols3("acc"))
b = Body(f"I = range(0, {W * H})")
fwd = vn(b, vs(b, vec(TARGET), vec(EYE)))          # the camera basis at run time, as the reference
right = vn(b, vc(b, fwd, ("0.0", "0.0", "1.0")))
up = vc(b, right, fwd)
d0 = vn(b, va(b, fwd, va(b, vm(b, right, b.let("@camu(I)")), vm(b, up, b.let("@camv(I)")))))
rules.append(b.rule(f"rays_b1(I, {', '.join(vec(EYE))}, {', '.join(d0)}, 1.0, 0.0, 0.0, 0.0)"))

rays = "rays_b1"
for k in range(1, DEPTH + 1):
    rays = emit_bounce(f"b{k}")

# rays still reflecting after the last bounce see the sky
b = Body(f"{rays}(I, Ox, Oy, Oz, Dx, Dy, Dz, Thr, Accx, Accy, Accz)")
acc = va(b, ("Accx", "Accy", "Accz"), vm(b, sky(), b.let("Thr * 1.0")))
rules.append(b.rule(f"done(I, {', '.join(acc)})"))

# ---- tone mapping: the SQL port's exposure and gamma ----
decl("pixel", "i: number, r: number, g: number, b: number")
rules.append("pixel(I, @tonemap(Accx), @tonemap(Accy), @tonemap(Accz)) :- done(I, Accx, Accy, Accz).")

PROGRAM = "\n".join(decls) + "\n\n" + "\n".join(facts) + "\n\n" + "\n\n".join(rules) + "\n.output pixel\n"
CREATE = "\n".join(sql for _, sql in FUNCS)

sys.stdout.write(f"""\
-- ====================================================================
-- ClickHouse-over-terrain benchmark, Umbra Datalog port  ({W}x{H}, depth {DEPTH})
--   terrain + analytic letters + tori march + planet + shadows + bounces
-- ====================================================================
-- the scalar helpers
{CREATE}

SET debug.datalog.use64bit = on;
COPY (
SELECT * FROM umbra.datalog($DATALOG$
{PROGRAM}$DATALOG$)
ORDER BY 1
) TO STDOUT WITH (FORMAT csv, DELIMITER E'\\t', HEADER false);
""")
