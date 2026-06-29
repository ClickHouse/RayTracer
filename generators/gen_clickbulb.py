#!/usr/bin/env python3
"""Desk-lamp homage (its own routine, not the Pixar short): a lamp -- built, like
everything else here, entirely from spheres -- hops in, leaps up and OVER the
banner to land behind it, rakes its light left and right across the backs of the
letters, then pushes its head forward through the gap between two letters to peer
at the camera. Same arrayFold path tracer as gen_anim.py; the lamp's articulated
pose is a function of a per-frame {FRAME} parameter, so the whole animation is the
SAME query run once per frame.

The only renderer change vs gen_anim.py: spheres carry a per-sphere radius
((x,y,z,r) instead of just (x,y,z)), because the lamp needs balls of different
sizes (wide base, thin arms, flared shade) while the letters stay uniform.

The lamp's bulb IS the scene light (ClickHouse yellow), so the lamp actually
lights the banner -- backlighting the letters from behind, then lighting the
gap letters from the front as the head pokes through.

Usage:
    gen_clickbulb.py W H SAMPLES DEPTH TEXT [target=INDEX] [gap=N]
TEXT default "CLICKHOUSE"; target = letter index whose RIGHT gap the lamp visits
(default 4, the gap between 'K' and 'H'); gap = blank columns between letters
(default 4, Pixar-style wide spacing).
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import font

W       = int(sys.argv[1]) if len(sys.argv) > 1 else 96
H       = int(sys.argv[2]) if len(sys.argv) > 2 else 40
SAMPLES = int(sys.argv[3]) if len(sys.argv) > 3 else 2
DEPTH   = int(sys.argv[4]) if len(sys.argv) > 4 else 3
TEXT    = sys.argv[5] if len(sys.argv) > 5 else "CLICKHOUSE"

# ---- which inter-letter gap the lamp visits, and letter spacing ----------
TARGET_IDX = 4  # the gap AFTER this letter (default: between 'K'(4) and 'H'(5))
GAP = 4         # blank columns between letters (Pixar "C L I C K H O U S E")
for a in sys.argv[6:]:
    if a.startswith("target="):
        TARGET_IDX = int(a.split("=", 1)[1])
    elif a.startswith("gap="):
        GAP = int(a.split("=", 1)[1])

# While True, ignore {FRAME} and render one fixed pose -- for nailing the lamp
# geometry before wiring up the timeline. Flip to False for the real animation.
STATIC = False

# ---- banner layout -------------------------------------------------------
BANNER, bannerW = font.banner(TEXT, gap=GAP)
bannerH = font.ROWS
cx = (bannerW - 1) / 2.0

# World x of the centre of the inter-letter gap AFTER letter TARGET_IDX -- the
# slot the lamp leaps behind and later pokes its head through. Re-lay the text
# to find where that blank gap sits.
def _gap_x(text, idx, gap):
    x = 0
    for i, ch in enumerate(text):
        g = font._lookup(ch)
        w = max(len(r) for r in g)
        if i == idx:
            return (x + w) + (gap - 1) / 2.0   # centre of the blank gap columns
        x += w + gap
    return x
GAP_X = round(_gap_x(TEXT, TARGET_IDX, GAP), 4)
LETTER_TOP = 3.0 + (bannerH - 1) * 1.0   # z0 + (rows-1)*spacing

# ---- camera: pull back far enough to frame the (now wider) banner --------
FOV_DEG = 34.0
aspect = W / H
# horizontal half-extent to fit = half the banner width + a margin
half_w = bannerW / 2.0 + 4.0
cam_dist = round(half_w / (aspect * math.tan(math.radians(FOV_DEG) / 2.0)), 4)
cam_dist = max(cam_dist, 30.0)
EYE_X = round(cx, 4)
EYE_Y = round(-cam_dist, 4)
EYE_Z = round(0.30 * cam_dist, 4)
TARGET_PT = f"({EYE_X}, 0.0, 6.0)"

# ============================ POSE (per frame) ============================
# Every pose quantity below is an SQL expression in `t` (=FRAME/FRAMES). When
# STATIC, they collapse to constants picking one clear standing/looking pose.
BASE_W = 1.4    # local height where the lower arm attaches to the base
BASE_R = 1.0    # base ball radius (foot height off floor)

def deg(d):
    return repr(round(math.radians(d), 6))

if STATIC:
    # A fixed "peeking through the gap" pose, for checking lamp geometry.
    POSE = {
        "bx":   str(GAP_X),
        "by":   "3.0",
        "bz":   "0.0",
        "cosY": "0.0", "sinY": "-1.0",     # facing -y (toward the camera)
        "a1":   deg(52),    # lower arm reaching forward
        "a2":   deg(66),    # upper arm reaching forward
        "a3":   deg(88),    # head roughly level, aimed at the camera
        "L1c":  "3.6",
        "L2c":  "3.4",
    }
else:
    # ---- animation timeline (all maths in SQL, in terms of t = FRAME/FRAMES) --
    # Beats:
    #   [0,  T1] hop in from the right to the K|H gap, lighting letters en route.
    #   [T1, T2] one big leap up and OVER the banner, landing behind it; turn to
    #            face the letters from behind.
    #   [T2, T3] sweep the head left and right, raking light across the backs of
    #            the letters so they glow rim-lit from behind.
    #   [T3, T4] draw in to the gap and push the head FORWARD through the slot.
    #   [T4, 1 ] head poking through the K|H gap, peering at the camera (a bob).
    T1, T2, T3, T4 = 0.26, 0.44, 0.74, 0.86
    HOPS    = 3
    X_START = bannerW + 8.0             # enters off-frame to the right
    BY_FRONT  = -4.0                    # standing in front, lighting the letters
    BY_BEHIND = 4.5                     # landed behind the banner
    BY_POKE   = 3.0                     # drawn in close to push the head through
    JUMP_H  = round(LETTER_TOP + 2.0, 4)   # leap clears the top of the letters
    SWEEP   = 0.7                       # yaw amplitude of the left/right look (rad)
    A1, A2, A3 = 14.0, 24.0, 138.0     # neutral standing pose (degrees)
    rA1, rA2, rA3 = math.radians(A1), math.radians(A2), math.radians(A3)
    E1, E2 = 52.0, 66.0                # arm angles fully extended for the poke
    rE1, rE2 = math.radians(E1), math.radians(E2)
    pi = "pi()"

    def sm(e):                        # smoothstep on a 0..1 value
        return f"({e})*({e})*(3.0 - 2.0*({e}))"
    def lerp(a, b, p):
        return f"({a} + (({b}) - ({a})) * ({p}))"
    def arc(p, s, e, h):              # p:0..1 jump s->e arching `h` above the chord
        return f"({s} + (({e}) - ({s})) * ({p}) + {h} * 4.0 * ({p}) * (1.0 - ({p})))"

    # Intermediate quantities are emitted as named scalar bindings (referenced by
    # name below) -- inlining them blows the query tree past CH's size limit.
    BINDS = [
        ("p1", f"greatest(0.0, least(1.0, t / {T1}))"),
        ("p2", f"greatest(0.0, least(1.0, (t - {T1}) / {T2 - T1}))"),
        ("p3", f"greatest(0.0, least(1.0, (t - {T2}) / {T3 - T2}))"),
        ("p4", f"greatest(0.0, least(1.0, (t - {T3}) / {T4 - T3}))"),
        ("p5", f"greatest(0.0, least(1.0, (t - {T4}) / {1.0 - T4}))"),
        # vertical rest height of the base centre (base balls sit at bz+BASE_R):
        # hop in, then one big arc up and over the banner, then grounded behind.
        ("bz", f"multiIf(t < {T1}, 5.0 * abs(sin({HOPS} * {pi} * p1)), "
               f"t < {T2}, {arc('p2', 0.0, 0.0, JUMP_H)}, "
               f"t < {T3}, 0.0, t < {T4}, 0.0, 0.12 * sin(2.0*{pi}*p5))"),
        ("air",  "greatest(0.0, least(1.0, bz / 6.0))"),
        # compression spikes only on landings, so the planted poses stand relaxed.
        ("comp", f"greatest(0.0, least(1.0, multiIf("
                 f"t < {T1}, 0.5 * (1.0 - air), "
                 f"t < {T2}, 0.0, "
                 f"t < {T3}, 0.5 * greatest(0.0, 1.0 - p3 / 0.10), "
                 f"0.0)))"),
        # how far the arms fold forward (0..1): tucked while hopping/leaping; a
        # low forward crouch for the rake (drops the head to mid-letter height so
        # the bulb winks through the gaps); fully extended to poke through.
        ("reach", f"multiIf(t < {T2}, 0.0, "
                  f"t < {T3}, {lerp(0.0, 0.55, sm('least(1.0, p3 / 0.25)'))}, "
                  f"t < {T4}, {lerp(0.55, 1.0, sm('p4'))}, 1.0)"),
        # facing: -x while walking in; turn to face the letters from behind (-y);
        # sweep left/right while raking light; hold on the camera at the end.
        ("yaw",  f"multiIf(t < {T1}, {pi}, "
                 f"t < {T2}, {lerp(pi, '1.5*pi()', sm('p2'))}, "
                 f"t < {T3}, 1.5*{pi} + {SWEEP} * sin(2.0*{pi}*p3), "
                 f"t < {T4}, 1.5*{pi}, "
                 f"1.5*{pi} + {math.radians(7)} * sin(3.0*{pi}*p5))"),
    ]
    POSE = dict(BINDS)
    POSE.update({
        "bx": f"multiIf(t < {T1}, {lerp(X_START, GAP_X, sm('p1'))}, {GAP_X})",
        # come in front of the banner, leap to behind it, then draw in to the gap.
        "by": f"multiIf(t < {T1}, {lerp(-11.0, BY_FRONT, sm('p1'))}, "
              f"t < {T2}, {lerp(BY_FRONT, BY_BEHIND, sm('p2'))}, "
              f"t < {T3}, {BY_BEHIND}, "
              f"t < {T4}, {lerp(BY_BEHIND, BY_POKE, sm('p4'))}, {BY_POKE})",
        "cosY": "cos(yaw)", "sinY": "sin(yaw)",
        # arms: bend a touch on landings (comp), straighten forward for the poke.
        "a1": f"({rA1} + comp * {math.radians(18)} + ({rE1} - {rA1}) * reach)",
        "a2": f"({rA2} + comp * {math.radians(22)} + ({rE2} - {rA2}) * reach)",
        # head: down-forward while hopping; lift over the jump; scan up/down while
        # raking; level for the poke; tip up to meet the camera at the end.
        "a3": f"multiIf(t < {T1}, {rA3}, "
              f"t < {T2}, {lerp(rA3, math.radians(95), sm('p2'))}, "
              f"t < {T3}, {math.radians(96)} + {math.radians(12)} * sin(2.0*{pi}*p3), "
              f"t < {T4}, {lerp(math.radians(96), math.radians(90), sm('p4'))}, "
              f"{math.radians(90)} - {math.radians(14)} * {sm('p5')})",
        "L1c": "3.6 * (1.0 + 0.12*air - 0.25*comp)",
        "L2c": "3.4 * (1.0 + 0.12*air - 0.25*comp)",
    })

# Derived linkage points (local u,w), valid for both static & animated poses.
DERIVED = [
    ("sinA1", "sin(a1)"), ("cosA1", "cos(a1)"),
    ("sinA2", "sin(a2)"), ("cosA2", "cos(a2)"),
    ("sinA3", "sin(a3)"), ("cosA3", "cos(a3)"),
    ("eu", "L1c * sinA1"),
    ("ew", f"{BASE_W} + L1c * cosA1"),
    ("hu", "eu + L2c * sinA2"),
    ("hw", "ew + L2c * cosA2"),
]

# ---- build the lamp as a list of world-space (x,y,z,r) SQL exprs ----------
def loc(u, w, r):
    """A linkage ball at local (u forward, w up) -> world tuple expr."""
    return f"(bx + ({u}) * cosY, by + ({u}) * sinY, bz + ({w}), {r})"

lamp = []
# Base: a ring of balls + a centre ball, a flat round foot on the floor.
NBASE = 7
RB = 1.7
for k in range(NBASE):
    ang = 2 * math.pi * k / NBASE
    ox, oy = round(RB * math.cos(ang), 4), round(RB * math.sin(ang), 4)
    lamp.append(f"(bx + {ox}, by + {oy}, bz + {BASE_R}, 0.8)")
lamp.append(f"(bx, by, bz + {BASE_R + 0.2}, 1.0)")

# Lower arm: base joint (0, BASE_W) -> elbow (eu, ew). Dense chain -> solid rod.
for f in (0.16, 0.32, 0.48, 0.64, 0.80, 0.95):
    lamp.append(loc(f"{f} * eu", f"{BASE_W} + {f} * (ew - {BASE_W})", 0.5))
lamp.append(loc("eu", "ew", 0.75))  # elbow

# Upper arm: elbow (eu, ew) -> head joint (hu, hw).
for f in (0.2, 0.4, 0.6, 0.8, 0.95):
    lamp.append(loc(f"eu + {f} * (hu - eu)", f"ew + {f} * (hw - ew)", 0.5))
lamp.append(loc("hu", "hw", 0.65))  # neck

# Shade: a flared cone of growing balls along the head direction (sinA3, cosA3).
SHADE = [(0.8, 0.55), (1.7, 0.85), (2.5, 1.1), (3.3, 1.4)]
for g, r in SHADE:
    lamp.append(loc(f"hu + {g} * sinA3", f"hw + {g} * cosA3", r))

# Bulb: a bright ball just inside the shade mouth -- and the scene's light.
GBULB = 2.9
BULB = loc(f"hu + {GBULB} * sinA3", f"hw + {GBULB} * cosA3", 0.85)
lamp.append(BULB)
# Light position = bulb centre (drop the radius component).
LIGHT_EXPR = f"(bx + (hu + {GBULB} * sinA3) * cosY, by + (hu + {GBULB} * sinA3) * sinY, bz + (hw + {GBULB} * cosA3))"

LAMP_ARR = "[" + ", ".join(lamp) + "]"

# ============================ scene / renderer ============================
STATIC_EYE = f"({EYE_X}, {EYE_Y}, {EYE_Z})"

ST = "Tuple(Tuple(Float64,Float64,Float64), Tuple(Float64,Float64,Float64), Float64, Tuple(Float64,Float64,Float64), Float64)"

def arr(rows):
    return "[" + ", ".join("'" + r + "'" for r in rows) + "]"

def lets(bindings, body):
    for name, expr in reversed(bindings):
        body = f"arrayMap({name} -> {body}, [{expr}])[1]"
    return body

# One full bounce. Spheres are now (x,y,z,r); `hc` is the hit sphere tuple.
_BIND = [
    ("o",   "s.1"),
    ("d",   "s.2"),
    ("thr", "s.3"),
    ("acc", "s.4"),
    ("hits",   "sphereHits(o, d)"),
    ("tP",     "planeT(o, d)"),
    ("tS",     "arrayMin(hits)"),
    ("hc",     "spheres[indexOf(hits, tS)]"),
    ("tHit",   "least(tS, tP)"),
    ("hp",     "va(o, vm(d, tHit))"),
    ("sn",     "vn(vs(hp, (hc.1, hc.2, hc.3)))"),
    ("isMirror", "(tS < tP) AND (tS < 1e8)"),
    ("isFloor",  "(tP <= tS) AND (tP < 1e8)"),
    ("isMiss",   "(tS >= 1e8) AND (tP >= 1e8)"),
    ("nrm",    "if(isFloor, (0.0, 0.0, 1.0), sn)"),
    ("shOrig", "va(hp, vm(nrm, eps * 2.0))"),
    ("rdir",   "vref(d, sn)"),
    ("ldir",   "vn(vs(lpos, hp))"),
    ("distL",  "L2Norm(vs(lpos, hp))"),
    ("shadowed", "occluded(shOrig, ldir, distL - 0.05)"),
    ("lit",    "if(shadowed, 0.0, 1.0)"),
    # how close to the lamp -- a bright pool right under it, falling off with distance
    ("att",    "1.0 / (1.0 + distL * distL * lightAtten)"),
    # is the hit sphere the bulb itself? (its centre IS the light position)
    ("isBulb", "L2Norm(vs((hc.1, hc.2, hc.3), lightPos)) < 1.2"),
    ("spec",   "pow(greatest(vd(ldir, rdir), 0.0), shininess) * lit * (1.0 + 2.5 * att)"),
    ("lambert","greatest(vd(ldir, (0.0, 0.0, 1.0)), 0.0) * lit"),
    ("fog",    "least(1.0, greatest(0.0, (tHit - fogStart) / fogRange))"),
    # base lit floor, plus an additive warm pool cast by the lamp (respects shadow + fog)
    ("floorCol", "va(va(vm(vm(floorPB, floorAmb + floorDiff * lambert), 1.0 - fog), vm(hazeColor, fog)), "
                 "vm(warmLight, poolGain * att * lit * (1.0 - fog)))"),
]
_BODY = """(
        if(isMirror, shOrig, o),
        if(isMirror, rdir, d),
        if(isMirror, thr * reflect_k, thr),
        va(acc, va(if(isMirror, va(vm(specColor, thr * spec),
                                   if(isBulb, vm(warmLight, thr * bulbEmit), (0.0, 0.0, 0.0))), (0.0, 0.0, 0.0)),
                   va(if(isFloor, vm(floorCol, thr), (0.0, 0.0, 0.0)),
                      if(isMiss, vm(sky(d), thr), (0.0, 0.0, 0.0))))),
        if(isMirror, 1.0, 0.0))"""
ONE_BOUNCE = lets(_BIND, _BODY)

# Pose/derived quantities are frame-constant (same for every pixel), so each is
# emitted as a scalar subquery -- evaluated once and referenced as a constant.
# (Plain WITH bindings are textual macros that re-expand at every reference; the
# lamp array references each pose scalar dozens of times, which would otherwise
# blow the query tree past CH's size limit.)
# assumeNotNull strips the Nullable that scalar subqueries return (else the
# Nullable propagates into the ray-state tuple and breaks the fold's type).
POSE_SQL = "".join(f"    assumeNotNull((SELECT {expr})) AS {name},\n" for name, expr in POSE.items())
DERIVED_SQL = "".join(f"    assumeNotNull((SELECT {expr})) AS {name},\n" for name, expr in DERIVED)
ST4 = "Array(Tuple(Float64, Float64, Float64, Float64))"

PRELUDE = f"""WITH
    {arr(BANNER)} AS banner,
    {bannerW} AS bannerW, {bannerH} AS bannerH,
    1.0 AS spacing, 0.92 AS radius, 3.0 AS z0,
    {BASE_W} AS baseW,
    {TARGET_PT}    AS target,
    {{FRAME:UInt32}}::Float64 / {{FRAMES:UInt32}}::Float64 AS t,
    /* ---- per-frame lamp pose, computed in SQL ---- */
{POSE_SQL}{DERIVED_SQL}    {STATIC_EYE} AS eye,
    {FOV_DEG} AS fovDeg,
    getSetting('output_format_image_width')::UInt64  AS W,
    getSetting('output_format_image_height')::UInt64 AS H,
    W::Float64 AS imgW, H::Float64 AS imgH,
    {DEPTH} AS maxDepth,
    {LIGHT_EXPR}  AS lightPos,
    3.0 AS lightR,
    (0.0026, 0.0026, 0.0023) AS skyColor,    /* ClickHouse grey #121211 backdrop */
    (0.0026, 0.0026, 0.0023) AS hazeColor,   /* = sky, so the floor fades into it */
    35.0 AS fogStart, 120.0 AS fogRange,
    (0.010, 0.010, 0.010)  AS floorPB,       /* near-black floor -> chrome + pool read */
    0.55 AS floorAmb, 0.45 AS floorDiff,
    (1.0, 1.0, 0.45)    AS specColor,        /* yellow highlights = lamp light */
    60.0 AS shininess, 0.72 AS reflect_k,
    /* ---- the lamp's own glow, so its light is clearly visible ---- */
    (1.0, 1.0, 0.42)    AS warmLight,        /* lamp light: ClickHouse yellow #FAFF6A */
    1.8  AS poolGain,                        /* yellow pool cast on the floor */
    4.0  AS bulbEmit,                        /* how bright the bulb itself glows */
    0.006 AS lightAtten,                     /* distance falloff of the lamp light */
    1.15 AS exposure, 2.2 AS gamma, 0.002 AS eps,

    ((a, b) -> tuplePlus(a, b))                                   AS va,
    ((a, b) -> tupleMinus(a, b))                                  AS vs,
    ((a, s) -> tupleMultiplyByNumber(a, s))                       AS vm,
    ((a, b) -> dotProduct(a, b))                                  AS vd,
    ((a)    -> L2Normalize(a))                                    AS vn,
    ((a, b) -> (a.2*b.3 - a.3*b.2, a.3*b.1 - a.1*b.3, a.1*b.2 - a.2*b.1)) AS vc,
    ((d, n) -> tupleMinus(d, tupleMultiplyByNumber(n, 2.0 * dotProduct(d, n)))) AS vref,

    /* letters: uniform-radius chrome balls, fixed in place (no squash now). */
    (SELECT arrayMap(c -> (
        c.1 * spacing,
        0.0,
        z0 + (toFloat64(bannerH - 1) - c.2) * spacing,
        radius),
      arrayFilter(c -> substring(banner[c.2 + 1], c.1 + 1, 1) = '#',
        arrayFlatten(arrayMap(gy -> arrayMap(gx -> (gx, gy), range(bannerW)), range(bannerH))))))::{ST4} AS letterSpheres,
    (SELECT {LAMP_ARR})::{ST4} AS lampSpheres,
    arrayConcat(letterSpheres, lampSpheres) AS spheres,

    L2Normalize(tupleMinus(target, eye))                          AS camFwd,
    L2Normalize(vc(L2Normalize(tupleMinus(target, eye)), (0.0, 0.0, 1.0))) AS camRight,
    vc(camRight, camFwd)                                          AS camUp,
    tan(fovDeg * 0.5 * pi() / 180.0)                              AS tanHalf,
    imgW / imgH AS aspect,

    /* nearest sphere hit for a ray vs a sphere of radius `rad` centred at origin
       of the translated point p; 1e9 = miss. */
    ((p, d, rad) -> arrayMap(b -> if(
        b - (dotProduct(p, p) - rad*rad) > 0.0
        AND -dotProduct(p, d) - sqrt(greatest(b - (dotProduct(p, p) - rad*rad), 0.0)) > eps,
        -dotProduct(p, d) - sqrt(greatest(b - (dotProduct(p, p) - rad*rad), 0.0)),
        1e9), [dotProduct(p, d) * dotProduct(p, d)])[1]) AS sphTnear,
    ((o, d) -> arrayMap(c -> sphTnear(vs(o, (c.1, c.2, c.3)), d, c.4), spheres)) AS sphereHits,
    ((o, d) -> if(d.3 < -eps AND o.3 > 0.0, -o.3 / d.3, 1e9))     AS planeT,
    ((o, d, maxd) -> arrayExists(c -> sphTnear(vs(o, (c.1, c.2, c.3)), d, c.4) < maxd, spheres)) AS occluded,
    ((d) -> skyColor) AS sky,                /* flat ClickHouse grey, no gradient */
    ((a, b, c) -> (cityHash64(a, b, c) % 1048576) / 1048576.0)    AS rnd,

    ((s, lpos) -> {ONE_BOUNCE}) AS oneBounce
"""

QUERY = PRELUDE + f"""
SELECT
    clamp(pow(greatest(avg(col.1), 0.0) * exposure, 1.0 / gamma), 0.0, 1.0) AS r,
    clamp(pow(greatest(avg(col.2), 0.0) * exposure, 1.0 / gamma), 0.0, 1.0) AS g,
    clamp(pow(greatest(avg(col.3), 0.0) * exposure, 1.0 / gamma), 0.0, 1.0) AS b,
    pixel % W      AS x,
    intDiv(pixel, W) AS y
FROM (
  SELECT pixel, va(st.4, if(st.5 > 0.5, vm(sky(st.2), st.3), (0.0,0.0,0.0))) AS col
  FROM (
    SELECT pixel,
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
         optimize_and_compare_chain = 0,
         max_expanded_ast_elements = 20000000
FORMAT PNG
"""

sys.stdout.write(QUERY)
