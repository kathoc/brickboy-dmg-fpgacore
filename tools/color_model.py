#!/usr/bin/env python3
"""Bit-exact model of brick_color.sv.

Mirrors the RTL's fixed-point arithmetic operation for operation, so a frame
rendered here is what the hardware will put in its line buffers. Used to
verify the stage against the RetroArch float reference before anything ships.
"""

import numpy as np

PAL = [(219, 207, 136), (140, 179, 102), (71, 130, 66), (33, 92, 43)]
PBG = (237, 217, 149)

K_BLEED, K_OFFTINT, K_XTALK = 41, 13, 44
K_XT_GRAY, K_XT_SIGN, K_XT_CLAMP = 102, 56, 166
K_SAT, K_WARM_R, K_WARM_G, K_WARM_B = 218, 8, 2, 6
K_CONTRAST, K_BRIGHT, K_BLACKL = 225, 225, 26
K_BETA_V, K_WN_V = 235, 20
K_BETA_H, K_WN_H = 226, 30
K_XT_EDGE = 102

DSQ = [0, 28, 114, 255]
DLIN = [0, 85, 170, 255]

LUT_GAMMA = [round(255 * (v / 255) ** 1.1) for v in range(256)]


def _ss(v):
    t = (v / 255 - 0.5) / 0.5
    if t <= 0:
        return 0
    if t >= 1:
        return 255
    return round(255 * t * t * (3 - 2 * t))


LUT_OFFW = [_ss(v) for v in range(256)]


def mix8(a, b, k):
    # +128 rounds instead of truncating; see brick_color.sv's mix8.
    return (a + ((((b - a) * k) + 128) >> 8)) & 0xFF


def luma8(r, g, b):
    return (77 * r + 150 * g + 29 * b + 128) >> 8


def sat8(v):
    return 0 if v < 0 else 255 if v > 255 else v


def tone(v):
    t = ((((v - 128) * K_CONTRAST) + 128) >> 8) + 128
    return sat8(((t * K_BRIGHT) + 128) >> 8)


def upward_field(shades):
    """brick_color's S_UP pre-pass: the 0.4x upward bleed of
    FRAG_COLUMN_REDUCE, sampled every 8 rows and interpolated, exactly as the
    RTL stores and reconstructs it."""
    h, w = shades.shape
    colU = np.zeros(w, dtype=np.int64)
    samples = {}
    for r in range(h - 1, -1, -1):
        if (r & 7) == 0:
            samples[r >> 3] = (colU >> 4).copy()
        colU = (K_BETA_V * (colU + np.array([DSQ[s] for s in shades[r]]))) >> 8
    samples[h >> 3] = np.zeros(w, dtype=np.int64)      # off the bottom

    out = np.zeros((h, w), dtype=np.int64)
    for r in range(h):
        cy, fy = r >> 3, r & 7
        lo = samples[cy]
        hi = samples.get(cy + 1, np.zeros(w, dtype=np.int64))
        out[r] = lo + (((hi - lo) * fy) >> 3)
    return out


def process_frame(shades, crosstalk=True):
    """shades: 144x160 uint8 of 0..3. Returns 144x160x3 uint8."""
    import bake_grain
    h, w = shades.shape
    out = np.zeros((h, w, 3), dtype=np.uint8)
    colA = [0] * w
    upfld = upward_field(shades) if crosstalk else np.zeros(shades.shape, np.int64)
    xtcol = bake_grain.bake_xtalk_columns() if crosstalk else np.zeros(w, np.int64)

    for y in range(h):
        rowH = 0
        up = shades[max(y - 1, 0)]
        cur = shades[y]
        dn = shades[min(y + 1, h - 1)]
        for x in range(w):
            s_c = int(cur[x])
            s_l = int(cur[max(x - 1, 0)])
            s_r = int(cur[min(x + 1, w - 1)])
            s_u = int(up[x])
            s_d = int(dn[x])

            # f0/f1: crosstalk field (state used BEFORE this pixel's update)
            A_use = colA[x]
            H_use = rowH
            rowH = (K_BETA_H * (rowH + DSQ[s_c])) >> 8
            colA[x] = ((K_BETA_V * (A_use + DSQ[s_c])) >> 8) & 0x3FFF

            edge = abs(DLIN[s_d] - DLIN[s_u])
            fld = (A_use * K_WN_V + ((H_use * K_WN_H) >> 2)
                   + edge * K_XT_EDGE + (int(upfld[y, x]) << 7))
            field = min(fld >> 8, 1023)
            # per-column gain (#49)
            field = field + (((field * int(xtcol[x])) + 128) >> 8)
            field = max(0, min(field, 1023))

            # palette + bleed
            pc = PAL[s_c]
            neigh = [PAL[s_l], PAL[s_r], PAL[s_u], PAL[s_d]]
            c = [mix8(pc[i], sum(n[i] for n in neigh) >> 2, K_BLEED)
                 for i in range(3)]

            # offTint
            lm = luma8(*c)
            offm = (K_OFFTINT * LUT_OFFW[lm] + 128) >> 8
            c = [mix8(c[i], PAL[3][i], offm) for i in range(3)]

            # crosstalk application
            if crosstalk:
                mg = 255 - abs(lm - 128) * 2 if lm != 128 else 255
                mg = 255 - (((lm - 128) << 1) if lm > 128 else ((128 - lm) << 1))
                gryf = (255 - K_XT_GRAY) + ((K_XT_GRAY * mg) >> 8)
                amt = (K_XTALK * field * gryf) >> 16
                dk = min(amt, K_XT_CLAMP)
                pol = lm - 128
                sgn = (K_XT_SIGN * dk * pol) >> 15
                c = [sat8(((c[i] * (256 - dk)) >> 8) + sgn) for i in range(3)]

            # gamma + saturation + warm
            g = [LUT_GAMMA[v] for v in c]
            gl = luma8(*g)
            warm = (((gl * K_WARM_R + 128) >> 8), ((gl * K_WARM_G + 128) >> 8),
                    -((gl * K_WARM_B + 128) >> 8))
            c = [sat8(gl + (((g[i] - gl) * K_SAT + 128) >> 8) + warm[i])
                 for i in range(3)]

            # tone + blackLift
            out[y, x] = [mix8(tone(c[i]), PBG[i], K_BLACKL) for i in range(3)]

    return out
