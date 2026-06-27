# Cross-engine portability findings

A write-up of what happened when we tried to run the combined **ClickHouse-over-terrain**
ray tracer — the scene in [`../queries/clickhouse_terrain.sql`](../queries/clickhouse_terrain.sql),
shrunk to a small deterministic benchmark — on engines other than ClickHouse.

> **TL;DR.** The renderer is a single SQL query built from ~30 nested lambdas and 4
> `arrayFold` loops, several of which are *ray-marches* (iterating a signed-distance field
> along the ray). ClickHouse's analyzer compiles and runs it. DuckDB — the only other engine
> here with SQL lambdas — translates faithfully but its **planner cannot compile a query that
> contains more than one ray-march**; it is superlinear (effectively exponential) in the
> number of marches. Postgres / CedarDB / MySQL have no lambdas at all and need a
> recursive-CTE / procedural reformulation. The headline result: *ClickHouse's analyzer
> digests a renderer that DuckDB's planner chokes on.*

## What we set out to measure

Port the **latest combined query** to DuckDB, CedarDB, Postgres and MySQL; verify each
renders the *same* image; measure how long each takes. Start at low resolution so slow
engines still finish.

To make the comparison fair and the images bit-comparable, the benchmark scene is:

- **192 × 90**, 1 centred sample per pixel, bounce depth 2 — deliberately small.
- **Deterministic**: no anti-alias jitter and no soft-shadow jitter (the light is a fixed
  point), so every engine should produce identical pixels up to floating-point rounding.
- **Portable hash**: the terrain noise uses a hand-rolled two-round integer LCG hash whose
  intermediates stay below ~9.2 × 10¹⁸ — it never overflows signed 64-bit and never errors in
  Postgres/MySQL, so the terrain is identical across engines (unlike `cityHash64`).
- **Uniform output**: every engine emits one row per pixel, `idx \t R \t G \t B` (0–255,
  scanline order). [`tools.py`](tools.py) renders that dump to PNG and diffs two dumps for a
  pass/fail correctness verdict.

Reference dumps (produced by ClickHouse):

| file | resolution | rows | Σ R / Σ G / Σ B |
|---|---|---:|---|
| `out/clickhouse.tsv` | 192 × 90 | 17 280 | 3 487 995 / 4 004 267 / 2 990 003 |
| `out/ch48.tsv` | 48 × 24 | 1 152 | 231 480 / 267 081 / 197 774 |

## Why this query is hard for a query compiler

The generated ClickHouse query [`queries/clickhouse.sql`](queries/clickhouse.sql) is only
**159 lines / ~19 KB**, but that text is dense: it expands to **173 lambda (`->`) terms** and
**4 `arrayFold` loops**. The structure is:

- vector math (add/sub/scale/dot/normalise/reflect/mix) as nested lambda calls on
  `Tuple(Float64, Float64, Float64)`;
- CSG primitives — ray/box, capsule (the letter strokes), oriented box, ring, **torus**
  (ray-marched signed-distance field), sphere, sphere-sphere planet;
- a **ray-marched Perlin/value-noise fBm terrain** (skip-empty-air + linear crossing
  interpolation);
- the whole thing wrapped in a bounce loop (`arrayFold`) for reflections, plus shadow rays
  that re-march the terrain and the tori.

The expensive part for a compiler is the **ray-marches**: each is a fixed-iteration loop
(`arrayFold` in ClickHouse, `list_reduce` in DuckDB) whose body re-evaluates the
signed-distance field. A single bounce contains ~4 of them (primary terrain, primary tori,
shadow terrain, shadow tori); depth-2 means ~8 marches in the fully-expanded query.

ClickHouse's analyzer represents these as bounded loop nodes and analyses the body **once**;
the cost is roughly linear in the program text, which is why its time barely changes with
resolution (see below). An engine that **inlines/expands** each higher-order call instead pays
a cost that multiplies per nested march — and that is exactly where DuckDB falls over.

## Per-engine results

### ClickHouse — ✅ compiles and runs; analysis-bound

Runs as written. The dominant cost is **query analysis, not pixel compute**:

| resolution | wall time |
|---|---|
| 16 × 16 | ≈ 50 s |
| 192 × 90 | ≈ 55–60 s |

A 144× increase in pixels adds only ~10–20 % wall time — almost the entire cost is the
fixed analysis of the deeply-nested lambda tree. At low resolution the ClickHouse number is
essentially a *compile* cost, not ray-tracing throughput. (This is itself worth noting: the
scene is a stress test of the analyzer, not of the execution engine.)

### DuckDB — ❌ faithful port, but the planner can't compile a multi-march query

