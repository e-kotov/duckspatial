"""Read and round-trip all generated GeoParquet versions without DuckDB.

The companion validator defines expected source geometries independently.
Here each reader must preserve those source values, dimensions, CRS, active
geometry, NULLs, empties and zero rows. GeoPandas writes the same GeoParquet
version back; native V2 is not silently downgraded to WKB V1.1.
"""
from collections import Counter
import json
from pathlib import Path
import sys
import tempfile

import geopandas as gpd
from geopandas.io.arrow import SUPPORTED_VERSIONS
import pyarrow
import pyarrow.parquet as pq
import pyogrio
import pyproj
from pyproj import CRS
import shapely

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else "geoparquet-interop")
paths = sorted(path for path in ROOT.rglob("*.parquet") if path.is_file())
assert paths, f"No Parquet fixtures found under {ROOT}"
print("READER_VERSIONS:", json.dumps({
    "geopandas": gpd.__version__, "pyarrow": pyarrow.__version__,
    "shapely": shapely.__version__, "pyproj": pyproj.__version__,
    "pyogrio": pyogrio.__version__, "gdal": pyogrio.__gdal_version_string__,
}))


def check_crs(actual, expected, label):
    if expected is None:
        assert actual is None, (label, actual)
    else:
        assert actual is not None, label
        assert CRS.from_user_input(actual).equals(
            CRS.from_json_dict(expected), ignore_axis_order=True
        ), (label, actual, expected)


def check_geometries(actual, expected_wkb, label):
    assert len(actual) == len(expected_wkb), label
    for index, (got, value) in enumerate(zip(actual, expected_wkb)):
        if value is None:
            assert got is None, (label, index, "NULL became geometry")
        else:
            want = shapely.from_wkb(value)
            assert got is not None, (label, index, "geometry became NULL")
            assert shapely.equals_identical(got, want), (
                label, index, shapely.to_wkt(got), shapely.to_wkt(want)
            )
            assert bool(shapely.has_z(got)) == bool(shapely.has_z(want)), (label, index)
            assert bool(shapely.has_m(got)) == bool(shapely.has_m(want)), (label, index)


def check_frame(frame, values, geo, label):
    assert frame.geometry.name == geo["primary_column"], label
    assert len(frame) == len(values["id"]), label
    for name, source_values in values.items():
        assert name in frame.columns, (label, name)
        if name in geo["columns"]:
            assert isinstance(frame[name].dtype, gpd.array.GeometryDtype), (label, name)
            check_crs(frame[name].crs, geo["columns"][name]["crs"], (label, name))
            check_geometries(frame[name], source_values, (label, name))
        else:
            assert frame[name].tolist() == source_values, (label, name)


read_counts = Counter()
roundtrip_counts = Counter()
gdal_counts = Counter()
gdal_available = "r" in pyogrio.list_drivers().get("Parquet", "").lower()

with tempfile.TemporaryDirectory(prefix="duckspatial-geopandas-roundtrip-") as directory:
    for index, path in enumerate(paths):
        label = str(path.relative_to(ROOT))
        source = pq.ParquetFile(path)
        values = source.read().to_pydict()
        geo = json.loads(source.metadata.metadata[b"geo"])
        version = geo["version"]

        # No blanket exception handling: unexpected reader or writer errors
        # must fail validation, including failures involving measured geometry.
        frame = gpd.read_parquet(path)
        check_frame(frame, values, geo, label)
        read_counts[version] += 1

        if version not in SUPPORTED_VERSIONS:
            print("GEOPANDAS_WRITE_UNAVAILABLE:", label, "input version", version,
                  "not in installed writer's supported versions", SUPPORTED_VERSIONS)
        else:
            destination = Path(directory) / f"{index}.parquet"
            frame.to_parquet(destination, index=False, geometry_encoding="WKB",
                             schema_version=version)
            roundtrip = gpd.read_parquet(destination)
            check_frame(roundtrip, values, geo, f"{label} round-trip")
            written = pq.ParquetFile(destination)
            written_geo = json.loads(written.metadata.metadata[b"geo"])
            assert written_geo["version"] == version, label
            assert written_geo["primary_column"] == geo["primary_column"], label
            assert set(written_geo["columns"]) == set(geo["columns"]), label
            for name in geo["columns"]:
                column = written.schema.column(written.schema.names.index(name))
                assert column.physical_type == "BYTE_ARRAY", (label, name)
                logical = json.loads(column.logical_type.to_json())
                assert logical["Type"] == (
                    "Geometry" if version == "2.0.0" else "None"
                ), (label, name, logical)
            roundtrip_counts[version] += 1

        if gdal_available:
            # pyogrio exposes one active geometry; secondary geometry fields
            # are independently checked by PyArrow/Shapely and GeoPandas above.
            gdal_frame = pyogrio.read_dataframe(path)
            primary = geo["primary_column"]
            assert len(gdal_frame) == len(values["id"]), label
            assert gdal_frame["id"].tolist() == values["id"], label
            check_crs(gdal_frame.crs, geo["columns"][primary]["crs"], label)
            check_geometries(gdal_frame.geometry, values[primary], label)
            gdal_counts[version] += 1
        print("GEOPANDAS_READ_PASS:", label)

print("GEOPANDAS_READ_COUNTS:", json.dumps(read_counts, sort_keys=True))
print("GEOPANDAS_SAME_VERSION_ROUNDTRIP_COUNTS:", json.dumps(roundtrip_counts, sort_keys=True))
if roundtrip_counts != read_counts:
    print("GEOPANDAS_ROUNDTRIP_LIMITATION: see explicit unsupported writer versions above")
else:
    print("GEOPANDAS_ALL_SAME_VERSION_ROUNDTRIPS_PASS")
if gdal_available:
    print("GDAL_PARQUET_PRIMARY_GEOMETRY_PASS:", json.dumps(gdal_counts, sort_keys=True))
else:
    print("GDAL_PARQUET_UNAVAILABLE:", pyogrio.__gdal_version_string__,
          "has no Parquet reader; GDAL interoperability remains unverified")
