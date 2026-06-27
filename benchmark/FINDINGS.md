# Cross-engine portability findings

A write-up of what happened when we tried to run the combined **ClickHouse-over-terrain**
ray tracer — the scene in [`../queries/clickhouse_terrain.sql`](../queries/clickhouse_terrain.sql),
shrunk to a small deterministic benchmark — on engines other than ClickHouse.

> **TL;DR.** The renderer is a single SQL query built from ~30 nested lambdas and 4
> `arrayFold` loops, several of which are *ray-marches* (iterating a signed-distance field
> along the ray). **ClickHouse** compiles and runs it (analysis-bound, ~54 s at 192 × 90).
> **DuckDB** — the only other engine here with SQL lambdas — translates faithfully but its
> **planner cannot compile a query with more than one ray-march** (superlinear, effectively
> exponential, in the number of marches). **CedarDB** has no lambdas, so it is re-expressed
> set-based with the marches as **recursive CTEs** — and its planner compiles *and* runs the
> full six-march scene in ~4.3 s, matching the reference image. The headline result: *the
> ray-march is fatal to DuckDB as an expression but cheap to CedarDB as a relation* — how an
> engine represents the loop decides whether the renderer compiles at all.

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

### CedarDB — ✅ compiles, runs, and matches — via recursive CTEs

CedarDB also has no SQL lambdas, but it speaks the PostgreSQL dialect and has a much more
advanced planner, so the port takes a completely different shape — *set-based and
recursive-CTE driven* rather than expression driven:

| ClickHouse / DuckDB | CedarDB |
|---|---|
| tuple / `LIST` | `double precision[]` (1-indexed) |
| lambda / `MACRO` | `CREATE FUNCTION … LANGUAGE sql` (expression body) |
| `arrayFold` ray-march | `WITH RECURSIVE` — all rays advance in lockstep |
| `arrayFold` bounce loop | unrolled: one march pipeline per depth |
| geometry list + `list_min` | rows (`VALUES`) + window `min` |
| nested intersection expr | `LATERAL` "let" chains in the main query |

The depth-2 scene therefore carries **six recursive ray-marches** in one query — terrain and
tori, each for the primary ray and the shadow ray, across two bounces — plus the analytic
letter cylinders, the i-dot sphere, and the planet. CedarDB's planner compiles and runs the
whole thing without complaint.

This is the crisp contrast with DuckDB. A recursive CTE is a **relation**: each step evaluates
its body once per (ray, step) *row*, so the per-step body stays bounded and the number of
marches in the query adds rows, not exponential expression size. DuckDB's `list_reduce` march
is an **expression**, and nesting several of them multiplies the expression the planner must
analyse — which is why two marches already time it out. Same algorithm, opposite outcome,
because of how each engine represents the loop.

**Correctness.** The CedarDB render matches the ClickHouse reference: per-channel sums agree to
within 0.1 %, the mean per-channel difference is ≈ 1.0 / 255, and the two 192 × 90 images are
visually indistinguishable. About 6 % of pixels differ by more than ±4; these are silhouette
and shadow-boundary pixels — the inherent sub-pixel disagreement between two independent ray
tracers evaluating the marches in different float order, with no anti-aliasing to hide it.

**Speed.** Depth 2, on the same machine, at two resolutions:

| engine | 192 × 90 (17 k px) | 2560 × 1200 (3.07 M px) | ~µs / pixel at full res |
|---|---:|---:|---:|
| ClickHouse (`arrayFold` + lambdas) | 54.4 s | **708 s** (11 m 48 s) | ≈ 214 (after ~50 s analysis) |
| CedarDB (recursive CTEs) | 4.3 s | **580 s** (9 m 40 s) | ≈ 189 |
| DuckDB | cannot compile | cannot compile | — |

The two resolutions measure different things. At **192 × 90** CedarDB looks ~12× faster, but
that gap is almost all ClickHouse's *fixed* lambda-tree analysis cost (~50 s, essentially
resolution-independent) — not ray-tracing throughput. At **2560 × 1200** the work is
3.07 M pixels of actual compute, the fixed cost washes out, and the gap collapses to **~1.2×**
(≈ 214 µs/pixel for ClickHouse after subtracting analysis, vs ≈ 189 µs/pixel for CedarDB).

