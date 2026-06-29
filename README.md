# RayTracer — a ray tracer in ClickHouse SQL

![ClickHouse over a Perlin-noise terrain](images/clickhouse_over_terrain.png)

A path tracer written entirely as **ClickHouse SQL queries**, rendering straight to a PNG
via ClickHouse's `PNG` output format. No UDFs and no external code — a single `SELECT`
computes every pixel.

It renders the word **ClickHouse** as glassy, chrome lettering — in the spirit of Andrew
Kensler's famous Pixar business-card ray tracer — and, in the scene above, sets it floating
over a procedurally generated landscape, reflecting the terrain and casting shadows on the hills.

See also:
- [NoiSQL — Generating Music With SQL Queries](https://github.com/ClickHouse/NoiSQL)
- [SQL Mandelbrot Benchmark](https://github.com/ClickHouse/sql-mandelbrot-benchmark)
- [Click-V: A RISC-V emulator built with ClickHouse SQL](https://github.com/SpencerTorres/Click-V)
- [DOOMHouse is a "Doom-like" game engine that renders the 3D graphics entirely in ClickHouse SQL](https://github.com/arniwesth/DoomHouse)

## How it works

The whole renderer lives in one query:

- **Pixels are rows.** `numbers_mt(width * height * samples)` produces one row per
  `(pixel, sample)`; samples are averaged with `GROUP BY pixel`, and the output columns
  `r, g, b` (in `[0, 1]`) plus explicit `x, y` coordinate columns (`pixel % width`,
  `intDiv(pixel, width)`) are written to the `PNG` output format. The explicit coordinates let
  the writer place each pixel by its position, so the rows need no `ORDER BY` and the heavy
  per-pixel work stays parallel across all cores.
- **3D math on tuples.** Vectors are `Tuple(Float64, Float64, Float64)`; `dotProduct`,
  `L2Normalize`, `tuplePlus`, `tupleMultiplyByNumber`, … do the linear algebra, wrapped in
  short lambda aliases (`va`, `vs`, `vm`, `vd`, `vn`, `vc`, `vref`).
- **The bounce loop is `arrayFold`.** Every ray is advanced exactly one mirror bounce per
  fold step over `range(maxDepth)` — a loop *inside each row*, so rows stay independent and
  the render parallelizes across all CPU cores. (The first version used a `WITH RECURSIVE`
  CTE instead — see the queries below.)
- **`let`-bindings via `arrayMap`.** ClickHouse `WITH` lambdas are call-by-name, so passing a
  value as a parameter re-expands the expression and blows up the query tree. Intermediates
  are therefore bound *by value* with `arrayMap(x -> body, [expr])[1]`, a one-element-array
  "let".

### Geometry (Constructive Solid Geometry)

- **Cylinders** — round rods with flat caps for the straight strokes (`l`, `i`, `k`, `H`,
  `u`, the bar of `e`).
- **Tori** — the round letters (`C`, `c`, `o`, `u`, `s`, `e`), ray-**marched** through their
  signed-distance field; the openings of `C`/`c`/`s`/`e` are a box subtracted from the ring.
- **Spheres** — the dot on `i`, plus a chrome "planet" that is a sphere **minus** a sphere.
- **Oriented boxes / parallelepipeds** — available for flat-faced strokes.

So the scene exercises boxes, cylinders, tori and spheres, with CSG **union**, **difference**
(the planet and the letter openings) and a **ray-marched distance field** (the tori).

### Terrain

A height field `z = amp · fBm(x, y)`, where fBm sums several octaves of lattice value-noise.
Camera rays are ray-marched against it — the march skips the empty air (it starts where the
ray first drops to the terrain's maximum height) and linearly interpolates the surface
crossing, so it is both fast and free of step-banding. It is shaded with a height color ramp
(water → sand → grass → rock → snow), a warm sun plus cool sky-ambient model, marched shadows
(terrain self-shadow *and* the letters' cast shadows), and distance fog into the sky.

## Gallery

**ClickBulb** — a desk lamp built entirely from spheres hops in, leaps behind the banner, rakes
its light through the letter gaps, then pokes its head through to peer at you. Every frame is the
same ClickHouse SQL query, run once per frame ([full-quality video](images/clickbulb_hd.mp4)).

[![ClickBulb — a sphere-built desk lamp animation](images/clickbulb.gif)](images/clickbulb_hd.mp4)

| | |
|---|---|
| ![Pixar homage](images/pixar_homage.png) | ![CSG primitives](images/csg_primitives.png) |
| **Pixar homage** — the letters as a union of sphere primitives, chrome over a checkerboard. | **CSG primitives** — the letters carved from cylinders, tori and spheres. |
| ![Perlin terrain](images/perlin_terrain.png) | ![ClickHouse over terrain](images/clickhouse_over_terrain.png) |
| **Perlin terrain** — a standalone ray-marched height field. | **Combined** — ClickHouse over the terrain (the hero image above). |

## Running

Every file in [`queries/`](queries) is complete and self-contained, and **parameterized**: the
image size comes from ClickHouse's image-output settings (read in SQL with `getSetting`) and the
samples per pixel from a `{SAMPLES:UInt32}` query parameter — one query renders any resolution.
Render one with:

```bash
clickhouse local --output_format_image_width 2560 --output_format_image_height 1200 \
                 --param_SAMPLES 8 --queries-file queries/clickhouse_terrain.sql > out.png
```

| Query | Scene | Resolution |
|---|---|---|
| [`clickhouse_raytracer.sql`](queries/clickhouse_raytracer.sql) | Pixar homage, `WITH RECURSIVE` bounce loop | 640 × 256 |
| [`clickhouse_raytracer_loop.sql`](queries/clickhouse_raytracer_loop.sql) | Same scene, `arrayFold` loop (parallel, faster) | 640 × 256 |
| [`clickhouse_raytracer_primitives.sql`](queries/clickhouse_raytracer_primitives.sql) | Letters carved from CSG primitives | 1280 × 512 |
| [`terrain.sql`](queries/terrain.sql) | Perlin-noise terrain | 896 × 504 |
| [`clickhouse_terrain.sql`](queries/clickhouse_terrain.sql) | ClickHouse over the terrain (hero image) | 2560 × 1200 |

The queries are emitted by the Python generators in [`generators/`](generators); the scene and
bounce depth are baked at generation time, while image size and samples per pixel stay runtime
parameters of the emitted query. For example, to re-create the hero image:

```bash
python3 generators/gen_combined.py 2560 1200 8 2 > scene.sql   # depth 2; W/H/samples are runtime
clickhouse local --output_format_image_width 2560 --output_format_image_height 1200 \
                 --param_SAMPLES 8 --queries-file scene.sql > scene.png
```

### Rendering arbitrary text

The sphere-banner generators ([`gen.py`](generators/gen.py) and the faster
[`gen_fold.py`](generators/gen_fold.py)) take an optional 5th argument: the text to render. It is
laid out from the 7-row bitmap font in [`generators/font.py`](generators/font.py) (uppercase A–Z,
digits, and common punctuation; the original mixed-case "ClickHouse" glyphs are preserved, so the
default render is unchanged), and the camera, light, and chrome sphere are recentered on the
banner automatically.

```bash
python3 generators/gen_fold.py 640 256 16 4 "HELLO SQL" > hello.sql
clickhouse local --output_format_image_width 640 --output_format_image_height 256 \
                 --param_SAMPLES 16 --queries-file hello.sql > hello.png
```

Preview a banner as ASCII art without rendering: `python3 generators/font.py "HELLO SQL"`.

## Trying with other databases

- 🐛 **CedarDB**: works, but 33 times slower and with bugs: https://github.com/cedardb/issues/issues/71
- ☠️ **DuckDB**: does not work, tried multiple ways - with arrays and recursive CTE, but it can't process even the smallest resolution image.

See the [benchmark](/benchmark).

## Credits

Inspired by Andrew Kensler's *business-card ray tracer* and Paul Heckbert's minimal ray
tracers — re-imagined as pure ClickHouse SQL.

## License

[Creative Commons Attribution-NonCommercial-ShareAlike 4.0](LICENSE), the same license as
[ClickBench](https://github.com/ClickHouse/ClickBench).
