"""Independent semantic comparison of direct DuckDB COPY, legacy duckspatial,
and enhanced GeoParquet exports using the same source fixture scenarios.

Not byte-for-byte comparison; reports concrete metadata, geometry and schema
differences. The enhanced writer's known-valid outputs are reference values,
not a specification substitute. This is a characterization experiment.
"""
from __future__ import annotations
import csv
import json
from pathlib import Path
from collections import defaultdict
import sys
import pyarrow.parquet as pq
from pyproj import CRS
import shapely

root = Path(sys.argv[1])
lanes = ("enhanced", "legacy", "direct")
rows = []
for lane in lanes:
    with (root/lane/"write-log.csv").open(newline="") as f:
        rows.extend(dict(x) for x in csv.DictReader(f))
statuses = {(r["lane"],r["case"]):r for r in rows}
files = {}
for lane in lanes:
    for p in (root/lane).rglob("*.parquet"):
        if p.is_file():
            rel = p.relative_to(root/lane)
            case = str(rel).split("/",1)[0]
            files.setdefault((lane,case),[]).append(p)
results = []
def load(p):
    f = pq.ParquetFile(p)
    md = f.metadata.metadata or {}
    geo = json.loads(md.get(b"geo",b"{}"))
    cols = {}
    for c in f.schema.names:
        field = f.schema.column(f.schema.names.index(c))
        logical = json.loads(field.logical_type.to_json())
        cols[c] = {"physical":field.physical_type,
                   "logical":logical.get("Type"),
                   "compression":f.metadata.row_group(0).column(
                       f.schema.names.index(c)).compression
                      if f.num_row_groups else None}
    payload = f.read().to_pylist()
    return {"geo":geo,"rows":payload,"cols":cols,"path":str(p)}
def compare_crs(a,b):
    if a is None or b is None:
        return a is b
    try:
        return CRS.from_json_dict(a).equals(
          CRS.from_json_dict(b),ignore_axis_order=True)
    except Exception:
        return False
def geom_equal(x,y):
    if x is None or y is None:
        return x is y
    try:
        return bool(shapely.equals_identical(shapely.from_wkb(x),shapely.from_wkb(y)))
    except Exception:
        return False
def evaluate(case, lane, target):
    ours = files.get(("enhanced",case),[])
    other = files.get((lane,case),[])
    if not ours or not other:
        return {"equal":False,"issues":["file_missing_or_write_failed"],
                "enhanced_files":len(ours),"other_files":len(other)}
    # Flatten partition files, but retain partition column as a source field.
    a=[load(x) for x in ours]
    b=[load(x) for x in other]
    issues=[]
    if len(a)!=len(b): issues.append("partition_file_count")
    # Cases can have partition directories named differently; compare across all rows.
    aa=[x for f in a for x in f["rows"]]
    bb=[x for f in b for x in f["rows"]]
    if len(aa)!=len(bb):issues.append("row_count")
    def indexed(rr):
        if any("id" not in x for x in rr):return None
        vals={}
        for x in rr: vals.setdefault(str(x["id"]),[]).append(x)
        return vals
    ai=indexed(aa);bi=indexed(bb)
    if ai is None or bi is None:issues.append("missing_id")
    elif ai.keys()!=bi.keys():issues.append("row_identifiers")
    amag=a[0]["geo"];bmag=b[0]["geo"]
    for key in ("version","primary_column"):
        if amag.get(key)!=bmag.get(key):issues.append("geo_"+key)
    acol=amag.get("columns",{});bcol=bmag.get("columns",{})
    if set(acol)!=set(bcol):issues.append("geometry_column_set")
    common=set(acol)&set(bcol)
    for col in sorted(common):
        ac=acol[col];bc=bcol[col]
        # Missing CRS has CRS84 meaning; explicit null denotes unknown.
        if ("crs" in ac)!=("crs" in bc):
            issues.append("crs_missing_vs_explicit_"+col)
        elif not compare_crs(ac.get("crs"),bc.get("crs")):
            issues.append("crs_mismatch_"+col)
        if ac.get("encoding")!=bc.get("encoding"):issues.append("encoding_"+col)
    if ai is not None and bi is not None:
        for key in ai.keys()&bi.keys():
            if len(ai[key])!=len(bi[key]):
                issues.append("row_multiplicity");break
            ra=ai[key][0];rb=bi[key][0]
            if ra.keys()!=rb.keys():
                issues.append("attribute_column_set");break
            for col in ra:
                if col in (set(acol) | set(bcol)) and (
                    isinstance(ra[col], bytes) or isinstance(rb[col], bytes)
                ):
                    if not geom_equal(ra[col],rb[col]):
                        issues.append("geometry_coordinates_"+col)
                elif ra[col]!=rb[col]:
                    issues.append("attribute_value_"+col)
    for col in common:
        acl=a[0]["cols"].get(col);bcl=b[0]["cols"].get(col)
        if acl and bcl:
            if acl["physical"]!=bcl["physical"]:issues.append("physical_type_"+col)
            if acl["logical"]!=bcl["logical"]:issues.append("native_annotation_"+col)
    def summarize_geo(g):
        def crs_label(entry):
            if "crs" not in entry:return "MISSING (implies CRS84)"
            if entry["crs"] is None:return "null (unknown)"
            try:
                obj=CRS.from_json_dict(entry["crs"])
                authority=obj.to_authority()
                return ":".join(authority) if authority else obj.name
            except Exception as e:
                return "invalid PROJJSON: "+str(e)[:80]
        return {"version":g.get("version", "<missing>"),
                "primary_column":g.get("primary_column", "<missing>"),
                "columns":{name:{"encoding":v.get("encoding"),
                                  "crs":crs_label(v)}
                           for name,v in g.get("columns",{}).items()}}
    return {"equal":not issues,"issues":sorted(set(issues)),
            "enhanced_files":len(a),"other_files":len(b),
            "enhanced_version":amag.get("version"),"other_version":bmag.get("version"),
            "enhanced_geo":summarize_geo(amag),
            "other_geo":summarize_geo(bmag),
            "enhanced_schema":a[0]["cols"],
            "other_schema":b[0]["cols"]}
