#!/usr/bin/env python3
"""Bake brickboy's reflector grain into two small ROMs for the Pocket.

Direct port of src/display/reflector.ts - same hash, same lattices, same band
weights, same seed - so the sheet the FPGA shows is the sheet brickboy shows.

Why two ROMs instead of the one texture brickboy bakes: brickboy stores the
whole module at 4 texels/dot (672x608 = 409k bytes). That is 3.2 Mbit, more than
the 5CEBA4's entire M10K budget, so the bake is split by band the way the noise
itself is split:

  coarse  mottle (~5 dots) + blotch (~18 dots). Varies far more slowly than one
          dot, so it is stored at one value per 2 dots for the whole 160x144
          field and bilinearly interpolated - the same interpolation
          reflector.ts already does per dot when it expands `coarse` to texels.
          80 x 72 bytes.
  fine    the 0.45-dot band. Stored as one 128x128 output-pixel TILE (32 x 32
          dots) and repeated. This is the one deviation: the sheet's fine grain
          repeats every 32 dots instead of never. At 0.45-dot features the
          repeat carries no visible structure, and it is what makes the band
          affordable at all.

The previous RTL had no coarse band and generated the fine band as one
independent hash per output pixel. That is white noise: it averages away
completely at any viewing distance, which is why the grain read as absent on the
Pocket while brickboy's stays visible (measured: brickboy keeps 60% of its grain
sigma after averaging over 16x16 dots; white noise keeps 0.4%).
"""

import argparse
import numpy as np

TEXELS_PER_DOT = 4          # GRAIN_TEXELS_PER_DOT
UNIT_SIGMA = 0.81
SEED = 7                    # dmg.json defects.seed
PAPER_SCALE = 0.45          # dmg.json finish.paperScale

FIELD_W, FIELD_H = 160, 144

# Lattice spacing of the baked coarse band, in native dots. reflector.ts
# evaluates it once per dot; 4 keeps 87% of its sigma for a quarter of the
# storage, and what it drops is the fastest mottle octave (~1.2 dots) - the part
# the eye averages away at the Pocket's pixel pitch anyway. M10K is the scarce
# resource on this device, so this is where the budget goes.
COARSE_DOTS_PER_SAMPLE = 4

M32 = 0xFFFFFFFF


def _i32(v):
    v &= M32
    return v - (1 << 32) if v & 0x80000000 else v


def hash2(x, y, seed):
    """reflector.ts hash2, with JS's int32 multiply and uint32 shifts."""
    x = np.asarray(x, dtype=np.int64)
    y = np.asarray(y, dtype=np.int64)
    h = (x * 374761393 + y * 668265263 + int(seed) * 1442695041) & M32
    h = (h ^ (h >> 13)) & M32
    # Math.imul: 32-bit signed multiply, low 32 bits.
    h = (h * 1274126177) & M32
    h = (h ^ (h >> 16)) & M32
    return h / 4294967296.0


def vnoise(x, y, seed):
    ix = np.floor(x).astype(np.int64)
    iy = np.floor(y).astype(np.int64)
    fx = x - ix
    fy = y - iy
    fx = fx * fx * (3 - 2 * fx)
    fy = fy * fy * (3 - 2 * fy)
    a = hash2(ix, iy, seed)
    b = hash2(ix + 1, iy, seed)
    c = hash2(ix, iy + 1, seed)
    d = hash2(ix + 1, iy + 1, seed)
    return a + (b - a) * fx + (c - a + (d - b - c + a) * fx) * fy


def fbm(x, y, seed):
    v = np.zeros_like(x)
    amp = 0.5
    px, py = x.copy(), y.copy()
    for i in range(3):
        v += amp * vnoise(px, py, seed + i * 101)
        px *= 2.03
        py *= 2.03
        amp *= 0.5
    return v


def bake_coarse(seed):
    """reflector.ts's `coarse` array, subsampled every COARSE_DOTS_PER_SAMPLE."""
    s = int(round(seed * 1013))
    step = COARSE_DOTS_PER_SAMPLE
    w = FIELD_W // step + 1
    h = FIELD_H // step + 1
    cx, cy = np.meshgrid(np.arange(w) * step, np.arange(h) * step)
    cx = cx.astype(np.float64)
    cy = cy.astype(np.float64)
    mottle = fbm(cx / 5, cy / 5, s + 11) - 0.5
    blotch = vnoise(cx / 18, cy / 18, s + 23) - 0.5
    return 1.0 * mottle + 0.5 * blotch


def coarse_reference_sigma(seed):
    """Sigma of reflector.ts's coarse band at its native per-dot resolution."""
    s = int(round(seed * 1013))
    cx, cy = np.meshgrid(np.arange(float(FIELD_W)), np.arange(float(FIELD_H)))
    return (1.0 * (fbm(cx / 5, cy / 5, s + 11) - 0.5)
            + 0.5 * (vnoise(cx / 18, cy / 18, s + 23) - 0.5)).std() * UNIT_SIGMA


