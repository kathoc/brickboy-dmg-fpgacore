# brickboy-dmg (Analogue Pocket openFPGA core)

A port of the DMG display and audio model from **brickboy** to an Analogue
Pocket openFPGA core. This is not an independent implementation: the maths, the
pass order and the constants come from brickboy's `src/display/` and
`src/ui/speaker-model.ts`.

DMG only. SGB and GBC were removed from the upstream core, and the freed
resources went into the panel model.

## What it does

The Pocket renders the game at 4x — one Game Boy dot becomes a 4x4 block — and
the whole panel model runs at that resolution in hardware, in the same order
brickboy's shader chain runs it.

| Stage | Ported from |
| --- | --- |
| Colour correction | `shaders.ts` `FRAG_COLOR_CORRECT` (dmg-lut path) |
| Passive-matrix crosstalk | `shaders.ts` `FRAG_COLUMN_REDUCE` |
| LCD persistence | `shaders.ts` `FRAG_GHOST` |
| Dot structure and drop shadow | `shaders.ts` `FRAG_GRID` |
| Reflector grain | `reflector.ts` |
| Screen-space finish | `shaders.ts` `FRAG_PASSTHROUGH` |
| Dead electrode lines | `shaders.ts` `FRAG_DEFECTS` |
| Speaker and case | `speaker-model.ts` plus the APU's output DC blocker |

Order is load-bearing. Persistence sits after the grid, the faults after
persistence, and crosstalk inside the colour pass — moving any of them changes
what the panel looks like.

Details worth knowing:

- **Crosstalk is bidirectional.** A dark block bleeds down strongly and up
  weakly (0.4x), which is what makes it read as crosstalk surrounding dark
  content rather than a second copy of the drop shadow. A top-to-bottom scan
  cannot see the rows below, so the upward field is computed by a pre-pass that
  walks the frame bottom-to-top during blanking.
- **Persistence is asymmetric.** Darkening is driven and fast; lightening is
  relaxation and slow. Getting that backwards reads as input lag.
- **The drop shadow has two layers**, a sharp umbra at 1.35 dots and a broad
  penumbra at 3.24, which is what makes the air gap between the element plane
  and the reflector readable.
- **The reflector grain has three bands** — half a dot, one to three dots, and
  eighteen to thirty-six. Only the middle one reads as grain at the Pocket's
  pixel pitch; the finest is below what the panel resolves and the coarsest is
  mottling.

## Deviations from brickboy

Every one of these is a hardware constraint or a difference in the display, not
a redesign. They are marked in the source at the point they matter.

| What | Why |
| --- | --- |
| Persistence state is kept at native resolution, before the grid | brickboy keeps it post-grid; at 4x that needs 8.85 Mbit against a 3.15 Mbit device |
| The grain's coarse band is baked on a 4-dot lattice and the finest band is a runtime hash | The full texture is 3.2 Mbit |
| Dead lines are substituted into the cell *before* the grid | The shader is a screen-space pass and re-applies a dot mask; a dead electrode is a fact about the element, so doing it there gets the dot structure and the neighbours' shadows for free |
| The 4-way D-pad uses last-input priority | brickboy's 4-way also resists turning (`R_COMMIT_4WAY`), which exists because a thumb drifts on glass. A physical cross-pad has no drift |
| The speaker runs the biquads directly | brickboy synthesises an impulse response and convolves it, which is how you get a fixed filter into a Web Audio graph. The response is identical |
| The module margin is not drawn | The Pocket's bezel plays that part, matching brickboy's own Fill mode |
| Panel trim dials | The Pocket's LTPS LCD and the phone OLED brickboy is authored against have different primaries, and Analogue publishes no colorimetry. Guessing a correction into the pipeline would corrupt the reference, so it rides on top as a dial |

The panel trim, ink tone, grain contrast and off-element tint dials are **not**
part of the port. At their Normal positions the pipeline is brickboy's,
unchanged.

Not yet implemented: dead-line flicker (`deadFlicker`). Vinegar syndrome is out
of scope.

## Verification

The port was checked against brickboy itself, not against a reimplementation.

- `tools/bb_render.mjs` drives brickboy's own `?renderfarm=1` harness — the same
  six-pass WebGL chain the app puts on screen — and renders arbitrary frames at
  the Pocket's 4x. Those pixels are the reference.
- `tools/color_model.py`, `grid_rtl.py` and `frame_model.py` are bit-exact
  models of the RTL, so a change can be measured before a 20-minute synthesis
  run.
- `tools/bake_grain.py`, `bake_audio.py` and `bake_deadlines.py` evaluate
  brickboy's own functions to produce the baked tables, so the constants are
  derived rather than transcribed.

Measured against brickboy at 4x, on flat fields:

```
shade   grid modulation        cell luminance
        brickboy  this core    brickboy       this core
  0       3.20%     1.98%      [178 166 115]  [176 164 112]
  1       5.46%     4.46%      [143 151  99]  [142 151  97]
  2      15.85%    15.42%      [112 123  79]  [106 119  74]
  3      31.39%    33.09%      [ 98 110  71]  [ 91 105  67]
```

The audio chain matches its float model to within 0.01 dB across the audible
band.

## Building

Quartus Prime Lite (tested on 25.1std) for a Cyclone V 5CEBA4F23C8:

```
cd src && quartus_sh --flow compile ap_core
python3 build/rbf_reverse.py src/output_files/ap_core.rbf build/brickboy.rbf_r
```

Regenerate the baked tables after changing a profile constant:

```
cd tools && python3 bake_grain.py && python3 bake_audio.py && python3 bake_deadlines.py
```

## Installing

Copy `Cores`, `Platforms` and `Assets` to the root of the SD card. Place the
Game Boy BIOS in `/Assets/gb/common` as `gb_bios.bin`, and ROMs in the same
folder.

## Licence

GPL-3.0-or-later. The upstream core carries GPL-3.0-or-later files (the
OpenGateware audio filters) alongside MIT ones, so the combined work is
GPL-3.0-or-later.

Provenance:

- Analogue Pocket core framework: [Analogue openFPGA](https://www.analogue.co/developer)
- Game Boy core: [budude2/openfpga-GBC](https://github.com/budude2/openfpga-GBC),
  itself ported from [Gameboy_MiSTer](https://github.com/MiSTer-devel/Gameboy_MiSTer)
- Panel and speaker model: brickboy (not public)

Neither `budude2/openfpga-GBC` nor `Gameboy_MiSTer` declares a repository-level
licence; the file headers do, and this repository follows them.
