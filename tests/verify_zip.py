#!/usr/bin/env python3
"""Check the release zip's CRCs, decompress it, and run verify_zip.lua.

Usage (from Gen3Mod): python3 coop/tests/verify_zip.py g3-coop-0.1.0.zip [scratch dir]
"""
import json
import os
import subprocess
import sys
import tempfile
import zipfile

here = os.path.dirname(os.path.abspath(__file__))
gen3 = os.path.dirname(os.path.dirname(here))
archive = os.path.abspath(sys.argv[1])
work = sys.argv[2] if len(sys.argv) > 2 else tempfile.mkdtemp(prefix="g3coop-zip-")
os.makedirs(work, exist_ok=True)

with zipfile.ZipFile(archive) as zf:
    bad = zf.testzip()
    if bad:
        sys.exit(f"CRC failure in {bad}")
    entries = {}
    for info in zf.infolist():
        if info.is_dir():
            continue
        if info.filename.startswith("/") or ".." in info.filename.split("/"):
            sys.exit(f"unsafe path in archive: {info.filename}")
        entries[info.filename] = zf.read(info).decode("latin-1")
    extracted = os.path.join(work, "g3_coop")
    zf.extractall(extracted)

# latin-1 round-trips every byte; Lua's JSON decoder hands them back as bytes
entries_path = os.path.join(work, "entries.json")
with open(entries_path, "w", encoding="latin-1") as fh:
    json.dump(entries, fh, ensure_ascii=False)

engine = os.path.join(gen3, "dev-engine")
result = subprocess.run(
    ["luajit", os.path.join(here, "verify_zip.lua"), archive, entries_path, extracted],
    cwd=engine)
sys.exit(result.returncode)
