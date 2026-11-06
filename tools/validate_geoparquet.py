"""Independently check package output with PyArrow, Shapely and PROJ.

Run tools/generate_geoparquet_fixtures.R first. No DuckDB reader is used here.
Checks cover schema, native/JSON CRS agreement, exact geometry values and
dimensions, NULL/EMPTY distinction, partitions and native row-group statistics.
"""
import json
import math
from pathlib import Path
import struct
import sys

import pyarrow.parquet as pq
from pyproj import CRS, Transformer
import shapely

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else "geoparquet-interop")
CUSTOM = "+proj=aeqd +lat_0=52 +lon_0=13 +datum=WGS84 +units=m +no_defs"


def geometry_type(wkb):
    return struct.unpack(("<" if wkb[0] else ">") + "I", wkb[1:5])[0]


def check_file(path, version, primary, crses, expected, compression=None):
    parquet = pq.ParquetFile(path)
    geo = json.loads(parquet.metadata.metadata[b"geo"])
    assert geo["version"] == version, path
    assert geo["primary_column"] == primary, path
    assert set(geo["columns"]) == set(crses), path
    assert parquet.metadata.num_rows == len(expected), path
    assert [n for n in parquet.schema.names if n in crses][0] == primary, path

    rows = parquet.read().to_pylist()
    assert {row["id"] for row in rows} == set(expected), path
    for name, crs in crses.items():
        col_index = parquet.schema.names.index(name)
        column = parquet.schema.column(col_index)
        assert column.path == name and column.physical_type == "BYTE_ARRAY", path
        assert column.max_repetition_level == 0, path
        metadata = geo["columns"][name]
        assert metadata["encoding"] == "WKB", path
        assert metadata["geometry_types"] == [], path
        assert "crs" in metadata, path
        if crs is None:
            assert metadata["crs"] is None, path
        else:
            assert CRS.from_json_dict(metadata["crs"]).equals(
                CRS.from_user_input(crs), ignore_axis_order=True
            ), (path, name, metadata["crs"])
        logical = json.loads(column.logical_type.to_json())
        assert logical["Type"] == ("Geometry" if version == "2.0.0" else "None"), path
        if version == "2.0.0":
            # DuckDB canonicalizes CRS definitions using its bundled PROJ;
            # sf may use a different PROJ version. The specification requires
            # semantic agreement, not identical JSON serialization.
            assert CRS.from_json(logical["crs"]).equals(
                CRS.from_json_dict(metadata["crs"]), ignore_axis_order=True
            ), (path, name)

        for row in rows:
            want = expected[row["id"]][name]
            value = row[name]
            if want is None:
                assert value is None, (path, row["id"], name)
            else:
                assert value is not None, (path, row["id"], name)
                got = shapely.from_wkb(value)
                assert shapely.equals_identical(got, shapely.from_wkt(want)), (
                    path, row["id"], name, shapely.to_wkt(got), want
                )
                if version == "1.0.0":
                    assert geometry_type(value) in set(range(1, 8)) | set(range(1001, 1008)), path

        for group_index in range(parquet.num_row_groups):
            chunk = parquet.metadata.row_group(group_index).column(col_index)
            if compression:
                assert chunk.compression == compression, path
            values = parquet.read_row_group(group_index, columns=[name]).column(0).to_pylist()
            values = [v for v in values if v is not None]
            stats = chunk.geo_statistics
            if version == "1.0.0":
                assert stats is None, path
                continue
            if not values:
                assert stats is None or not stats.geospatial_types, path
                continue
            assert stats is not None, path
            assert set(stats.geospatial_types) == {geometry_type(v) for v in values}, path
            coordinates = shapely.get_coordinates(
                [shapely.from_wkb(v) for v in values], include_z=True, include_m=True
            )
            for axis, dim in enumerate("xyzm"):
                finite = [float(c[axis]) for c in coordinates if math.isfinite(c[axis])]
                lo, hi = getattr(stats, dim + "min"), getattr(stats, dim + "max")
                if finite:
                    assert lo == min(finite) and hi == max(finite), (path, name, dim, stats)
                else:
                    assert lo is None and hi is None, (path, name, dim, stats)
    print(path.relative_to(ROOT), "validated")


base = {1: {"geometry": "POINT (1 2)"}, 2: {"geometry": "POINT (3 4)"}}
check_file(ROOT / "gp-v1.parquet", "1.0.0", "geometry", {"geometry": None}, base)
check_file(ROOT / "gp-v2.parquet", "2.0.0", "geometry", {"geometry": 4326}, base)

multi = {
    1: {"geometry": "POINT (1000 2000)", "other": "POINT (1 2)"},
    2: {"geometry": "POINT (3000 4000)", "other": "POINT (3 4)"},
    3: {"geometry": "POINT EMPTY", "other": "POINT (5 6)"},
}
for tag, version in (("v1", "1.0.0"), ("v2", "2.0.0")):
    crses = {"geometry": 3857, "other": 4326}
    check_file(ROOT / f"multi-{tag}.parquet", version, "geometry", crses, multi, "ZSTD")
    check_file(ROOT / f"empty-{tag}.parquet", version, "geometry", crses, {})
    files = sorted((ROOT / f"partitioned-{tag}.parquet").rglob("*.parquet"))
    assert len(files) == 2, files
    seen = set()
    for path in files:
        ids = {1, 3} if path.parent.name == "part=A" else {2}
        assert not (seen & ids), path
        seen |= ids
        check_file(path, version, "geometry", crses, {i: multi[i] for i in ids})
    assert seen == set(multi)

wkts = {
    10: "POINT (1 2)", 20: "POINT Z (3 4 5)",
    30: "POINT M (6 7 8)", 40: "POINT ZM (9 10 11 12)",
    50: "POINT EMPTY", 60: None, 70: "POINT M EMPTY",
    80: "GEOMETRYCOLLECTION ZM (POINT ZM (13 14 15 16))",
}
for tag, version in (("v1", "1.0.0"), ("v2", "2.0.0")):
    ids = (10, 20, 50, 60) if tag == "v1" else wkts.keys()
    expected = {
        i: {"shape": wkts[i], "other": None if i == 20 else f"POINT ({i} {2 * i})"}
        for i in ids
    }
    crses = {"shape": 4326, "other": 3857}
    check_file(ROOT / f"dimensions-{tag}.parquet", version, "shape", crses, expected)
    check_file(ROOT / f"null-{tag}.parquet", version, "shape", crses, {60: expected[60]})

check_file(ROOT / "custom-v2.parquet", "2.0.0", "geometry", {"geometry": CUSTOM}, base)

# Use an independent PROJ calculation for the lazy transformed query.
path = ROOT / "transformed-v2.parquet"
parquet = pq.ParquetFile(path)
geo = json.loads(parquet.metadata.metadata[b"geo"])
assert CRS.from_json_dict(geo["columns"]["geometry"]["crs"]).to_epsg() == 3857
column = parquet.schema.column(parquet.schema.names.index("geometry"))
assert CRS.from_json(json.loads(column.logical_type.to_json())["crs"]).equals(
    CRS.from_json_dict(geo["columns"]["geometry"]["crs"]), ignore_axis_order=True
)
row = parquet.read().to_pylist()[0]
assert row["id"] == 1
xy = shapely.get_coordinates(shapely.from_wkb(row["geometry"]))[0]
want = Transformer.from_crs(4326, 3857, always_xy=True).transform(1, 2)
assert all(math.isclose(a, b, rel_tol=1e-12) for a, b in zip(xy, want)), (xy, want)
print(path.relative_to(ROOT), "validated")
print("All independent GeoParquet interoperability checks passed")