def coarse_reconstructed_sigma(q):
    """Sigma of what the RTL actually reconstructs from the baked lattice:
    integer bilinear across 16 output pixels. Interpolation is a low-pass, so it
    loses variance that has to be given back, or the band comes out weak."""
    q = np.where(q > 127, q - 256, q).astype(np.int64)   # to_q packs two's complement
    step = COARSE_DOTS_PER_SAMPLE * TEXELS_PER_DOT
    sh = int(np.log2(step))
    gx, gy = np.meshgrid(np.arange(FIELD_W * TEXELS_PER_DOT),
                         np.arange(FIELD_H * TEXELS_PER_DOT))
    cx, cy = gx >> sh, gy >> sh
    fx, fy = gx & (step - 1), gy & (step - 1)
    lo = q[cy, cx] + ((q[cy + 1, cx] - q[cy, cx]) * fy >> sh)
    hi = q[cy, cx + 1] + ((q[cy + 1, cx + 1] - q[cy, cx + 1]) * fy >> sh)
    return ((lo + ((hi - lo) * fx >> sh)) / 127).std()


def fine_dot_sigmas(seed, n=576):
    """Sigma of reflector.ts's fine band, per texel and averaged to one dot.

    The RTL generates the band as one hash per 2x2 output pixels. That has the
    right feature size and the right per-texel sigma, but its blocks are
    independent where value noise is correlated, so it fades faster when the eye
    (or the panel) averages a dot. The Pocket cannot resolve sub-dot detail at
    all, so the per-DOT figure is the one worth matching.
    """
    s = int(round(seed * 1013))
    fs = max(PAPER_SCALE, 0.1)
    t = np.arange(n) / TEXELS_PER_DOT
    px, py = np.meshgrid(t, t)
    f = ((vnoise(px / fs, py / fs, s)
          + vnoise(px / (fs * 1.7), py / (fs * 1.7), s + 37)) * 0.5 - 0.5)
    f = f * 2.5 * UNIT_SIGMA
    per_dot = f.reshape(n // 4, 4, n // 4, 4).mean((1, 3)).std()
    return f.std(), per_dot


def fine_sigma(seed, n=512):
    """Sigma of reflector.ts's fine band, so the RTL's runtime hash can be
    scaled to it. The band itself is not baked - it is generated on the fly."""
    s = int(round(seed * 1013))
    fs = max(PAPER_SCALE, 0.1)
    t = np.arange(n) / TEXELS_PER_DOT
    px, py = np.meshgrid(t, t)
    f = (vnoise(px / fs, py / fs, s)
         + vnoise(px / (fs * 1.7), py / (fs * 1.7), s + 37)) * 0.5 - 0.5
    return f.std()


def to_q(a, bits=8):
    """Signed two's-complement, full-scale +-1 like the R8 encoding."""
    q = np.round(np.clip(a, -1.0, 1.0) * (2 ** (bits - 1) - 1))
    return q.astype(np.int64) & ((1 << bits) - 1)


def emit(name, arr, path, width_bits=8):
    flat = arr.reshape(-1)
    lines = [f"localparam bit [{width_bits-1}:0] {name}[0:{flat.size-1}] = '{{"]
    for i in range(0, flat.size, 16):
        chunk = ", ".join(f"{width_bits}'d{v}" for v in flat[i:i + 16])
        lines.append("  " + chunk + ("," if i + 16 < flat.size else ""))
    lines.append("};")
    path.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    import pathlib

    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="../src/core")
    ap.add_argument("--seed", type=float, default=SEED)
    args = ap.parse_args()

    out = pathlib.Path(args.out)
    g_coarse = bake_coarse(args.seed) * UNIT_SIGMA

    # Give back what the RTL's bilinear reconstruction loses, so the field the
    # hardware shows has reflector.ts's per-dot sigma rather than a smoothed one.
    q = to_q(g_coarse)
    gain = coarse_reference_sigma(args.seed) / coarse_reconstructed_sigma(q)
    print(f"coarse reconstruction gain x{gain:.3f}")
    g_coarse = g_coarse * gain
    q = to_q(g_coarse)

    # The runtime fine hash is blocky where reflector.ts's is value noise, so it
    # averages away faster; scale it to match at the dot, not at the texel.
    s_fine_texel, s_fine_dot = fine_dot_sigmas(args.seed)
    blocky_dot = s_fine_texel / 2.0        # 2x2 independent blocks per dot
    fine_gain = s_fine_dot / blocky_dot
    s_fine = s_fine_texel * fine_gain
    # Pack lattice row pairs into one word, so the RTL gets both rows of the
    # bilinear from a single read: word(cy, cx) = {row cy+1, row cy}.
    rows, cols = q.shape
    pair = np.zeros((rows - 1, cols), dtype=np.int64)
    for cy in range(rows - 1):
        pair[cy] = (q[cy + 1] << 8) | q[cy]

    print(f"coarse lattice {cols} x {rows} (every {COARSE_DOTS_PER_SAMPLE} dots)"
          f"  reconstructed sigma {coarse_reconstructed_sigma(q):.4f} "
          f"(reflector.ts per dot {coarse_reference_sigma(args.seed):.4f})")
    print(f"fine   runtime hash, 2x2 output px       texel sigma {s_fine:.4f} "
          f"-> per-dot {s_fine/2:.4f} (reflector.ts {s_fine_dot:.4f})")
    # The RTL's fine band is a uniform hash spanning the full +-1, so its sigma
    # is 1/sqrt(3); scale it down to the band's measured sigma.
    print(f"runtime hash scale: {s_fine * 3 ** 0.5:.4f} "
          f"= {round(s_fine * 3 ** 0.5 * 256)}/256")

    emit("GRAIN_COARSE", pair, out / "brick_grain_coarse.svh", width_bits=16)
    print(f"wrote {out}/brick_grain_coarse.svh  "
          f"({pair.size} words x 16 bit, {pair.size*16/1024:.1f} kbit)")
