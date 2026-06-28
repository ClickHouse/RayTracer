#!/usr/bin/env python3
"""A Perlin/value-noise terrain rendered in one ClickHouse SQL query.

The terrain is a height field  z = amp * fBm(x, y)  (fBm = sum of octaves of
lattice value-noise). Each pixel's ray is ray-marched against the height field
(step until the ray dips below the surface); the surface normal comes from the
height gradient. Shading = a height color ramp * (sky ambient + sun diffuse),
with a marched shadow ray toward the sun and distance fog into the sky.

Pixels stream to ClickHouse's PNG output format."""
import sys

W       = int(sys.argv[1]) if len(sys.argv) > 1 else 320
H       = int(sys.argv[2]) if len(sys.argv) > 2 else 180
SAMPLES = int(sys.argv[3]) if len(sys.argv) > 3 else 1

def lets(bindings, body):
    for name, expr in reversed(bindings):
        body = f"arrayMap({name} -> {body}, [{expr}])[1]"
    return body

# value-noise of one octave; each lattice hash is evaluated exactly once
VNOISE_B = [
    ("ix","floor(x)"), ("iy","floor(y)"),
    ("fx","x - ix"), ("fy","y - iy"),
    ("u","fx*fx*fx*(fx*(fx*6.0-15.0)+10.0)"),
    ("v","fy*fy*fy*(fy*(fy*6.0-15.0)+10.0)"),
    ("a","(cityHash64(toInt64(ix),   toInt64(iy))   % 4194304) / 4194304.0"),
    ("b","(cityHash64(toInt64(ix)+1, toInt64(iy))   % 4194304) / 4194304.0"),
    ("c","(cityHash64(toInt64(ix),   toInt64(iy)+1) % 4194304) / 4194304.0"),
    ("d","(cityHash64(toInt64(ix)+1, toInt64(iy)+1) % 4194304) / 4194304.0"),
]
VNOISE = lets(VNOISE_B, "(a + (b-a)*u) + ((c + (d-c)*u) - (a + (b-a)*u)) * v")

# 4-octave fBm in [0,1): freq doubles, amplitude halves, normalized by 1/(1-2^-4)
FBM = ("(vnoise(x, y)*0.5 + vnoise(x*2.0, y*2.0)*0.25 "
       " + vnoise(x*4.0, y*4.0)*0.125 + vnoise(x*8.0, y*8.0)*0.0625) / 0.9375")

