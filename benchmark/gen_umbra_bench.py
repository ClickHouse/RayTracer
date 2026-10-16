#!/usr/bin/env python3
"""Emit the benchmark scene as an Umbra script.

Umbra is CedarDB's research ancestor and runs the same set-based,
recursive-CTE port (see gen_cedardb_bench.py for its design), so this script
takes the CedarDB script unchanged except for one dialect difference:

  double precision[] parameter /  -> double precision array  (Umbra rejects the
  return types                       [] suffix in a function signature)

and the comments that name CedarDB (the header, and the implicit-cross-product
guard, which Umbra has as well).

Usage:  gen_umbra_bench.py [W] [H] [DEPTH]   (default 48 24 2)

Requires an Umbra build that takes a query as the body of a SQL function
(AS 'SELECT expr'): master with branch schmidt/sql-udf-select-body, or the
26.10 image from 2026-10-15 on. Earlier builds expect a bare expression and
reject the SELECT bodies.

Run (a local build, started like ClickBench's umbra LOCAL mode; here on port 5496):
  bin/sql -createdb db/umbra.db <<<"ALTER ROLE postgres WITH LOGIN SUPERUSER PASSWORD 'postgres';"
  ASYNCIO=0 bin/server -port=5496 db/umbra.db &
  python3 gen_umbra_bench.py 2560 1200 2 > queries/umbra_full.sql
  PGPASSWORD=postgres psql -h 127.0.0.1 -p 5496 -U postgres -q -f queries/umbra_full.sql > out/umbra.tsv
"""
import os, re, subprocess, sys

# The CedarDB script for the same arguments (W H DEPTH), from its generator next to this one
W, H, DEPTH = (sys.argv[1:4] + ["48", "24", "2"][len(sys.argv[1:4]):])
CEDAR_SCRIPT = subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "gen_cedardb_bench.py"), W, H, DEPTH],
                              check=True, capture_output=True, text=True).stdout

# CREATE OR REPLACE FUNCTION <signature with double precision[]> AS  ->  ... double precision array ...
script, n = re.subn(r"CREATE OR REPLACE FUNCTION .*?LANGUAGE sql AS",
                    lambda m: m.group(0).replace("double precision[]", "double precision array"), CEDAR_SCRIPT, flags=re.S)
assert n > 0, "unexpected CedarDB script shape"

# The comments that name CedarDB
for cedar, umbra in (("CedarDB port", "Umbra port"), ("CedarDB's implicit-cross-product guard", "Umbra's implicit-cross-product guard")):
    assert cedar in script, f"unexpected CedarDB script shape: {cedar}"
    script = script.replace(cedar, umbra, 1)

sys.stdout.write(script)
