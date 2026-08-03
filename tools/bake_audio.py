#!/usr/bin/env python3
"""Bake brickboy's speaker model into fixed-point biquad coefficients.

Direct port of src/ui/speaker-model.ts (RBJ Audio EQ Cookbook forms) plus the
one-pole DC blocker from src/emu/apu/apu.ts, at the rate the FPGA runs them.

brickboy synthesises an impulse response from these biquads and convolves it in
a ConvolverNode. On hardware there is no reason to go through an IR: the biquads
themselves are three second-order sections, so they are evaluated directly. The
response is identical - the IR was only ever a way to get a fixed filter into
the Web Audio graph.

dmg.json audio:
    hpfHz   28.0                      Pan Docs cf 0.999958
    speaker f0 420, q 1.1             sealed-box resonance
            fHigh 7000, q 0.707       cone breakup + grille
            resonances [[1200, 2.5, 4]]   box colouration
            gain 1.0
"""

import numpy as np

FS = 65536.0            # clk_sys / 512
HPF_HZ = 28.0
COEF_BITS = 22          # Q2.22 signed; |a1| approaches 2


def highpass2(fs, f0, q):
    w = 2 * np.pi * f0 / fs
    cw, alpha = np.cos(w), np.sin(w) / (2 * q)
    a0 = 1 + alpha
    return ((1 + cw) / 2 / a0, -(1 + cw) / a0, (1 + cw) / 2 / a0,
            (-2 * cw) / a0, (1 - alpha) / a0)


def lowpass2(fs, f0, q):
    w = 2 * np.pi * f0 / fs
    cw, alpha = np.cos(w), np.sin(w) / (2 * q)
    a0 = 1 + alpha
    return ((1 - cw) / 2 / a0, (1 - cw) / a0, (1 - cw) / 2 / a0,
            (-2 * cw) / a0, (1 - alpha) / a0)


def peaking(fs, f0, q, gain_db):
    A = 10 ** (gain_db / 40)
    w = 2 * np.pi * f0 / fs
    cw, alpha = np.cos(w), np.sin(w) / (2 * q)
    a0 = 1 + alpha / A
    return ((1 + alpha * A) / a0, (-2 * cw) / a0, (1 - alpha * A) / a0,
            (-2 * cw) / a0, (1 - alpha / A) / a0)


STAGES = [
    ("highpass 420 Q1.1", highpass2(FS, 420, 1.1)),
    ("lowpass 7000 Q0.707", lowpass2(FS, 7000, 0.707)),
    ("peaking 1200 Q2.5 +4dB", peaking(FS, 1200, 2.5, 4)),
]


def q(v):
    return int(round(v * (1 << COEF_BITS)))


def response(stages, freqs, fs=FS, quantised=False):
    """|H(f)| in dB for a cascade, optionally with the coefficients rounded to
    the fixed-point grid, so the two can be compared directly."""
    out = np.zeros(len(freqs))
    z = np.exp(-2j * np.pi * np.asarray(freqs) / fs)
    for _, c in stages:
        b0, b1, b2, a1, a2 = c
        if quantised:
            b0, b1, b2, a1, a2 = (q(v) / (1 << COEF_BITS) for v in (b0, b1, b2, a1, a2))
        h = (b0 + b1 * z + b2 * z * z) / (1 + a1 * z + a2 * z * z)
        out += 20 * np.log10(np.abs(h) + 1e-30)
    return out


def dc_blocker_alpha():
    return 1 - np.exp(-2 * np.pi * HPF_HZ / FS)


if __name__ == "__main__":
    import pathlib

    print(f"fs = {FS:.0f} Hz, coefficients Q2.{COEF_BITS}\n")
    lines = []
    for i, (name, c) in enumerate(STAGES):
        b0, b1, b2, a1, a2 = c
        print(f"  {name}")
        print(f"    b {b0:+.9f} {b1:+.9f} {b2:+.9f}")
        print(f"    a {a1:+.9f} {a2:+.9f}")
        for nm, v in zip("b0 b1 b2 a1 a2".split(), c):
            lines.append(f"  {24}'sd{q(v)} /* {nm} {name} = {v:+.9f} */")

    alpha = dc_blocker_alpha()
    print(f"\n  DC blocker {HPF_HZ} Hz: alpha = {alpha:.9f} "
          f"= {round(alpha * (1 << 24))}/2^24")

    freqs = np.array([20, 50, 100, 200, 300, 420, 600, 1000, 1200, 2000,
                      3000, 5000, 7000, 10000, 15000, 20000])
    ref = response(STAGES, freqs)
    qz = response(STAGES, freqs, quantised=True)
    print(f"\n  {'Hz':>6}  {'float dB':>9}  {'Q2.22 dB':>9}  {'err':>7}")
    for f, r, s in zip(freqs, ref, qz):
        print(f"  {f:6.0f}  {r:+9.3f}  {s:+9.3f}  {s - r:+7.4f}")
    print(f"\n  worst quantisation error {np.abs(qz - ref).max():.4f} dB")

    body = "\n".join(f"  24'sd{q(v)}," if i < 14 else f"  24'sd{q(v)}"
                     for i, v in enumerate(
                         [v for _, c in STAGES for v in c]))
    pathlib.Path("../src/core/brick_audio_coef.svh").write_text(body + "\n")
    print("\nwrote ../src/core/brick_audio_coef.svh")
