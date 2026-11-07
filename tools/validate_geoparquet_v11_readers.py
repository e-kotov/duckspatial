"""Read GeoParquet 1.1 output with GeoPandas and optionally GDAL.

Core conformance and PyArrow/Shapely/PROJ tests run in other workflow steps.
A missing GDAL Parquet driver is explicitly reported as unverified.
"""
from pathlib import Path

import geopandas as gpd
from pyproj import CRS
import pyogrio

root = Path("geoparquet-interop")
points = gpd.read_parquet(root / "gp-v1.1.parquet")
assert len(points) == 2 and points.crs.to_epsg() == 4326
assert list(points.geometry.x) == [1.0, 3.0]

multi = gpd.read_parquet(root / "multi-v1.1.parquet")
assert len(multi) == 3
assert multi.geometry.name == "geometry"
assert multi.crs.to_epsg() == 3857
assert multi["other"].crs.to_epsg() == 4326
assert multi.geometry.iloc[2].is_empty

unknown = gpd.read_parquet(root / "unknown-v1.1.parquet")
assert unknown.crs is None and len(unknown) == 2

custom = gpd.read_parquet(root / "custom-v1.1.parquet")
expected = CRS.from_user_input(
    "+proj=aeqd +lat_0=52 +lon_0=13 +datum=WGS84 +units=m +no_defs"
)
assert CRS.from_user_input(custom.crs).equals(expected, ignore_axis_order=True)

nonpoint = gpd.read_parquet(root / "nonpoint-v1.1.parquet")
assert len(nonpoint) == 9
assert nonpoint.geometry.iloc[0].geom_type == "LineString"
assert nonpoint.geometry.iloc[2].geom_type == "Polygon"
assert nonpoint.geometry.iloc[6].is_empty
assert nonpoint.geometry.iloc[8] is None
print("GEOPANDAS_V11_PASS: known, custom and unknown CRS, multiple geometry "
      "columns, mixed geometries, EMPTY and NULL")

drivers = pyogrio.list_drivers()
if "Parquet" in drivers and "r" in drivers["Parquet"].lower():
    for name, n in (("gp-v1.1.parquet", 2), ("nonpoint-v1.1.parquet", 9)):
        frame = pyogrio.read_dataframe(root / name)
        assert len(frame) == n, name
    print("GDAL_PARQUET_V11_PASS: read two files via pyogrio/GDAL")
else:
    print("GDAL_PARQUET_V11_UNAVAILABLE: this GDAL build lacks Parquet "
          "reading; GDAL interoperability remains unverified")
