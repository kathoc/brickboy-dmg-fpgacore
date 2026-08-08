#!/usr/bin/env python3
"""Grid stage: the shader's FRAG_GRID evaluated at 4x, next to brick_grid.sv.

The point of this file is to answer one question honestly: at 4x upscale, what
modulation does brickboy's OWN shader produce? The figures in
display-pipeline.md 4-3 were measured at brickboy's normal display scale, where
one native cell is 10+ device pixels and the 0.20-cell gap is fully resolved.
At 4x the gap is 0.8 output pixels wide, and the shader's fwidth prefilter
widens the smoothstep edge to one pixel - so the shader itself cannot reach
17.3% here. The port target is what the shader does at 4x, not the doc number.
"""

import numpy as np

REAL = False                               # Panel Colour: 1 = dmg-real
BG = (np.array([0.74, 0.673, 0.329]) if REAL   # grid.bgTint
      else np.array([0.93, 0.85, 0.586]))
SHADOW_OPACITY = 0.6                       # grid.shadowOpacity
BASELINE_ALPHA = 0.0 if REAL else 0.10
GRID_CONTRAST = 0.95
STRENGTH = 1.0 if REAL else 0.62           # grid.strength
PIXEL_SIZE = 0.80

SCALE = 4


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def body_axis(scale=SCALE, pixel_size=PIXEL_SIZE):
    """The shader's per-sub-pixel body mask on one axis.

    fw = 1/scale cells per device pixel, so e = max(margin, fw); the fragment
    centre of sub-pixel s sits at (s + 0.5)/scale.
    """
    margin = np.clip((1.0 - pixel_size) * 0.5 + 0.10, 0.0, 0.42)
    fw = 1.0 / scale
    e = max(margin, fw)
    cell = (np.arange(scale) + 0.5) / scale
    return smoothstep(0.0, e, cell) * smoothstep(0.0, e, 1.0 - cell)


def body_axis_integrated(scale=SCALE, pixel_size=PIXEL_SIZE):
    """What brick_grid.sv's table actually holds: the integral of the UNwidened
    smoothstep over each sub-pixel. Kept for the comparison."""
    margin = np.clip((1.0 - pixel_size) * 0.5 + 0.10, 0.0, 0.42)
    t = np.linspace(0.0, 1.0, 4001)
    m = smoothstep(0.0, margin, t) * smoothstep(0.0, margin, 1.0 - t)
    return np.array([m[(t >= s / scale) & (t < (s + 1) / scale)].mean()
                     for s in range(scale)])


def grid_cell(base, axis, drop=0.0):
    """base: linear RGB of one native dot. Returns scale x scale x 3."""
    gap = BG * (1.0 - SHADOW_OPACITY * 0.4)
    lit = BG + (base - BG) * (1.0 - BASELINE_ALPHA)
    body = np.outer(axis, axis)[:, :, None]
    gridded = gap + (lit - gap) * body
    gridded = (gridded - 0.5) * GRID_CONTRAST + 0.5
    return base + (gridded - base) * STRENGTH


def modulation(cell):
    lum = cell @ np.array([0.299, 0.587, 0.114])
    return (lum.max() - lum.min()) / lum.mean()


if __name__ == "__main__":
    import color_model

    shades = np.zeros((16, 16), dtype=np.uint8)
    ax_shader = body_axis()
    ax_rtl = body_axis_integrated()
    print(f"body axis  shader@4x {np.round(ax_shader * 255).astype(int)}")
    print(f"body axis  brick_grid.sv {np.round(ax_rtl * 255).astype(int)}")
    print()
    print("shade   shader@4x   brick_grid.sv   doc(large scale)")
    doc = {0: 3.7, 1: 17.3, 3: 31.4}
    for s in (0, 1, 2, 3):
        flat = np.full((16, 16), s, dtype=np.uint8)
        base = color_model.process_frame(flat, crosstalk=False)[8, 8] / 255.0
        a = modulation(grid_cell(base, ax_shader)) * 100
        b = modulation(grid_cell(base, ax_rtl)) * 100
        d = f"{doc[s]:.1f}%" if s in doc else "-"
        print(f"  {s}     {a:6.2f}%      {b:6.2f}%        {d}")
