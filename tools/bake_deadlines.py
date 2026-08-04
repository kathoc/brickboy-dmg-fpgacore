#!/usr/bin/env python3
"""Bake brickboy's dead-line layout into tables.

Port of the dead-line block in src/display/shaders.ts (vEdgeWeight, vDeadDrop,
vDeadShade and the row equivalents) with dmg.json's seed and defects.ts's
defaults:

    deadLineEdgeBias  1.0     the surveyed edge concentration, fully on
    deadLineLit       0.06    fraction of dead lines that settle DARK
    deadLineRowRatio  0.15    horizontal failures as a fraction of vertical
    deadLineShimmer   1.0     flicker amount
    seed              7

Every one of those decisions is a pure function of the line index and the seed,
so none of it has to be evaluated on the FPGA. The severity dial is the only
runtime input, and it is quantised to eight steps, so the whole layout collapses
to one dead/alive bit per line per severity plus a few bytes of per-line state:

    DL_COL_DEAD[sev]   160-bit mask, which columns are dead at that severity
    DL_ROW_DEAD[sev]   144-bit mask
    DL_COL_STATE[col]  {lit, drop, gradient ends}
    DL_ROW_STATE[row]

The shader's `sev = pow(dial, 2.2)` non-linearity is folded into the table too -
the eight steps are the dial positions, not the internal severity.
"""

import argparse
import numpy as np

SEED = 7
EDGE_BIAS = 1.0
DEAD_LIT = 0.06
ROW_RATIO = 0.15
NATIVE_W, NATIVE_H = 160, 144
STEPS = 8

M32 = 0xFFFFFFFF


def dl_mix(v):
    """The shader's dlMix - a 32-bit integer avalanche."""
    v = int(v) & M32
    v = (v ^ (v >> 16)) & M32
    v = (v * 0x7FEB352D) & M32
    v = (v ^ (v >> 15)) & M32
    v = (v * 0x846CA68B) & M32
    return (v ^ (v >> 16)) & M32


def dl_rand(a, b):
    return dl_mix(((int(a) & M32) * 0x9E3779B9 & M32) ^ dl_mix(b)) / 4294967296.0


def dl_noise(t, salt):
    i = np.floor(t)
    f = t - i
    f = f * f * (3 - 2 * f)
    a = dl_rand(int(i), salt)
    b = dl_rand(int(i) + 1, salt)
    return a + (b - a) * f


def edge_weight(cx, span):
    if EDGE_BIAS <= 0:
        return 1.0
    x = cx / (span - 1.0)
    L, A, B, MEAN = 0.14, 0.230, 0.040, 0.10435
    w = A * (np.exp(-x / L) + np.exp(-(1.0 - x) / L)) + B
    return 1.0 + (w / MEAN - 1.0) * min(max(EDGE_BIAS, 0.0), 1.0)


def line_state(idx, span, sd, ratio=1.0):
    """Everything about one line that does not depend on the dial."""
    u = dl_rand(idx, sd ^ 23473)
    clump = min(max(0.35 + 1.3 * dl_noise(idx * 0.18, sd ^ 7991), 0.0), 2.0)
    # P(dead) = sev * 0.94 * edge * clump, so the dial value at which this line
    # dies is u / (0.94 * edge * clump * ratio).
    gain = 0.94 * edge_weight(idx, span) * clump * ratio
    thr = u / gain if gain > 0 else 9.9
    drop = min(max(0.86 + 0.14 * dl_rand(idx, sd ^ 41221), 0.0), 1.0)
    lit = dl_rand(idx, sd ^ 9001) < DEAD_LIT
    ga = 0.55 + 0.45 * dl_rand(int(idx * 1.7), sd + 4)
    gb = 0.55 + 0.45 * dl_rand(int(idx * 2.3), sd + 8)
    return thr, drop, lit, ga, gb


def bake(span, sd, ratio):
    thr = np.zeros(span)
    state = []
    for i in range(span):
        t, drop, lit, ga, gb = line_state(i, span, sd, ratio)
        thr[i] = t
        state.append((drop, lit, ga, gb))
    masks = []
    for s in range(STEPS):
        dial = s / (STEPS - 1.0)
        sev = dial ** 2.2                      # the shader's dial curve
        masks.append(thr < sev)
    return masks, state


def emit_mask(name, masks, span, path):
    words = []
    for m in masks:
        bits = 0
        for i in range(span):
            if m[i]:
                bits |= 1 << i
        words.append(bits)
    lines = [f"localparam bit [{span-1}:0] {name}[0:{STEPS-1}] = '{{"]
    for k, w in enumerate(words):
        lines.append(f"  {span}'h{w:0{(span+3)//4}x}" + ("," if k < STEPS - 1 else ""))
    lines.append("};")
    path.write_text("\n".join(lines) + "\n")


def emit_state(name, state, path):
    # 16 bits per line: {ga[3:0], gb[3:0], lit, drop[6:0]}
    vals = []
    for drop, lit, ga, gb in state:
        d = int(round(drop * 127))
        a = int(round((ga - 0.55) / 0.45 * 15))
        b = int(round((gb - 0.55) / 0.45 * 15))
        vals.append((a << 12) | (b << 8) | (int(lit) << 7) | d)
    lines = [f"localparam bit [15:0] {name}[0:{len(vals)-1}] = '{{"]
    for i in range(0, len(vals), 8):
        chunk = ", ".join(f"16'h{v:04x}" for v in vals[i:i + 8])
        lines.append("  " + chunk + ("," if i + 8 < len(vals) else ""))
    lines.append("};")
    path.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    import pathlib

    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="../src/core")
    args = ap.parse_args()
    out = pathlib.Path(args.out)
    sd = int(round(SEED * 1013))

    cmask, cstate = bake(NATIVE_W, sd, 1.0)
    rmask, rstate = bake(NATIVE_H, sd, ROW_RATIO)

    print("dial  dead columns  dead rows")
    for s in range(STEPS):
        print(f"  {s}      {cmask[s].sum():3d} / 160    {rmask[s].sum():3d} / 144")
    lit = sum(1 for _, l, _, _ in cstate if l)
    print(f"\nstuck-dark columns: {lit} of 160 ({lit/160*100:.1f}%, deadLineLit {DEAD_LIT})")
    # the surveyed shape: outer 20% should hold ~39% of dropped columns
    top = cmask[4]
    outer = top[:32].sum() + top[-32:].sum()
    if top.sum():
        print(f"outer 20% holds {outer/top.sum()*100:.0f}% of dead columns "
              f"at dial 4 (survey: 39%)")

    emit_mask("DL_COL_DEAD", cmask, NATIVE_W, out / "brick_dl_col.svh")
    emit_mask("DL_ROW_DEAD", rmask, NATIVE_H, out / "brick_dl_row.svh")
    emit_state("DL_COL_ST", cstate, out / "brick_dl_col_st.svh")
    emit_state("DL_ROW_ST", rstate, out / "brick_dl_row_st.svh")
    print("\nwrote brick_dl_{col,row}{,_st}.svh")
