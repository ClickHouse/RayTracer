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
├── primfont2.py              # the glyph geometry (shared)
├── tools.py                  # render a TSV dump to PNG; diff two dumps for correctness
├── queries/                  # the generated per-engine queries
│   └── clickhouse.sql
└── out/                      # rendered images and pixel dumps
    ├── clickhouse.tsv        # the reference pixel dump
    └── clickhouse_192.png    # the reference image
```

## Running

```bash
# ClickHouse reference (pixel dump + image)
python3 gen_clickhouse_bench.py 192 90 2 data > queries/clickhouse.sql
clickhouse local --queries-file queries/clickhouse.sql > out/clickhouse.tsv
python3 tools.py render out/clickhouse.tsv 192 90 out/clickhouse.png

# Compare another engine's dump against the reference
python3 tools.py compare out/clickhouse.tsv out/duckdb.tsv
```

## The reference image (192 × 90)

![reference](out/clickhouse_192.png)

## Status & notes

| Engine | Port approach | Status |
|---|---|---|
| **ClickHouse** | `arrayFold` + `arrayMap` lambdas + tuple math | ✅ reference, ~55 s |
| **DuckDB** | `CREATE MACRO` + `list_reduce`/`list_transform` | ❌ pieces work, but the planner can't compile a multi-march query (see below) |
| **Postgres** | no SQL lambdas/HOFs → recursive CTE / PL/pgSQL | not started (procedural) |
| **CedarDB** | Postgres-compatible, same constraint | not started (procedural) |
| **MySQL** | no arrays/lambdas → recursive CTE / stored routines | not started (procedural) |

### Findings

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

**Bottom line:** ClickHouse's analyzer compiles this whole renderer (~50 s) and runs it;
DuckDB's planner cannot compile it at all once more than one ray-march is involved. That is
the headline cross-engine result so far. The only remaining DuckDB avenue is to split the
renderer into ~20 *separate* `CREATE TABLE … AS` statements (≤ 1 march each, materialised to
real tables between them) — possible, but non-idiomatic and with unknown execution speed.

**3. Postgres / CedarDB / MySQL have no lambdas or higher-order array functions in SQL at
all**, so even the inner marches (`list_reduce` over the ray) can't be written as expressions.
A faithful port needs procedural code (PL/pgSQL functions, MySQL stored routines) or a
recursive-CTE reformulation of every loop — a substantially larger effort than DuckDB.
