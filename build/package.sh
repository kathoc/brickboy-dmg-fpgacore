#!/bin/bash
# Package a built core for the SD card.
#
#   ./build/package.sh M21
#
# Stamps the milestone into core.json's version so the Pocket's core info
# screen says which build is on the card - doing that by hand is how the
# version and the bitstream drift apart.
set -euo pipefail

MS="${1:?usage: package.sh <milestone>, e.g. M21}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/build/sdcard/Cores/fugudaro.BrickBoy"
RBF="$ROOT/src/output_files/ap_core.rbf"

[ -f "$RBF" ] || { echo "no bitstream at $RBF - build first"; exit 1; }

# The Pocket wants each byte of the RBF bit-reversed.
python3 "$ROOT/build/rbf_reverse.py" "$RBF" "$ROOT/build/brickboy.rbf_r" >/dev/null

BASE=$(python3 - "$ROOT" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]) / "pkg/Cores/fugudaro.BrickBoy/core.json"
print(json.loads(p.read_text())["core"]["metadata"]["version"].split("-")[0])
PY
)

cp "$ROOT/build/brickboy.rbf_r" "$CORE/"
for f in "$ROOT"/pkg/Cores/fugudaro.BrickBoy/*; do cp "$f" "$CORE/"; done

python3 - "$CORE" "$BASE" "$MS" <<'PY'
import json, pathlib, subprocess, sys
core, base, ms = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
p = core / "core.json"
d = json.loads(p.read_text())
d["core"]["metadata"]["version"] = f"{base}-{ms}"
d["core"]["metadata"]["date_release"] = subprocess.run(
    ["date", "+%Y-%m-%d"], capture_output=True, text=True).stdout.strip()
p.write_text(json.dumps(d, indent=2) + "\n")
print(f'  version {d["core"]["metadata"]["version"]}')
PY

OUT="$ROOT/build/brickboy-pocket-${MS,,}.zip"
rm -f "$OUT"
(cd "$ROOT/build/sdcard" && zip -qr "$OUT" .)
ls -l "$OUT"
