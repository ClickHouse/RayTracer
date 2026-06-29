#!/usr/bin/env python3
"""Animation variant of gen_fold.py: the same arrayFold path tracer, but a
chosen scene quantity (camera, light, ...) moves as a function of a per-frame
query parameter, so a whole animation is just the SAME query run once per frame
with a different {FRAME} value. All of the animation math lives in ClickHouse
SQL; outside ClickHouse there is only a frame loop and the ffmpeg mux (CH can
render each frame but cannot encode an mp4).

Usage:
    gen_anim.py W H SAMPLES DEPTH TEXT [anim=NAME] [param=value ...]

Pre-baked anims (run `gen_anim.py W H S D TEXT anim=list` to print this):

  turntable  -- camera orbits the banner.  params:
                 sweep = peak swing in degrees (default 35; 360 = full spin)
  light      -- the light circles in front of the banner, sweeping the
                specular highlights across the chrome.  params:
                 arc    = peak swing in degrees (default 360; <360 = pendulum)
                 radius = circle radius in scene units (default 28)
                 cz     = height of the circle's centre   (default 34)
                 cy     = how far in front of the banner  (default -30)

Every anim is driven by `t = FRAME / FRAMES` in [0,1). Angles use either
`2*pi*t` (a full loop, seamless) or `sweepRad * sin(2*pi*t)` (a pendulum that
also returns to its start), so frame 0 and frame FRAMES coincide and the clip
loops with no visible seam."""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import font

W       = int(sys.argv[1]) if len(sys.argv) > 1 else 320
H       = int(sys.argv[2]) if len(sys.argv) > 2 else 128
SAMPLES = int(sys.argv[3]) if len(sys.argv) > 3 else 4
DEPTH   = int(sys.argv[4]) if len(sys.argv) > 4 else 4
TEXT    = sys.argv[5] if len(sys.argv) > 5 else "ClickHouse"

# Build the banner from the text and recenter the scene on its midpoint; the
# default "ClickHouse" banner is 49 wide (center x = 24), so dx = 0 there.
BANNER, bannerW = font.banner(TEXT)
bannerH = font.ROWS
cx = (bannerW - 1) / 2.0
dx = cx - 24.0
def fx(x):
    return repr(round(x + dx, 4))

# The static (un-animated) camera / light, reused by anims that hold one fixed.
STATIC_EYE   = f"({fx(24.0)}, -42.0, 12.0)"
STATIC_LIGHT = f"({fx(9.0)}, -30.0, 52.0)"

def _angle(deg_expr, deg):
    """SQL for an angle(t): a full 2*pi loop at >=360, else a sin() pendulum."""
    return "2.0 * pi() * t" if deg >= 360.0 \
        else f"{repr(round(math.radians(deg), 6))} * sin(2.0 * pi() * t)"

# Each anim returns a dict; any key omitted falls back to the un-animated scene:
#   binds  -> extra WITH bindings (may reference `t` and each other)
#   eye    -> camera position expr            (default STATIC_EYE)
#   light  -> light position expr             (default STATIC_LIGHT)
#   slide  -> (x, y, z) offset added to the whole banner (text + chrome ball),
#             so it can fly in/out of frame   (default no offset)
def anim_turntable(p):
    theta = _angle(None, float(p["sweep"]))
    return {"binds": [("theta", theta), ("orbitR", "42.0")],
            "eye": f"({fx(24.0)} + orbitR * sin(theta), -orbitR * cos(theta), 12.0)"}

def anim_light(p):
    phi = _angle(None, float(p["arc"]))
    return {"binds": [("phi", phi),
                      ("lr",  repr(float(p["radius"]))),
                      ("lcz", repr(float(p["cz"])))],
            "light": f"({fx(24.0)} + lr * cos(phi), {repr(float(p['cy']))}, lcz + lr * sin(phi))"}

# Unit direction the banner travels FROM, as (x, z) -- 'left' enters from the
# left (starts at -x), 'bottom' rises up out of the floor (starts at -z), etc.
_FLY_DIRS = {"left": (-1.0, 0.0), "right": (1.0, 0.0),
             "bottom": (0.0, -1.0), "top": (0.0, 1.0)}
