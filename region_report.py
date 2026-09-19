#!/usr/bin/env python3
"""Compare the updatelist.xml responses collected by region_probe.sh."""

import hashlib
import os
import sys
import xml.etree.ElementTree as ET
from collections import OrderedDict, defaultdict
from urllib.parse import urlparse, parse_qs

out = sys.argv[1] if len(sys.argv) > 1 else "region_probe_out"
xml_dir = os.path.join(out, "xml")

status = {}
with open(os.path.join(out, "results.tsv")) as fh:
    next(fh)
    for line in fh:
        cc, ip, http, byts, body = line.rstrip("\n").split("\t")
        status[cc] = dict(ip=ip, http=http, bytes=int(byts), body=body)


def fields(path):
    """Flatten one updatelist.xml into comparable name -> value fields."""
    f = OrderedDict()
    root = ET.parse(path).getroot()
    region = root.find("region")
    f["region_id"] = region.get("id") if region is not None else "(none)"

    fu = region.find("force_update/system") if region is not None else None
    if fu is not None:
        f["force_update.upd_version"] = fu.get("upd_version")
        f["force_update.sdk_version"] = fu.get("sdk_version")
        reqs = sorted(
            "%s:%s" % (c.get("id"), c.get("upd_version"))
            for c in fu.findall("conditional_requirement")
        )
        f["force_update.requirement_count"] = str(len(reqs))
        f["force_update.requirements"] = ",".join(reqs)

    pup = region.find("system_pup") if region is not None else None
    if pup is not None:
        f["system_pup.label"] = pup.get("label")
        f["system_pup.upd_version"] = pup.get("upd_version")
        f["system_pup.sdk_version"] = pup.get("sdk_version")
        for data in pup.findall("update_data"):
            kind = data.get("update_type")
            img = data.find("image")
            if img is None:
                continue
            f["image[%s].size" % kind] = img.get("size")
            url = (img.text or "").strip()
            u = urlparse(url)
            parts = u.path.strip("/").split("/")
            f["image[%s].host" % kind] = u.netloc
            f["image[%s].token" % kind] = parts[3] if len(parts) > 3 else "?"
            f["image[%s].build_date" % kind] = parts[5] if len(parts) > 5 else "?"
            f["image[%s].file_hash" % kind] = parts[6] if len(parts) > 6 else "?"
            f["image[%s].dest" % kind] = ",".join(parse_qs(u.query).get("dest", ["-"]))

    tests = sorted(
        "%s/%s" % (t.get("upd_version"), t.get("sdk_version"))
        for t in (region.findall("finished_test_list/finished_test") if region is not None else [])
    )
    f["finished_tests"] = ",".join(tests) if tests else "(none)"
    return f


parsed, broken = {}, {}
for cc in sorted(status):
    path = os.path.join(xml_dir, "%s.xml" % cc)
    if not os.path.exists(path):
        continue
    try:
        parsed[cc] = fields(path)
    except ET.ParseError as exc:
        broken[cc] = str(exc)

served = sorted(parsed)
print("== Reachability ==")
by_http = defaultdict(list)
for cc, s in status.items():
    by_http[s["http"] if s["ip"] != "-" else "DNS_FAIL"].append(cc)
for code in sorted(by_http):
    ccs = sorted(by_http[code])
    print("%-10s %3d  %s" % (code, len(ccs), " ".join(ccs)))
if broken:
    print("\nnot XML: %s" % " ".join(sorted(broken)))

print("\n== Identical response bodies ==")
groups = defaultdict(list)
for cc in served:
    with open(os.path.join(xml_dir, "%s.xml" % cc), "rb") as fh:
        groups[hashlib.sha256(fh.read()).hexdigest()[:12]].append(cc)
for digest, ccs in sorted(groups.items(), key=lambda kv: -len(kv[1])):
    print("%s  %3d regions  %s" % (digest, len(ccs), " ".join(sorted(ccs))))

print("\n== Field differences across %d served regions ==" % len(served))
names = []
for cc in served:
    for k in parsed[cc]:
        if k not in names:
            names.append(k)
for name in names:
    values = defaultdict(list)
    for cc in served:
        values[parsed[cc].get(name, "(absent)")].append(cc)
    if len(values) == 1:
        val = next(iter(values))
        show = val if len(val) <= 90 else val[:87] + "..."
        print("  [same] %-32s %s" % (name, show))
    else:
        print("  [DIFF] %-32s %d distinct values" % (name, len(values)))
        for val, ccs in sorted(values.items(), key=lambda kv: -len(kv[1])):
            show = val if len(val) <= 70 else val[:67] + "..."
            print("         %-70s %3d  %s" % (show, len(ccs), " ".join(sorted(ccs))))