So the honest takeaway is *not* "CedarDB beats ClickHouse at ray tracing" — on raw per-pixel
throughput they are close. It is: (1) CedarDB *compiles* the scene that DuckDB cannot, and
(2) its recursive-CTE formulation carries no large fixed analysis cost, so it wins decisively
at small sizes and modestly at large ones. A recursive-CTE *ClickHouse* query would likely
close most of the remaining gap.

**One genuine CedarDB engine bug** surfaced, reported upstream as
[cedardb/issues#71](https://github.com/cedardb/issues/issues/71):
  * subscripting (≥ 2 ×) an array column produced by a `CASE`/`if` expression — when a branch
    is a function returning an array and the query has `ORDER BY` — aborts the server
    (`ArrayRuntime.cpp:937` `ArrayHeader` assertion). All four ingredients are required; drop
    any one and it runs. Worked around throughout by making every array choice an arithmetic
    `mix()` blend on a 0/1 selector rather than a `CASE` returning an array.

The other rough edges turned out **not** to be bugs, on closer testing:
  * `LATERAL` inside a *recursive* term works fine (an isolated repro runs correctly); the
    marches inline their per-step expressions purely as a style choice. (The crash I first
    blamed on this was actually the `CASE`-array bug above, which the same query also hit.)
  * integer literals default to `int32` — standard PostgreSQL behaviour, so the LCG hash needs
    explicit `bigint`; the intentional `LATERAL` "let" joins need `SET implicit_cross_products
    = ON` (an intentional guard); composite types and subqueries-in-function-bodies are
    documented-as-unimplemented, not crashes.

### Postgres / MySQL — no SQL lambdas *and* no advanced recursive planner

These dialects also lack lambdas, so a faithful port needs the same recursive-CTE
reformulation of every loop — but without CedarDB's planner, a six-march query is a much
riskier proposition, and MySQL additionally lacks arrays (vectors would have to be triples of
columns or JSON). They remain the procedural / recursive-CTE frontier; CedarDB shows the
recursive-CTE shape *can* work when the planner is strong enough.

## Conclusion

The combined ClickHouse ray tracer is **portable as a faithful translation** (the math, the
hash, the SDFs all reproduce correctly), but whether it is portable *as a single SQL query*
depends entirely on **how the engine's planner represents a bounded loop**:

- expand the loop into an **expression** (DuckDB's `list_reduce` macro) and several marches
  multiply into a query the planner can't analyse — it cannot compile the scene at all;
- analyse the loop as a **bounded operator** (ClickHouse's `arrayFold`) and it compiles, but
  the cost is concentrated in analysing the deeply-nested lambda tree (~54 s, resolution-independent);
- iterate the loop as a **relation** (CedarDB's `WITH RECURSIVE`) and the planner sees an
  ordinary recursive join — it compiles *and* runs the six-march scene in ~4.3 s.

So the renderer is an unusually sharp benchmark of **query-compiler architecture** rather than
execution throughput. The same ~8 nested bounded loops are trivial, analysis-bound, or
impossible depending only on whether the engine treats the loop as a relation, an operator, or
an expression. Two of three engines tried can run it; the one that can't is the one that
inlines the loop into an expression.

## Open follow-ups

- **Postgres / MySQL via recursive CTE** — the CedarDB shape ports in principle, but without
  CedarDB's planner the six-march query is a risky bet (and MySQL lacks arrays — vectors become
  column triples or JSON).
- **A portable single-march scene** — a terrain-only variant (one `marchTerr`, no
  letters/tori/planet, no reflections) is within reach for every engine (DuckDB handles one
  march in 6.7 s) and would yield apples-to-apples *execution* numbers across all of them.
- **DuckDB separate-statement workaround** — split into ~20 `CREATE TABLE … AS` statements,
  ≤ 1 march each, to sidestep the planner blowup for the full scene.

## Reproducing

```bash
# ClickHouse reference (pixel dump + image)
python3 gen_clickhouse_bench.py 192 90 2 data > queries/clickhouse.sql
clickhouse local --queries-file queries/clickhouse.sql > out/clickhouse.tsv
python3 tools.py render out/clickhouse.tsv 192 90 out/clickhouse.png

# CedarDB port (Postgres wire protocol)
python3 gen_cedardb_bench.py 192 90 2 > queries/cedardb.sql
psql -h 127.0.0.1 -p 5499 -U postgres -d raytracer -q -f queries/cedardb.sql > out/cedardb.tsv
python3 tools.py render out/cedardb.tsv 192 90 out/cedardb_192.png

# Compare an engine's dump against the reference
python3 tools.py compare out/clickhouse.tsv out/cedardb.tsv
```