all_cases=sorted({r["case"] for r in rows})
for case in all_cases:
    for lane in ("legacy","direct"):
        reference=statuses.get(("enhanced",case),{})
        control=statuses.get((lane,case),{})
        if control.get("status")=="skip":
            comparison={"equal":None,"issues":["not_applicable_to_direct_sf"],
                        "enhanced_files":len(files.get(("enhanced",case),[])),
                        "other_files":0}
        else:
            comparison=evaluate(case,lane,control)
        results.append({"case":case,"lane":lane,
                        "reference_status":reference.get("status"),
                        "control_status":control.get("status"),
                        "control_error":control.get("error",""),
                        **comparison})
(root/"comparison.json").write_text(json.dumps(results,indent=2)+"\n")
with (root/"comparison.csv").open("w",newline="") as f:
    cols=["case","lane","reference_status","control_status","equal","issues",
          "control_error","enhanced_files","other_files",
          "enhanced_version","other_version"]
    w=csv.DictWriter(f,fieldnames=cols,extrasaction="ignore")
    w.writeheader()
    for r in results:w.writerow({**r,"issues":";".join(r["issues"])})
counts=defaultdict(int)
for r in results:
    counts[(r["lane"],r["control_status"],str(r["equal"]))]+=1
with (root/"comparison.md").open("w") as f:
    f.write("# Direct DuckDB delegation vs enhanced duckspatial GeoParquet\n\n")
    f.write("Same input fixture scenarios, three independent writer paths. "
            "This compares semantics, not file bytes, sort order or timing. "
            "The direct lane only applies to lazy queries with typed DuckDB geometry.\n\n")
    f.write("## Summary\n\n| Lane | Write status | Semantic match | Cases |\n"
            "|---|---|---|---:|\n")
    for (lane,status,match),n in sorted(counts.items()):
        f.write(f"| {lane} | {status} | {match} | {n} |\n")
    f.write("\n## Differences\n\n")
    for r in results:
        if r["equal"] is True:continue
        f.write(f"- **{r['case']} / {r['lane']}**: {r['control_status']}; "
                f"{', '.join(r['issues']) or 'unknown'}")
        if r["control_error"]:f.write(f"; error: {r['control_error'][:320]}")
        f.write("\n")
        if r.get("enhanced_geo") and r.get("other_geo"):
            f.write("  - enhanced: "+json.dumps(r["enhanced_geo"],ensure_ascii=False)+"\n")
            f.write("  - delegated: "+json.dumps(r["other_geo"],ensure_ascii=False)+"\n")
    f.write("\n## Interpretation limits\n\n"
            "- A failed baseline write does not imply core DuckDB cannot produce "
            "that encoding; it may reflect original duckspatial preprocessing.\n"
            "- WKB V1/V1.1 vs native V2 cannot be expected to be byte-identical.\n"
            "- Spatial sorting is an independent optional optimization; "
            "different record order is not a semantic error.\n"
            "- Failed direct SQL on sf is reported as not applicable, because "
            "DuckDB cannot receive an R sf object without a conversion step.\n"
            "- EPSG/PROJJSON definitions are compared semantically with PyProj.\n")
print((root/"comparison.md").read_text()[:20000])
