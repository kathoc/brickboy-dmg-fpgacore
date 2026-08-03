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
    return finish(out)


CX, CY, HALF = 19661, 47186, 32768
SX, SY = 99864, 110376
K_GRAD = K_VIGN = 10486
K_FGRAIN = 3
LUT_SQRT = [min(int(round((min((i + 0.5) / 256, 1.0)) ** 0.5 * 65536)), 65535)
            for i in range(256)]


def finish(img):
    """brick_finish: brickboy's FRAG_PASSTHROUGH gradient, vignette and matte
    grain, in the same fixed point the RTL uses."""
    h, w, _ = img.shape
    gx, gy = np.meshgrid(np.arange(w), np.arange(h))
    ux = ((gx + 16) * SX >> 10) & 0xFFFF
    uy = (65535 - ((gy + 16) * SY >> 10)) & 0xFFFF
    dx, dy = ux - CX, uy - CY
    vx, vy = ux - HALF, uy - HALF
    r2s = np.minimum((dx * dx + dy * dy) >> 16, 65535)
    prox = 65536 - np.array(LUT_SQRT)[r2s >> 8]
    grad = ((prox - 32768) * K_GRAD) >> 16
    vign = (((vx * vx + vy * vy) >> 16) * K_VIGN) >> 16
    fac = 65536 + grad - vign

    hsh = bake_grain.hash2(gx, gy, 0x5bd1e995 & 0xFF)   # stand-in for mix32
    fg = np.floor(hsh * 256).astype(np.int64) - 128

    v = img.astype(np.int64)
    p = (v * fac[:, :, None] + 32768) >> 16
    q = p + ((K_FGRAIN * fg) >> 7)[:, :, None]
    return np.clip(q, 0, 255).astype(np.uint8)
