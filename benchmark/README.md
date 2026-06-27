# Cross-engine benchmark

Porting the combined **ClickHouse-over-terrain** scene to other SQL engines, checking that
each renders the *same* image, and measuring how long each takes.

## The scene

A small, deterministic version of [`../queries/clickhouse_terrain.sql`](../queries/clickhouse_terrain.sql):

- **192 × 90**, 1 centred sample per pixel, 2 bounce depth — small on purpose, so even slow
  engines finish in reasonable time.
- **Deterministic**: no anti-alias jitter, no soft-shadow jitter (the light is a fixed point),
  so every engine should produce identical pixels up to floating-point rounding.
- **Portable hash**: the terrain noise uses a hand-rolled integer LCG hash (two rounds, all
  intermediates below ~9.2e18 so it never overflows signed 64-bit and never errors in
  Postgres/MySQL) instead of `cityHash64`/`intHash64`, so the *terrain matches across engines*.

Every engine emits one row per pixel — `idx \t R \t G \t B` (0–255, scanline order). That
uniform dump is what we diff and render; only ClickHouse can also emit a real PNG.

## Layout

```
benchmark/
├── gen_clickhouse_bench.py   # emits the ClickHouse query (portable hash, PNG or TSV output)
├── gen_cedardb_bench.py      # emits the CedarDB recursive-CTE port (args: W H DEPTH)
├── gen_duckdb_bench.py       # emits the DuckDB port (does not compile; kept as evidence)
├── primfont2.py              # the glyph geometry (shared)
├── tools.py                  # render a TSV dump to PNG; diff two dumps for correctness
├── FINDINGS.md               # the cross-engine portability write-up
├── queries/                  # the generated per-engine queries
│   ├── clickhouse.sql
│   └── cedardb.sql
└── out/                      # rendered images and pixel dumps
    ├── clickhouse.tsv        # the reference pixel dump (192x90)
    ├── clickhouse_192.png    # the reference image
    └── cedardb_192.png       # the CedarDB render (visually identical)
```

## Running

```bash
# ClickHouse reference (pixel dump + image)
python3 gen_clickhouse_bench.py 192 90 2 data > queries/clickhouse.sql
clickhouse local --queries-file queries/clickhouse.sql > out/clickhouse.tsv
python3 tools.py render out/clickhouse.tsv 192 90 out/clickhouse.png

# CedarDB port (Postgres wire protocol; here on host port 5499)
python3 gen_cedardb_bench.py 192 90 2 > queries/cedardb.sql
psql -h 127.0.0.1 -p 5499 -U postgres -d raytracer -q -f queries/cedardb.sql > out/cedardb.tsv
python3 tools.py render out/cedardb.tsv 192 90 out/cedardb_192.png

# Compare an engine's dump against the reference
python3 tools.py compare out/clickhouse.tsv out/cedardb.tsv
```

## The reference image (192 × 90)

![reference](out/clickhouse_192.png)

## Status & notes

| Engine | Port approach | Status |
|---|---|---|
| **ClickHouse** | `arrayFold` + `arrayMap` lambdas + tuple math | ✅ reference, ~54 s (analysis-bound) |
| **CedarDB** | recursive-CTE marches + set-based hits + SQL functions | ✅ matches reference, **~4.3 s** (see below) |
| **DuckDB** | `CREATE MACRO` + `list_reduce`/`list_transform` | ❌ pieces work, but the planner can't compile a multi-march query (see below) |
| **Postgres** | no SQL lambdas/HOFs → recursive CTE / PL/pgSQL | not started (procedural) |
| **MySQL** | no arrays/lambdas → recursive CTE / stored routines | not started (procedural) |

### Timing (192 × 90, depth 2, same machine)

| Engine | Wall time | Notes |
|---|---:|---|
| ClickHouse | **54.4 s** | dominated by analysis of the nested lambda tree, not pixel compute |
| CedarDB | **4.3 s** | set-based recursive CTEs; the planner is not analysis-bound here |
| DuckDB | — | cannot compile the scene at all |

Same scene, same image (mean per-channel difference ≈ 1.0 / 255 vs the ClickHouse
reference; the two renders are visually identical). The ~12× gap is *formulation*,
not raw engine power: ClickHouse's idiomatic `arrayFold`/lambda query spends its
time in query analysis, while CedarDB's idiomatic recursive-CTE port does not.

### Findings

> A full, self-contained write-up of the cross-engine portability study is in
> [`FINDINGS.md`](FINDINGS.md). The summary below is the short version.

