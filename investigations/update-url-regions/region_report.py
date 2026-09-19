#!/usr/bin/env python3
"""Compare the updatelist.xml responses collected by region_probe.sh.

Reads the probe's results.tsv and the XML bodies beside it, then prints which
codes were served, which hostnames exist, which responses were byte-identical,
and, field by field, what actually differs between the regions.
"""

from __future__ import annotations

import hashlib
import os
import sys
import xml.etree.ElementTree as ElementTree
from collections import OrderedDict, defaultdict
from urllib.parse import parse_qs, urlparse

out = sys.argv[1] if len(sys.argv) > 1 else "region_probe_out"
xml_dir = os.path.join(out, "xml")

status = {}
with open(os.path.join(out, "results.tsv")) as fh:
    header = next(fh).rstrip("\n").split("\t")
    for line in fh:
        row = dict(zip(header, line.rstrip("\n").split("\t"), strict=False))
        status[row["cc"]] = dict(
            f_ip=row.get("f_host_ip", row.get("ip", "-")),
            d_ip=row.get("d_host_ip", "-"),
            http=row["http"],
            bytes=int(row["bytes"]),
            body=row["body_sha256_16"],
            region_id=row.get("region_id", "-"),
        )


def fields(path):
    """Flatten one updatelist.xml into comparable name -> value fields."""
    f = OrderedDict()
    root = ElementTree.parse(path).getroot()
    region = root.find("region")
    f["region_id"] = region.get("id") if region is not None else "(none)"

    force_update = region.find("force_update/system") if region is not None else None
    if force_update is not None:
        f["force_update.upd_version"] = force_update.get("upd_version")
        f["force_update.sdk_version"] = force_update.get("sdk_version")
        requirements = sorted(
            f"{c.get('id')}:{c.get('upd_version')}"
            for c in force_update.findall("conditional_requirement")
        )
        f["force_update.requirement_count"] = str(len(requirements))
        f["force_update.requirements"] = ",".join(requirements)

    pup = region.find("system_pup") if region is not None else None
    if pup is not None:
        f["system_pup.label"] = pup.get("label")
        f["system_pup.upd_version"] = pup.get("upd_version")
        f["system_pup.sdk_version"] = pup.get("sdk_version")
        for data in pup.findall("update_data"):
            kind = data.get("update_type")
            image = data.find("image")
            if image is None:
                continue
            f[f"image[{kind}].size"] = image.get("size")
            url = (image.text or "").strip()
            parsed_url = urlparse(url)
            parts = parsed_url.path.strip("/").split("/")
            f[f"image[{kind}].host"] = parsed_url.netloc
            f[f"image[{kind}].token"] = parts[3] if len(parts) > 3 else "?"
            f[f"image[{kind}].build_date"] = parts[5] if len(parts) > 5 else "?"
            f[f"image[{kind}].file_hash"] = parts[6] if len(parts) > 6 else "?"
            f[f"image[{kind}].dest"] = ",".join(parse_qs(parsed_url.query).get("dest", ["-"]))

    tests = sorted(
        f"{t.get('upd_version')}/{t.get('sdk_version')}"
        for t in (region.findall("finished_test_list/finished_test") if region is not None else [])
    )
    f["finished_tests"] = ",".join(tests) if tests else "(none)"
    return f


parsed, broken = {}, {}
for cc in sorted(status):
    path = os.path.join(xml_dir, f"{cc}.xml")
    if not os.path.exists(path):
        continue
    try:
        parsed[cc] = fields(path)
    except ElementTree.ParseError as exc:
        broken[cc] = str(exc)

served = sorted(parsed)
print("== Update list availability (path segment /list/<cc>/, fixed host) ==")
by_http = defaultdict(list)
for cc, st in status.items():
    by_http[st["http"]].append(cc)
for code in sorted(by_http):
    ccs = sorted(by_http[code])
    print(f"{code:<10} {len(ccs):3d}  {' '.join(ccs)}")

print("\n== Hostname existence (DNS) ==")
for prefix, key in (("f", "f_ip"), ("d", "d_ip")):
    resolving = sorted(cc for cc, st in status.items() if st[key] != "-")
    ips = defaultdict(list)
    for cc in resolving:
        ips[status[cc][key]].append(cc)
    print(f"{prefix}<cc>01 resolves for {len(resolving)} codes: {' '.join(resolving)}")
    for ip, ccs in sorted(ips.items()):
        print(f"    {ip:<16} {len(ccs):3d}  {' '.join(sorted(ccs))}")

print("\n== Served region_id vs requested code ==")
mismatch = sorted(cc for cc, st in status.items() if st["region_id"] not in ("-", cc))
print(
    "echoed back unchanged for every served code"
    if not mismatch
    else "differs for: " + " ".join(f"{cc}->{status[cc]['region_id']}" for cc in mismatch)
)
if broken:
    print(f"\nnot XML: {' '.join(sorted(broken))}")

print("\n== Identical response bodies ==")
groups = defaultdict(list)
for cc in served:
    with open(os.path.join(xml_dir, f"{cc}.xml"), "rb") as fh:
        groups[hashlib.sha256(fh.read()).hexdigest()[:12]].append(cc)
for digest, ccs in sorted(groups.items(), key=lambda kv: -len(kv[1])):
    print(f"{digest}  {len(ccs):3d} regions  {' '.join(sorted(ccs))}")

print(f"\n== Field differences across {len(served)} served regions ==")
names = []
for cc in served:
    for name in parsed[cc]:
        if name not in names:
            names.append(name)
for name in names:
    values = defaultdict(list)
    for cc in served:
        values[parsed[cc].get(name, "(absent)")].append(cc)
    if len(values) == 1:
        value = next(iter(values))
        show = value if len(value) <= 90 else value[:87] + "..."
        print(f"  [same] {name:<32} {show}")
    else:
        print(f"  [DIFF] {name:<32} {len(values)} distinct values")
        for value, ccs in sorted(values.items(), key=lambda kv: -len(kv[1])):
            show = value if len(value) <= 70 else value[:67] + "..."
            print(f"         {show:<70} {len(ccs):3d}  {' '.join(sorted(ccs))}")