QUERY = f"""WITH
    getSetting('output_format_image_width')::UInt64  AS W,
    getSetting('output_format_image_height')::UInt64 AS H,
    W::Float64 AS imgW, H::Float64 AS imgH,
    (0.0, -9.0, 4.2)  AS eye,
    (0.0,  9.0, 1.3)  AS target,
    52.0 AS fovDeg,
    L2Normalize((0.55, 0.45, 0.70))  AS sun,
    (1.05, 0.96, 0.80)  AS sunCol,
    7.0  AS amp,          /* terrain height scale */
    0.085 AS nscale,      /* horizontal noise frequency */
    0.6  AS waterLevel,
    90.0 AS fogDist,
    (0.62, 0.74, 0.92)  AS skyHorizon,
    (0.30, 0.50, 0.85)  AS skyTop,

    ((a, b) -> tuplePlus(a, b))               AS va,
    ((a, b) -> tupleMinus(a, b))              AS vs,
    ((a, s) -> tupleMultiplyByNumber(a, s))   AS vm,
    ((a, b) -> dotProduct(a, b))              AS vd,
    ((a)    -> L2Normalize(a))                AS vn,
    ((a, b) -> (a.2*b.3 - a.3*b.2, a.3*b.1 - a.1*b.3, a.1*b.2 - a.2*b.1)) AS vc,
    ((a, b) -> tupleMultiply(a, b))           AS vmul3,
    ((a, b, t) -> tuplePlus(a, tupleMultiplyByNumber(tupleMinus(b, a), t))) AS mix,
    ((lo, hi, t) -> greatest(lo, least(hi, t))) AS clamp3,

    L2Normalize(tupleMinus(target, eye))                          AS camFwd,
    L2Normalize(vc(L2Normalize(tupleMinus(target, eye)), (0.0,0.0,1.0))) AS camRight,
    vc(camRight, camFwd)                                          AS camUp,
    tan(fovDeg*0.5*pi()/180.0)                                    AS tanHalf,
    imgW/imgH                                                     AS aspect,

    /* ---- the noise / height field ---- */
    ((x, y) -> {VNOISE})  AS vnoise,
    ((x, y) -> {FBM})     AS fbm,
    ((x, y) -> amp * fbm(x*nscale, y*nscale)) AS height,
    /* surface normal from the height gradient (z is up) */
    ((x, y) -> vn(((height(x-0.15, y) - height(x+0.15, y)) / 0.3,
                   (height(x, y-0.15) - height(x, y+0.15)) / 0.3,
                   1.0))) AS terrainN,
    /* color by elevation: water -> sand -> grass -> rock -> snow */
    ((h) -> mix(mix(mix(mix((0.14,0.28,0.50), (0.78,0.72,0.46), clamp3(0.0,1.0,(h-waterLevel)/0.4)),
                        (0.24,0.44,0.17), clamp3(0.0,1.0,(h-1.3)/1.1)),
                    (0.40,0.35,0.31), clamp3(0.0,1.0,(h-3.4)/1.4)),
                (0.93,0.94,0.98), clamp3(0.0,1.0,(h-5.0)/1.0))) AS terrainCol,
    /* sky gradient for escaped rays */
    ((d) -> mix(skyHorizon, skyTop, clamp3(0.0,1.0,d.3*1.6))) AS sky,

    /* ---- ray-march the height field; returns hit distance or 1e9 ---- */
    ((O, D) -> arrayMap(s -> s.2,
        [arrayFold((s, i) -> if(s.2 < 1e8, s,
             if(O.3 + s.1*D.3 < height(O.1 + s.1*D.1, O.2 + s.1*D.2),
                (s.1, s.1),
                (s.1 + greatest(0.04, s.1*0.035), 1e9))),
           range(170), (0.05, 1e9))])[1]) AS march,
    /* shadow ray toward the sun: is the terrain in the way? */
    ((P) -> arrayFold((blk, i) -> blk OR
              (P.3 + (0.3 + i*0.45)*sun.3 < height(P.1 + (0.3 + i*0.45)*sun.1, P.2 + (0.3 + i*0.45)*sun.2)),
            range(48), 0) > 0) AS shadowed

SELECT
    clamp(pow(greatest(avg(col.1), 0.0), 1.0/2.2), 0.0, 1.0) AS r,
    clamp(pow(greatest(avg(col.2), 0.0), 1.0/2.2), 0.0, 1.0) AS g,
    clamp(pow(greatest(avg(col.3), 0.0), 1.0/2.2), 0.0, 1.0) AS b,
    pixel % W      AS x,                          /* explicit PNG coordinates: no ORDER BY needed */
    intDiv(pixel, W) AS y
FROM (
  SELECT pixel,
    {lets([
        ("t","march(O, D)"),
        ("hp","va(O, vm(D, t))"),
        ("hgt","height(hp.1, hp.2)"),
        ("nrm","terrainN(hp.1, hp.2)"),
        ("lit","greatest(vd(nrm, sun), 0.0) * if(shadowed(va(hp, vm(nrm, 0.08))), 0.0, 1.0)"),
        # incoming light = cool sky ambient (from above) + warm directional sun
        ("light","va(vm((0.42,0.54,0.80), 0.30 + 0.25*greatest(nrm.3,0.0)), vm(sunCol, 1.5*lit))"),
        ("ground","vmul3(terrainCol(hgt), light)"),
        ("fog","greatest(0.0, least(1.0, t/fogDist))"),
    ],
    "if(t >= 1e8, sky(D), mix(ground, skyHorizon, fog))")} AS col
  FROM (
    SELECT
      intDiv(number, {{SAMPLES:UInt32}}) AS pixel,
      number % {{SAMPLES:UInt32}} AS sample,
      eye AS O,
      vn(va(camFwd, va(vm(camRight, (((pixel % W) + (cityHash64(pixel,sample,1)%1024)/1024.0) / imgW * 2.0 - 1.0) * aspect * tanHalf),
                       vm(camUp,    (1.0 - (intDiv(pixel, W) + (cityHash64(pixel,sample,2)%1024)/1024.0) / imgH * 2.0) * tanHalf)))) AS D
    FROM numbers_mt(W * H * {{SAMPLES:UInt32}})
  )
)
GROUP BY pixel
SETTINGS max_block_size = 2048,
         optimize_and_compare_chain = 0
FORMAT PNG
"""
sys.stdout.write(QUERY)
