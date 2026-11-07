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

cases = {
    "typed_single_xy": """SELECT ST_Point(5, 6)::GEOMETRY('EPSG:3857') AS geometry""",
    "unqualified_xy": """SELECT ST_Point(500000, 6000000)::GEOMETRY AS geometry""",
    "typed_two_columns": """SELECT
          ST_Point(1,2)::GEOMETRY('EPSG:4326') AS shape,
          ST_Point(500000,6000000)::GEOMETRY('EPSG:3857') AS other""",
    "renamed_typed_two": """SELECT shape AS renamed, other FROM (
          SELECT ST_Point(1,2)::GEOMETRY('EPSG:4326') AS shape,
          ST_Point(500000,6000000)::GEOMETRY('EPSG:3857') AS other
        )""",
    "empty_typed_single": """SELECT ST_Point(5,6)::GEOMETRY('EPSG:3857') AS geometry WHERE FALSE""",
    "empty_typed_two": """SELECT
          ST_Point(1,2)::GEOMETRY('EPSG:4326') AS shape,
          ST_Point(500000,6000000)::GEOMETRY('EPSG:3857') AS other WHERE FALSE""",
    "typed_measured_point": """SELECT ST_GeomFromText('POINT M (1 2 3)')::GEOMETRY('EPSG:3857') AS geometry""",
    "typed_measured_zm": """SELECT ST_GeomFromText('LINESTRING ZM (0 0 1 2, 1 1 3 4)')::GEOMETRY('EPSG:3857') AS geometry""",
    "untyped_measured_zm": """SELECT ST_GeomFromText('LINESTRING ZM (0 0 1 2, 1 1 3 4)') AS geometry""",
    "typed_nonpoint": """SELECT ST_GeomFromText('LINESTRING (0 0, 1 1)')::GEOMETRY('EPSG:3857') AS geometry""",
    "mixed_measured_rows": """SELECT ST_GeomFromText(wkt)::GEOMETRY('EPSG:4326') AS geometry
          FROM (VALUES ('POINT (1 2)'), ('POINT M (3 4 5)')) t(wkt)""",
    "filtered_mixed_measured": """SELECT geometry FROM (
          SELECT id, ST_GeomFromText(wkt)::GEOMETRY('EPSG:4326') AS geometry
          FROM (VALUES (1,'POINT (1 2)'), (2,'POINT M (3 4 5)')) t(id,wkt)
        ) WHERE id = 1""",
}
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