[`gen_duckdb_bench.py`](gen_duckdb_bench.py) translates the scene faithfully:
tuples → `LIST`/`STRUCT`, lambdas → `CREATE MACRO` (call-by-name, like ClickHouse's
WITH-lambda aliases), `arrayFold` → `list_reduce`, plus the portable hash and
`SET lambda_syntax='ENABLE_SINGLE_ARROW'`. The **individual pieces run and match**:

| piece | time | note |
|---|---|---|
| `terrH`, `toriSDF` (the SDFs) | instant | scalar, correct |
| `marchTorus` (one ray) | ~0.4 s | |
| `marchTerr` (one ray) | ~6.7 s | ~6.5 s bind + ~17 ms/ray, so it vectorises |

But assembling them into the renderer does **not** bind/plan. Three independent formulations,
all fail — and the failure is in *planning*, not execution or memory:

| formulation | result |
|---|---|
| one monolithic `oneBounce` expression | runs > 110 s at ~14 GB RSS, never returns (binder blowup) |
| `marchTerr` **+** `marchTorus` in **one** query | 2 m 30 s timeout |
| `EXPLAIN` of a single bounce (planning only, no execution) | 4 m 40 s timeout |
| staged `MATERIALIZED`-CTE bounce, DEPTH = 1, 16 × 16 | 4 m 41 s timeout (steady ~1 GB — *not* memory-bound) |

The staged version used DuckDB's by-value **lateral column aliasing** (verified: an alias
referenced 4× binds once) so memory stayed ~1 GB instead of 14 GB — yet it still timed out in
**planning**. The decisive measurement is the second row: **one march binds in 6.7 s, two
marches in one query time out**. DuckDB's optimizer is therefore **superlinear — effectively
exponential — in the number of macro-expanded `list_reduce` marches in a single query**.

The combined scene needs ~8 marches, so DuckDB cannot plan it in any single-query formulation
(monolith, staged-flat, and per-march CTEs are all planned together as one query). The only
remaining DuckDB avenue is to split the renderer into ~20 *separate* `CREATE TABLE … AS`
statements (≤ 1 march each, materialised to real tables between them) — possible, but
non-idiomatic and with unknown execution speed. We did **not** pursue it.

> Note the contrast: ClickHouse's analyzer *does* compile the equivalent monolith (~50 s),
> and the staged DuckDB query is no larger in memory — the difference is purely how each
> engine's planner handles deeply-nested higher-order expressions.

### Postgres / CedarDB / MySQL — no SQL lambdas at all

These dialects have **no lambdas or higher-order array functions**, so even a single inner
march cannot be written as an expression the way it can in ClickHouse/DuckDB. A faithful port
must reformulate every loop (the bounce loop *and* each ray-march) as a **recursive CTE**, or
move the logic into procedural code (PL/pgSQL functions, MySQL stored routines). That is a
strictly larger effort than the DuckDB port — and DuckDB, which *does* have lambdas, already
could not compile the result.

**CedarDB** is the most promising of the three: it speaks the Postgres dialect but has a much
more advanced query planner/optimizer, so a recursive-CTE reformulation has a real chance of
compiling where DuckDB's did not. That is the next experiment (see below).

## Conclusion

The combined ClickHouse ray tracer is **portable as a faithful translation** (the math, the
hash, the SDFs all reproduce correctly), but it is **not portable as a single SQL query** to
engines whose planners expand higher-order calls instead of analysing bounded loops in place.
On the engine most likely to succeed — DuckDB, the only other one with SQL lambdas — the
planner is superlinear in the number of ray-marches and cannot compile more than one.

This makes the renderer an unusually sharp benchmark of **query-compiler architecture** rather
than execution throughput: the question is not "how fast does each engine trace rays" but
"can each engine's planner even compile a program with ~8 nested bounded loops in one query."

## Open follow-ups

- **CedarDB via recursive CTE** — in progress. Advanced planner, Postgres-compatible;
  reformulate the bounce loop and marches as recursive CTEs.
- **A portable single-march scene** — a terrain-only variant (one `marchTerr`, no
  letters/tori/planet, no reflections) is within reach for every engine (DuckDB handles one
  march in 6.7 s) and would yield real apples-to-apples execution numbers.
- **DuckDB separate-statement workaround** — split into ~20 `CREATE TABLE … AS` statements,
  ≤ 1 march each, to sidestep the planner blowup for the full scene.

## Reproducing

```bash
# ClickHouse reference (pixel dump + image)
python3 gen_clickhouse_bench.py 192 90 2 data > queries/clickhouse.sql
clickhouse local --queries-file queries/clickhouse.sql > out/clickhouse.tsv
python3 tools.py render out/clickhouse.tsv 192 90 out/clickhouse.png

# Compare another engine's dump against the reference
python3 tools.py compare out/clickhouse.tsv out/<engine>.tsv
```
