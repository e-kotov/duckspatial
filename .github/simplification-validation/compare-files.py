"""Compare independently validated physical output from reference and candidate."""
import argparse
import json
import math
from pathlib import Path

import pyarrow.parquet as pq
from pyproj import CRS
import shapely


def hilbert_index(x, y):
    """The independent 16-bit algorithm used by the preserved validator."""
    side = 1 << 16
    distance = 0
    step = side >> 1
    while step:
        rx, ry = int(bool(x & step)), int(bool(y & step))
        distance += step * step * ((3 * rx) ^ ry)
        if ry == 0:
            if rx == 1:
                x, y = side - 1 - x, side - 1 - y
            x, y = y, x
        step >>= 1
    return distance


def check_physical_order(parquet, path, label):
    # Only these fixture families request spatial ordering. Partitioned and
    # other unordered exports have no physical-order contract.
    if not path.name.startswith(("multi-", "dimensions-", "null-", "empty-", "ordered-row-groups-")):
        return
    primary = json.loads(parquet.metadata.metadata[b"geo"])["primary_column"]
    values = parquet.read(columns=[primary]).column(0).to_pylist()
    geometries = [None if value is None else shapely.from_wkb(value) for value in values]
    missing = [geometry is None or bool(shapely.is_empty(geometry)) for geometry in geometries]
    assert missing == sorted(missing), (label, path, "NULL/EMPTY must follow nonempty geometries")
    nonempty = [geometry for geometry, absent in zip(geometries, missing) if not absent]
    if not nonempty:
        print("ORDER_PASS", label, path, "zero nonempty geometries", flush=True)
        return
    boxes = [tuple(shapely.bounds(geometry)) for geometry in nonempty]
    assert all(math.isfinite(value) for box in boxes for value in box), (label, path)
    xmin, ymin = min(box[0] for box in boxes), min(box[1] for box in boxes)
    xmax, ymax = max(box[2] for box in boxes), max(box[3] for box in boxes)
    if xmin == xmax or ymin == ymax:
        # The exporter deliberately assigns NULL Hilbert indices to a
        # degenerate extent, while retaining the NULL/EMPTY-last guarantee.
        print("ORDER_PASS", label, path, "degenerate extent; NULL/EMPTY suffix checked", flush=True)
        return
    xscale, yscale = 65535 / (xmax - xmin), 65535 / (ymax - ymin)
    indices = []
    for box in boxes:
        # ST_Hilbert uses each geometry's envelope center, not its centroid.
        # Keep the operation order used by the independently checked algorithm.
        dx = box[0] + (box[2] - box[0]) / 2
        dy = box[1] + (box[3] - box[1]) / 2
        x, y = int((dx - xmin) * xscale), int((dy - ymin) * yscale)
        assert 0 <= x <= 65535 and 0 <= y <= 65535, (label, path, x, y)
        indices.append(hilbert_index(x, y))
    assert indices == sorted(indices), (label, path, "nonempty Hilbert indices are not nondecreasing")
    print("ORDER_PASS", label, path, len(nonempty), "nonempty geometries followed by",
          sum(missing), "NULL/EMPTY geometries", flush=True)


def compare(left, right):
    left_paths = {p.relative_to(left) for p in left.rglob("*.parquet") if p.is_file()}
    right_paths = {p.relative_to(right) for p in right.rglob("*.parquet") if p.is_file()}
    assert len(left_paths) in (22, 34), (left, len(left_paths))
    assert left_paths == right_paths, (left_paths, right_paths)
    for path in sorted(left_paths):
        a, b = pq.ParquetFile(left / path), pq.ParquetFile(right / path)
        check_physical_order(a, path, "reference")
        check_physical_order(b, path, "candidate")
        assert a.schema.names == b.schema.names, path
        assert a.metadata.num_rows == b.metadata.num_rows, path
        assert a.num_row_groups == b.num_row_groups, path
        ag = json.loads(a.metadata.metadata[b"geo"])
        bg = json.loads(b.metadata.metadata[b"geo"])
        assert ag["version"] == bg["version"], path
        assert ag["primary_column"] == bg["primary_column"], path
        assert set(ag["columns"]) == set(bg["columns"]), path
        for name in ag["columns"]:
            am, bm = dict(ag["columns"][name]), dict(bg["columns"][name])
            ac, bc = am.pop("crs"), bm.pop("crs")
            assert am == bm, (path, name)
            if ac is None or bc is None:
                assert ac is None and bc is None, (path, name)
            else:
                assert CRS.from_json_dict(ac).equals(CRS.from_json_dict(bc), ignore_axis_order=True), (path, name)
        for i in range(len(a.schema)):
            ac, bc = a.schema.column(i), b.schema.column(i)
            assert ac.path == bc.path and ac.physical_type == bc.physical_type, (path, i)
            assert ac.max_definition_level == bc.max_definition_level, (path, i)
            assert ac.max_repetition_level == bc.max_repetition_level, (path, i)
            al = json.loads(ac.logical_type.to_json())
            bl = json.loads(bc.logical_type.to_json())
            ac_crs, bc_crs = al.pop("crs", None), bl.pop("crs", None)
            assert al == bl, (path, i, al, bl)
            if ac_crs is not None or bc_crs is not None:
                assert ac_crs is not None and bc_crs is not None, (path, i)
                assert CRS.from_json(ac_crs).equals(CRS.from_json(bc_crs), ignore_axis_order=True), (path, i)
            for j in range(a.num_row_groups):
                ar, br = a.metadata.row_group(j), b.metadata.row_group(j)
                assert ar.num_rows == br.num_rows, (path, j)
                ach, bch = ar.column(i), br.column(i)
                assert ach.compression == bch.compression, (path, i, j)
                ast, bst = ach.geo_statistics, bch.geo_statistics
                if ast is None or bst is None:
                    assert ast is None and bst is None, (path, i, j)
                else:
                    assert set(ast.geospatial_types) == set(bst.geospatial_types), (path, i, j)
                    for dim in "xyzm":
                        for bound in ("min", "max"):
                            attribute = dim + bound
                            assert getattr(ast, attribute) == getattr(bst, attribute), (path, i, j, attribute)
        av, bv = a.read().to_pylist(), b.read().to_pylist()
        if not path.name.startswith("ordered-row-groups-"):
            av, bv = sorted(av, key=lambda row: row["id"]), sorted(bv, key=lambda row: row["id"])
        assert av == bv, path
        print("EQUIVALENT", path, flush=True)
    return len(left_paths)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("reference", type=Path)
    parser.add_argument("candidate", type=Path)
    args = parser.parse_args()
    total = compare(args.reference, args.candidate)
    print(json.dumps({"equivalent_files": total, "reference": str(args.reference),
                      "candidate": str(args.candidate)}))