def anim_flyin(p):
    if p["dir"] not in _FLY_DIRS:
        sys.exit(f"flyin: dir must be one of {', '.join(_FLY_DIRS)} (got {p['dir']!r})")
    ux, uz = _FLY_DIRS[p["dir"]]
    dist, enter = float(p["dist"]), float(p["enter"])
    # Swoosh over the first `enter` fraction of the clip, then hold settled.
    # prog is ease-out cubic (fast in, decelerating) -> PowerPoint "fly in".
    return {"binds": [("tin",  f"least(1.0, t / {repr(enter)})"),
                      ("prog", "1.0 - pow(1.0 - tin, 3.0)"),
                      ("off",  f"{repr(dist)} * (1.0 - prog)")],
            "slide": (f"({repr(ux)}) * off", "0.0", f"({repr(uz)}) * off")}

ANIMS = {
    "turntable": (anim_turntable, {"sweep": "35"}),
    "light":     (anim_light,     {"arc": "360", "radius": "28", "cz": "34", "cy": "-30"}),
    "flyin":     (anim_flyin,     {"dir": "left", "dist": "60", "enter": "0.6"}),
}

# Parse the trailing `key=value` args (anim selector + its params).
ANIM = "turntable"
KV = {}
for a in sys.argv[6:]:
    if "=" not in a:
        sys.exit(f"gen_anim: expected key=value, got {a!r}")
    k, v = a.split("=", 1)
    if k == "anim":
        ANIM = v
    else:
        KV[k] = v

if ANIM in ("list", "help") or ANIM not in ANIMS:
    lines = [f"available anims: {', '.join(ANIMS)}"]
    for name, (_, defs) in ANIMS.items():
        lines.append(f"  {name}: " + (", ".join(f"{k}={v}" for k, v in defs.items()) or "(no params)"))
    sys.exit("\n".join(lines) if ANIM in ("list", "help") else f"unknown anim {ANIM!r}\n" + "\n".join(lines))

_build, _defaults = ANIMS[ANIM]
PARAMS = {**_defaults, **KV}
unknown = set(PARAMS) - set(_defaults)
if unknown:
    sys.exit(f"anim {ANIM!r} has no param(s): {', '.join(sorted(unknown))}; valid: {', '.join(_defaults)}")
SPEC = _build(PARAMS)
EYE_EXPR   = SPEC.get("eye", STATIC_EYE)
LIGHT_EXPR = SPEC.get("light", STATIC_LIGHT)
sx, sy, sz = SPEC.get("slide", ("0.0", "0.0", "0.0"))
# slideX/Y/Z are always defined (zero when not animated) since the banner
# geometry below references them unconditionally; they follow the anim's own
# helper bindings so the slide exprs can reference them.
ALL_BINDS = SPEC.get("binds", []) + [("slideX", sx), ("slideY", sy), ("slideZ", sz)]
ANIM_BINDS_SQL = "".join(f"    {expr} AS {name},\n" for name, expr in ALL_BINDS)

ST ="Tuple(Tuple(Float64,Float64,Float64), Tuple(Float64,Float64,Float64), Float64, Tuple(Float64,Float64,Float64), Float64)"

def arr(rows):
    return "[" + ", ".join("'" + r + "'" for r in rows) + "]"

# "let name = expr in body" implemented as arrayMap(name -> body, [expr])[1].
# arrayMap's lambda parameter is bound by value, so each expr is evaluated once
# and the AST does not blow up no matter how many times the name is referenced.
def lets(bindings, body):
    for name, expr in reversed(bindings):
        body = f"arrayMap({name} -> {body}, [{expr}])[1]"
    return body

