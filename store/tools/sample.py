"""Cuts a small Health app export for App Review out of the simulator's synthetic one.

    python3 -I store/tools/sample.py build/apple/apple_health_export out.zip

Keeps every record and workout that starts in the first two weeks of September 2026 (the
seeded month, so it has workouts with routes, sleep, blood pressure and the rest), plus the
route files those workouts point to. The data is made up by Seeder.swift; nobody's real Health.
"""
import re
import sys
import zipfile
from pathlib import Path

FROM, TO = "2026-09-01", "2026-09-15"

src, out = Path(sys.argv[1]), Path(sys.argv[2])
start = re.compile(r'startDate="(\d{4}-\d{2}-\d{2})')
route = re.compile(r'<FileReference path="/([^"]+)"')

kept, block, name, routes, records = [], [], None, set(), 0
with open(src / "export.xml", encoding="utf-8") as f:
    body = False
    for line in f:
        if not body:
            kept.append(line)
            body = line.startswith(" <Me ")
            continue
        if line.startswith("</HealthData>"):
            break
        if name is None:
            block = [line]
            if line.rstrip().endswith("/>"):
                done = True
            else:
                name = line.split()[0][1:]
                continue
        else:
            block.append(line)
            done = line.startswith(" </" + name + ">")
            if not done:
                continue
        name = None
        m = start.search(block[0])
        if m and FROM <= m.group(1) < TO:
            kept += block
            records += 1
            for b in block:
                r = route.search(b)
                if r:
                    routes.add(r.group(1))
kept.append("</HealthData>\n")

with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("apple_health_export/export.xml", "".join(kept))
    for r in sorted(routes):
        z.write(src / r, "apple_health_export/" + r)
print(f"{records} top-level entries, {len(routes)} routes, {out.stat().st_size // 1024} KB")
