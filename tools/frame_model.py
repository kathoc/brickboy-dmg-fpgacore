#!/usr/bin/env python3
"""Whole-frame model of the Pocket pipeline: brick_color -> brick_grid.

Puts the per-stage models together with brick_video's caster selection, so a
frame rendered here can be laid next to the same frame out of brickboy's own
renderfarm (tools/bb_render.mjs) and compared pixel for pixel.

Persistence (brick_ghost) is a no-op on a still frame, so it is not modelled.
"""

import numpy as np

import color_model
import grid_rtl
import bake_grain


def grain_field(w, h, seed=7, k_fine=167, gain=1.166):
    """What brick_grain.sv produces, in +-127 units."""
    gx, gy = np.meshgrid(np.arange(w), np.arange(h))
    q = bake_grain.to_q(bake_grain.bake_coarse(seed) * bake_grain.UNIT_SIGMA * gain)
    q = np.where(q > 127, q - 256, q).astype(np.int64)
    cx, cy = gx >> 4, gy >> 4
    fx, fy = gx & 15, gy & 15
    lo = q[cy, cx] + ((q[cy + 1, cx] - q[cy, cx]) * fy >> 4)
    hi = q[cy, cx + 1] + ((q[cy + 1, cx + 1] - q[cy, cx + 1]) * fy >> 4)
    coarse = lo + ((hi - lo) * fx >> 4)
    hsh = bake_grain.hash2(gx >> 1, gy >> 1, int(round(seed * 1013)))
    fine = np.floor(hsh * 256).astype(np.int64) - 128
    return np.clip(coarse + ((fine * k_fine) >> 8), -127, 127)


def render(shades, grain=True):
    """shades: 144x160 of 0..3. Returns 576x640x3 uint8."""
    base = color_model.process_frame(shades)
    h, w, _ = base.shape
    out = np.zeros((h * 4, w * 4, 3), dtype=np.uint8)
    g = grain_field(w * 4, h * 4) if grain else np.zeros((h * 4, w * 4), np.int64)

    def dark(y, x):
        # Outside the dot field nothing casts, matching the shader, where the
        # colour pass writes the bare panel colour beyond the active area.
        if y < 0 or x < 0:
            return 0
        return 255 - grid_rtl.luma8([int(v) for v in base[y, x]])

    for y in range(h):
        for x in range(w):
            c = tuple(int(v) for v in base[y, x])
            # brick_video's caster rule: back along the light direction by 1 dot
            # for the umbra, and the mean of 2 and 3 dots for the penumbra.
            near = dark(y - 1, x - 1)
            far = (dark(y - 2, x - 2) + dark(y - 3, x - 3)) >> 1
            out[y * 4:y * 4 + 4, x * 4:x * 4 + 4] = \
                grid_rtl.cell(c, near, far, k_paper=0)

    if grain:
        v = out.astype(np.int64)
        d = (v * 8 * g[:, :, None]) >> 15
        out = np.clip(v + d, 0, 255).astype(np.uint8)
    return out