**1. ClickHouse time here is dominated by query *analysis*, not pixel compute.** This is a
deeply nested tree of ~30 lambdas; expanding/analysing it takes ~50 s regardless of
resolution (16×16 ≈ 50 s, 192×90 ≈ 60 s). At low resolution the ClickHouse number is mostly a
fixed compile cost, not ray-tracing throughput.

**2. The DuckDB port works piece-by-piece but the *whole* renderer overwhelms DuckDB's
planner.** `gen_duckdb_bench.py` faithfully translates the scene (tuples→`LIST`, lambdas→
`MACRO`, `arrayFold`→`list_reduce`, the portable hash, etc.) and the individual pieces run and
match: `terrH`, `toriSDF`, `marchTorus` (0.4 s), `marchTerr` (a single ray ≈ 6.5 s bind +
~17 ms/ray, so it vectorises). But assembling them into one `oneBounce` expression does not
bind — a single `oneBounce` evaluation runs >110 s at ~14 GB and never returns. DuckDB
macros are call-by-name, and even with the marched point bound via a one-element
`list_transform`, the fully-expanded per-bounce expression is too large for DuckDB's
binder/optimizer. (ClickHouse's analyzer *does* compile the equivalent monolith, in ~50 s —
that contrast is itself a result.)

I then re-architected it: each bounce as a `MATERIALIZED` CTE, the per-bounce step as a flat
SELECT using DuckDB's by-value **lateral column aliasing** (verified: an alias referenced 4×
binds once). Memory no longer blows up (~1 GB, not 14 GB) — but it still doesn't **plan**:

| what | time |
|---|---|
| one `marchTerr` (a single ray-march, scalar) | ~6.7 s |
| `marchTerr` **+** `marchTorus` in one query | **> 150 s (timeout)** |
| `EXPLAIN` of a single bounce (planning only, no execution) | **> 280 s (timeout)** |

So DuckDB's optimizer is **superlinear — effectively exponential — in the number of
macro-expanded `list_reduce` marches in a single query**. One march is fine; two already blow
up. The combined scene needs ~4 marches per bounce (terrain, tori, the shadow's terrain and
tori marches) × 2 bounces ≈ 8 marches, which DuckDB cannot plan in any formulation tried
(monolith, staged-flat, per-march CTEs all plan the whole query together).

**Bottom line:** DuckDB's planner cannot compile this renderer once more than one ray-march is
involved — because its `list_reduce` march is an *expression*, and nesting several of them
blows up the expression the planner must analyse. (CedarDB, which expresses the same marches
as *recursive CTEs* — relations, not expressions — has no such problem; see finding 3.) The
only remaining DuckDB avenue is to split the renderer into ~20 *separate* `CREATE TABLE … AS`
statements (≤ 1 march each, materialised to real tables between them) — possible, but
non-idiomatic and with unknown execution speed.

**3. CedarDB compiles *and* runs the whole scene — fast — via recursive CTEs.** CedarDB has
no SQL lambdas either, so the port is a different shape: vectors are `double precision[]`,
leaf math is `CREATE FUNCTION` expression-bodies, intersection math lives in `LATERAL` "let"
chains in the main query, and every ray-march is a `WITH RECURSIVE` that advances all rays in
lockstep. The bounce loop is unrolled (a recursive CTE can't be nested in another), so depth-2
is two march pipelines; the full query carries **six recursive marches** (terrain + tori, ×
primary and shadow, × two bounces) plus the analytic letters and planet — and CedarDB's
planner handles it without complaint, in ~4.3 s at 192 × 90. The render matches the ClickHouse
reference (mean per-channel diff ≈ 1.0; the handful of pixels that differ by more are
silhouette / shadow-boundary pixels, the inherent sub-pixel disagreement of two independent
ray tracers without anti-aliasing). This is the crisp contrast with DuckDB: the *recursive
CTE* is a relation (data-level iteration with a bounded per-step body), so the planner never
faces the exponential expression blow-up that defeats DuckDB's macro expansion. Full write-up
in [`FINDINGS.md`](FINDINGS.md). Two CedarDB engine bugs/quirks found along the way:
subscripting a `CASE`-produced array aborts the server (worked around with `mix()` blends),
and `LATERAL` inside a recursive term also aborts (the marches inline their step expressions).

**4. Postgres / MySQL have no lambdas *and* no advanced recursive planner.** A faithful port
still needs a recursive-CTE reformulation of every loop, but without CedarDB's planner the
six-march query is a much riskier bet; these remain the procedural / recursive-CTE frontier.
