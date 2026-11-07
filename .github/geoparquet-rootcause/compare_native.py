"""Compare identical plain-SQL Parquet exports written through Python and R drivers.

Characterizes writer behavior without duckspatial. Requires PyArrow.
"""
import json
from pathlib import Path
import sys
import pyarrow.parquet as pq

root=Path(sys.argv[1])
cases=json.loads((Path(__file__).with_name("cases.json")).read_text())
rows=[]
for name in cases:
    for version in ["V1","V2"]:
        record={"case":name,"version":version}
        for driver in ["python","r"]:
            file=root/driver/f"{name}-{version.lower()}.parquet"
            state={"exists":file.exists()}
            if file.exists():
                table=pq.ParquetFile(file)
                md=table.metadata.metadata or {}
                raw=json.loads(md[b"geo"]) if b"geo" in md else None
                state.update({"rows":table.metadata.num_rows,"has_geo":raw is not None,
                  "version":raw.get("version") if raw else None,
                  "primary_column":raw.get("primary_column") if raw else None,
                  "geometry_columns":sorted(raw.get("columns",{})) if raw else [],
                  "crs_fields":{k:("missing" if "crs" not in v else
                         "unknown" if v["crs"] is None else "defined")
                         for k,v in raw.get("columns",{}).items()} if raw else {},
                  "types":{col.name:{"physical":col.physical_type,
                         "logical":json.loads(col.logical_type.to_json()).get("Type")}
                    for col in table.schema}})
            record[driver]=state
        record["same_semantics"]=record["python"]==record["r"]
        rows.append(record)
        print(json.dumps(record),flush=True)
(root/"native-comparison.json").write_text(json.dumps(rows,indent=2)+"\n")
different=[x for x in rows if not x["same_semantics"]]
print(f"NATIVE_COMPARISON: {len(rows)} cases, {len(different)} Python/R metadata differences")
(root/"native-comparison.md").write_text(
  "# Native DuckDB V2 root-cause controls\n\n"
  + f"Identical SQL from Python and R, no duckspatial: {len(rows)} cases. "
  + f"Semantic metadata differences: {len(different)}.\n\n"
  + "| Case | Version | Python geo | R geo | Same metadata? |\n"
  + "|---|---|---|---|---|\n"
  + "".join(f"| {x['case']} | {x['version']} | {x['python'].get('has_geo')} "
     f"| {x['r'].get('has_geo')} | {x['same_semantics']} |\n" for x in rows)
);
