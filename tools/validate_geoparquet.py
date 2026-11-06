"""Validate GeoParquet output metadata using an independent PyArrow reader."""
import json
import sys
import pyarrow.parquet as pq

for filename, version in (("gp-v1.parquet", "1.0.0"),
                          ("gp-v2.parquet", "2.0.0")):
    parquet = pq.ParquetFile(filename)
    geo = json.loads(parquet.metadata.metadata[b"geo"])
    assert geo["version"] == version
    name = geo["primary_column"]
    assert name in geo["columns"]
    logical = str(parquet.schema.column(parquet.schema.names.index(name)).logical_type)
    assert ("GEOMETRY" in logical.upper()) == (version == "2.0.0"), logical
    assert parquet.metadata.num_rows == 2
    print(filename, "validated")