# The bounce, as a sequence of by-value bindings (s = ray state, lpos = light).
_BIND = [
    ("o",   "s.1"),
    ("d",   "s.2"),
    ("thr", "s.3"),
    ("acc", "s.4"),
    ("hits",   "sphereHits(o, d)"),
    ("tP",     "planeT(o, d)"),
    ("pairA",  "sphPair(o, d, csgA, csgAr)"),
    ("pairB",  "sphPair(o, d, csgB, csgBr)"),
    ("tS",     "arrayMin(hits)"),
    ("cEnter", "if(pairA.1 > eps AND pairA.1 < 1e8 AND NOT (pairB.1 <= pairA.1 AND pairA.1 <= pairB.2), pairA.1, 1e9)"),
    ("cCav",   "if(pairB.1 < 1e8 AND pairB.2 > eps AND pairA.1 <= pairB.2 AND pairB.2 <= pairA.2, pairB.2, 1e9)"),
    ("tC",     "least(cEnter, cCav)"),
    ("tM",     "least(tS, tC)"),
    ("tHit",   "least(tM, tP)"),
    ("hp",     "va(o, vm(d, tHit))"),
    ("sn",     "if(tC < tS, if(cEnter <= cCav, vn(vs(hp, csgA)), vn(vs(csgB, hp))), vn(vs(hp, spheres[indexOf(hits, tS)])))"),
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
ONE_BOUNCE = lets(_BIND, _BODY)

PRELUDE = f"""WITH
    {arr(BANNER)} AS banner,
    {bannerW} AS bannerW, {bannerH} AS bannerH,
    1.0 AS spacing, 0.92 AS radius, 3.0 AS z0,
    ({fx(24.0)}, 0.0, 6.0)    AS target,
    /* ---- per-frame animation '{ANIM}', computed in SQL ---- */
    {{FRAME:UInt32}}::Float64 / {{FRAMES:UInt32}}::Float64 AS t,   /* 0..1 over the loop */
{ANIM_BINDS_SQL}    {EYE_EXPR} AS eye,
    34.0 AS fovDeg,
    getSetting('output_format_image_width')::UInt64  AS W,
    getSetting('output_format_image_height')::UInt64 AS H,
    W::Float64 AS imgW, H::Float64 AS imgH,
    {DEPTH} AS maxDepth,
    {LIGHT_EXPR}  AS lightPos,
    5.0 AS lightR,
    (0.42, 0.60, 0.95)  AS skyColor,
    (0.66, 0.78, 0.96)  AS hazeColor,
    35.0 AS fogStart, 120.0 AS fogRange,
    (0.90, 0.27, 0.23)  AS floorA,
    (0.93, 0.93, 0.95)  AS floorB,
    5.0 AS tile, 0.30 AS floorAmb, 0.85 AS floorDiff,
    (1.0, 1.0, 1.0)     AS specColor,
    60.0 AS shininess, 0.72 AS reflect_k,
    ({fx(24.0)} + slideX, 12.0 + slideY, 17.5 + slideZ)  AS csgA, 6.0 AS csgAr,
    ({fx(24.0)} + slideX, 6.6 + slideY, 17.0 + slideZ)   AS csgB, 4.4 AS csgBr,
    1.15 AS exposure, 2.2 AS gamma, 0.002 AS eps,

    ((a, b) -> tuplePlus(a, b))                                   AS va,
    ((a, b) -> tupleMinus(a, b))                                  AS vs,
    ((a, s) -> tupleMultiplyByNumber(a, s))                       AS vm,
    ((a, b) -> dotProduct(a, b))                                  AS vd,
    ((a)    -> L2Normalize(a))                                    AS vn,
    ((a, b) -> (a.2*b.3 - a.3*b.2, a.3*b.1 - a.1*b.3, a.1*b.2 - a.2*b.1)) AS vc,
    ((d, n) -> tupleMinus(d, tupleMultiplyByNumber(n, 2.0 * dotProduct(d, n)))) AS vref,

    arrayMap(c -> (c.1 * spacing + slideX, 0.0 + slideY, (toFloat64(bannerH - 1) - c.2) * spacing + z0 + slideZ),
      arrayFilter(c -> substring(banner[c.2 + 1], c.1 + 1, 1) = '#',
        arrayFlatten(arrayMap(gy -> arrayMap(gx -> (gx, gy), range(bannerW)), range(bannerH))))) AS spheres,

    L2Normalize(tupleMinus(target, eye))                          AS camFwd,
    L2Normalize(vc(L2Normalize(tupleMinus(target, eye)), (0.0, 0.0, 1.0))) AS camRight,
    vc(camRight, camFwd)                                          AS camUp,
    tan(fovDeg * 0.5 * pi() / 180.0)                              AS tanHalf,
    imgW / imgH AS aspect, radius * radius AS r2,

    ((p, d) -> if(
        dotProduct(p, d) * dotProduct(p, d) - (dotProduct(p, p) - r2) > 0.0
        AND -dotProduct(p, d) - sqrt(greatest(dotProduct(p, d) * dotProduct(p, d) - (dotProduct(p, p) - r2), 0.0)) > eps,
        -dotProduct(p, d) - sqrt(greatest(dotProduct(p, d) * dotProduct(p, d) - (dotProduct(p, p) - r2), 0.0)),
        1e9)) AS sphereT,
    ((o, d) -> arrayMap(c -> sphereT(vs(o, c), d), spheres))      AS sphereHits,
    ((o, d, c, rad) -> if(
        dotProduct(vs(o,c), d) * dotProduct(vs(o,c), d) - (dotProduct(vs(o,c), vs(o,c)) - rad*rad) > 0.0,
        (-dotProduct(vs(o,c), d) - sqrt(greatest(dotProduct(vs(o,c), d) * dotProduct(vs(o,c), d) - (dotProduct(vs(o,c), vs(o,c)) - rad*rad), 0.0)),
         -dotProduct(vs(o,c), d) + sqrt(greatest(dotProduct(vs(o,c), d) * dotProduct(vs(o,c), d) - (dotProduct(vs(o,c), vs(o,c)) - rad*rad), 0.0))),
        (1e9, -1e9))) AS sphPair,
    ((o, d) -> if(d.3 < -eps AND o.3 > 0.0, -o.3 / d.3, 1e9))     AS planeT,
    ((o, d, maxd) -> arrayExists(c -> sphereT(vs(o, c), d) < maxd, spheres)) AS occluded,
    ((d) -> tupleMultiplyByNumber(skyColor, 0.35 + 0.65 * pow(greatest(1.0 - d.3, 0.0), 3.0))) AS sky,
    ((p) -> (toInt64(floor(p.1 / tile)) + toInt64(floor(p.2 / tile))) % 2) AS checker,
    ((a, b, c) -> (cityHash64(a, b, c) % 1048576) / 1048576.0)    AS rnd,

    /* ---- one full bounce of a ray. Each intermediate is bound exactly once via
            arrayMap(x -> body, [expr])[1] -- a by-value "let", since arrayMap's
            lambda parameter is bound by value (unlike WITH-lambda macro args). ---- */
    ((s, lpos) -> {ONE_BOUNCE}) AS oneBounce
"""

QUERY = PRELUDE + f"""
SELECT
    clamp(pow(greatest(avg(col.1), 0.0) * exposure, 1.0 / gamma), 0.0, 1.0) AS r,
    clamp(pow(greatest(avg(col.2), 0.0) * exposure, 1.0 / gamma), 0.0, 1.0) AS g,
    clamp(pow(greatest(avg(col.3), 0.0) * exposure, 1.0 / gamma), 0.0, 1.0) AS b,
    pixel % W      AS x,                          /* explicit PNG coordinates: no ORDER BY needed */
    intDiv(pixel, W) AS y
FROM (
  SELECT pixel, va(st.4, if(st.5 > 0.5, vm(sky(st.2), st.3), (0.0,0.0,0.0))) AS col
  FROM (
    SELECT pixel,
      /* the bounce loop: a fold over range(maxDepth), not recursion */
      arrayFold((s, i) -> if(s.5 > 0.5, oneBounce(s, lpos), s), range(maxDepth), st0) AS st
    FROM (
      SELECT
        number AS pixel, sample,
        va(lightPos, (lightR * (rnd(number, sample, 3) - 0.5),
                      lightR * (rnd(number, sample, 4) - 0.5),
                      lightR * (rnd(number, sample, 5) - 0.5))) AS lpos,
        CAST((eye,
              vn(va(camFwd, va(vm(camRight, (((number % W) + rnd(number, sample, 1)) / imgW * 2.0 - 1.0) * aspect * tanHalf),
                                vm(camUp,    (1.0 - (intDiv(number, W) + rnd(number, sample, 2)) / imgH * 2.0) * tanHalf)))),
              1.0, (0.0, 0.0, 0.0), 1.0) AS {ST}) AS st0
      FROM numbers_mt(W * H)
      ARRAY JOIN range({{SAMPLES:UInt32}}) AS sample
    )
  )
)
GROUP BY pixel
SETTINGS max_block_size = 2048,
         optimize_and_compare_chain = 0
FORMAT PNG
"""

sys.stdout.write(QUERY)
