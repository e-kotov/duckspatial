"""Isolate DuckDB GeoParquet V2 metadata behavior WITHOUT duckspatial or R.

Runs under duckdb Python 2.0.0 and inspects files with PyArrow.
This is an experimental characterization, not a production or acceptance test.
"""
import json
from pathlib import Path
import sys
import traceback
import duckdb
import pyarrow.parquet as pq

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
connection = duckdb.connect()
connection.execute("INSTALL spatial; LOAD spatial")

cases = json.loads(Path(__file__).with_name("cases.json").read_text())
rows = []
for name, sql in cases.items():
    for version in ["V1", "V2"]:
        dest = out / f"{name}-{version.lower()}.parquet"
        row = {"case": name, "version": version, "duckdb_version": duckdb.__version__,
               "sql": sql, "status": "ok", "error": None}
        try:
            describe = connection.sql("DESCRIBE " + sql).fetchall()
            row["types"] = {k: typ for k, typ, *_ in describe}
            connection.execute(f"COPY ({sql}) TO '{dest}' (FORMAT PARQUET, GEOPARQUET_VERSION '{version}')")
            parquet = pq.ParquetFile(dest)
            meta = parquet.metadata.metadata or {}
            geo = json.loads(meta[b"geo"]) if b"geo" in meta else None
            row["geo"] = geo
            row["has_geo"] = geo is not None
            row["rows"] = parquet.metadata.num_rows
            row["schema"] = str(parquet.schema)
            row["geo_columns"] = sorted(geo.get("columns", {})) if geo else []
            row["primary_column"] = geo.get("primary_column") if geo else None
        except Exception as error:
            row["status"] = "error"
            row["error"] = str(error)
        rows.append(row)
        print(json.dumps({"case":name,"version":version,"types":row.get("types"),
            "has_geo":row.get("has_geo"),"geo_columns":row.get("geo_columns"),
            "primary":row.get("primary_column"),"status":row["status"],"error":row.get("error")}),flush=True)
(out / "results-python.json").write_text(json.dumps(rows, indent=2, default=str))
print("OUTPUT_RECORDS",len(rows),flush=True)
