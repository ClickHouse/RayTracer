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
| **DuckDB** | `CREATE MACRO` + `list_reduce`/`list_transform` + `LIST`/`STRUCT` | ⚠ pieces work, full query won't compile (see below) |
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

To make DuckDB run, the per-bounce computation has to be **flattened into query stages**
(a recursive CTE whose columns hold the intermediates, instead of one nested-`list_transform`
expression). That re-architecture is the natural next step.

**3. Postgres / CedarDB / MySQL have no lambdas or higher-order array functions in SQL at
all**, so even the inner marches (`list_reduce` over the ray) can't be written as expressions.
A faithful port needs procedural code (PL/pgSQL functions, MySQL stored routines) or a
recursive-CTE reformulation of every loop — a substantially larger effort than DuckDB.
