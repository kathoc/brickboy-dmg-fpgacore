#!/usr/bin/env python3
"""Bit-exact model of brick_grid.sv, for measuring modulation without a build.

Mirrors the RTL stage for stage. Compared against the real shader's numbers from
retroarch/tools/measure_grid.py, which is the port target at 4x - the figures in
display-pipeline.md 4-3 were taken at brickboy's own display scale, where the
0.20-cell gap is fully resolved, and are not reachable at 4x by the shader
itself.
"""

import numpy as np

GAP = (180, 165, 113)
BG = (237, 217, 149)
DROP = (101, 100, 57)

K_BASEA, K_GRIDC, K_STR, K_DROP, K_PAPER = 26, 243, 159, 87, 9

AXIS_COV = [153, 255, 255, 153]


def _ss(v, lo, hi):
    t = (v / 255 - lo) / (hi - lo)
    if t <= 0:
        return 0
    if t >= 1:
        return 255
    return round(255 * t * t * (3 - 2 * t))


LUT_SS_NEAR = [_ss(v, 0.40, 0.75) for v in range(256)]
LUT_SS_FAR = [_ss(v, 0.34, 0.80) for v in range(256)]


def mix8(a, b, k):
    return a + (((b - a) * k) >> 8)


def sat8(v):
    return 0 if v < 0 else 255 if v > 255 else int(v)


def luma8(c):
    return (77 * c[0] + 150 * c[1] + 29 * c[2]) >> 8


def gcon(v):
    return sat8((((v - 128) * K_GRIDC) >> 8) + 128)


def cell(base, near_d=0, far_d=0, grain=128, axis=None, k_paper=K_PAPER):
    """base: RGB888 of this dot. near_d/far_d: caster darkness at the two
    shadow offsets (see brick_video). Returns 4x4x3 uint8."""
    axis = AXIS_COV if axis is None else axis
    lit = [mix8(BG[i], base[i], 255 - K_BASEA) for i in range(3)]
    e_gap = [mix8(base[i], gcon(GAP[i]), K_STR) for i in range(3)]
    e_dot = [mix8(base[i], gcon(lit[i]), K_STR) for i in range(3)]

    ss = LUT_SS_NEAR[near_d] + ((LUT_SS_FAR[far_d] * 115) >> 8)
    ss = min(ss, 255)
    amt2 = (ss * K_DROP) >> 8

    out = np.zeros((4, 4, 3), dtype=np.uint8)
    for sy in range(4):
        for sx in range(4):
            body = (axis[sx] * axis[sy]) >> 8
            g = [mix8(e_gap[i], e_dot[i], body) for i in range(3)]
            own = LUT_SS_NEAR[255 - luma8(g)]
            amt3 = (amt2 * (255 - own)) >> 8
            s = [mix8(g[i], DROP[i], amt3) for i in range(3)]
            gr = grain - 128
            out[sy, sx] = [sat8(s[i] + (((s[i] * k_paper) * gr) >> 15))
                           for i in range(3)]
    return out


def modulation(c):
    lum = c.astype(np.float64) @ np.array([0.299, 0.587, 0.114])
    return (lum.max() - lum.min()) / lum.mean()


if __name__ == "__main__":
    import color_model

    # The shader at 4x, measured with retroarch/tools/measure_grid.py.
    shader4x = [5.33, 6.90, 17.65, 36.31]

    variants = {
        "current (cov 153)": AXIS_COV,
        "shader cov @4x   ": [128, 255, 255, 128],
    }
    print("            " + "".join(f"  shade{s}" for s in range(4)))
    print("shader @4x  " + "".join(f"  {v:5.2f}%" for v in shader4x))
    for name, axis in variants.items():
        row = []
        for s in range(4):
            base = color_model.process_frame(
                np.full((8, 8), s, dtype=np.uint8), crosstalk=False)[4, 4]
            d = 255 - luma8([int(v) for v in base])
            row.append(modulation(cell(tuple(int(v) for v in base),
                                       d, d, axis=axis)) * 100)
        print(f"{name}  " + "".join(f"  {v:5.2f}%" for v in row))
