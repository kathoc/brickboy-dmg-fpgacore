#!/bin/bash
# Package a built core for the SD card.
#
#   ./build/package.sh M21
#
# Stamps the milestone into core.json's version so the Pocket's core info
# screen says which build is on the card - doing that by hand is how the
# version and the bitstream drift apart.
set -euo pipefail

MS="${1:?usage: package.sh <milestone>, e.g. M23 or M23-testA}"

# Diagnostic packages MUST get their own milestone string. Four packages went
# out stamped M22 and there was no way to tell from the Pocket which one was on
# the card, which is precisely what the stamp exists to prevent.
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

# interact.json goes on the card WITHOUT pretty-printing. The Pocket reads it
# into a fixed buffer somewhere just over 9 KiB, and indentation is most of the
# file - 9682 bytes formatted against 4680 the same content compact. Going over
# does not truncate the menu, it stops the core loading, and the failure looks
# exactly like a bad bitstream. pkg/ keeps the readable copy for editing.
python3 - "$CORE/interact.json" <<'PYEOF'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
d = json.loads(p.read_text())
p.write_text(json.dumps(d, separators=(",", ":")))
print(f"  interact.json {p.stat().st_size} bytes")
PYEOF

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
