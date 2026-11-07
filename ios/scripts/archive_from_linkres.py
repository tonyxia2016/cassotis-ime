#!/usr/bin/env python3
"""Pack the objects FPC would have linked into one static archive, plus any
objects named after the archive (the Core ML runtime of the character LM)."""
import pathlib, subprocess, sys

out, archive = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
extra = [str(pathlib.Path(p)) for p in sys.argv[3:]]
candidates = sorted(out.glob("linkfiles*.res"))
if len(candidates) != 1:
    sys.exit(f"expected one linkfiles*.res in {out}, found {candidates}")
link_res = candidates[0]
objects = []
for line in link_res.read_text().splitlines():
    line = line.strip()
    if line.endswith(".o") and line not in objects:
        objects.append(line)
if not objects:
    sys.exit("link.res lists no objects:\n" + link_res.read_text()[:2000])
archive.unlink(missing_ok=True)
subprocess.check_call(["xcrun", "libtool", "-static", "-no_warning_for_no_symbols",
                       "-o", str(archive), *objects, *extra])
print(f"{len(objects)} + {len(extra)} objects -> {archive}")
