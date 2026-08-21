# BrickBoy DMG for MiSTer

This directory contains the MiSTer port of the BrickBoy DMG panel and sealed-speaker model. It combines the BrickBoy hardware stages from this repository with the current [Gameboy_MiSTer](https://github.com/MiSTer-devel/Gameboy_MiSTer) framework.

The port renders a 640x576 active image on an 896x627 raster. One raster frame is exactly one DMG frame, preserving the original 59.7275 Hz cadence. MiSTer's 67.108864 MHz video clock carries a half-rate 33.554432 MHz pixel enable.

## Install

Copy [`RELEASE/BrickBoy_DMG.rbf`](RELEASE/BrickBoy_DMG.rbf) to `/media/fat/_Console/` on the MiSTer SD card. Load `.gb` or `.gbc` ROMs through the core menu.

The release bitstream was compiled with Quartus Prime Lite 17.0, passed TimeQuest with positive setup and hold slack, and was tested on a DE10-Nano over HDMI.

## BrickBoy controls

The `BrickBoy Panel` OSD page exposes:

- panel brightness and warmth;
- reflector grain and saturation;
- nostalgia or measured panel colour;
- independent red, green, and blue ink tuning;
- off-element tint;
- dead electrode line severity;
- 4-way D-pad shaping;
- speaker simulation, rumble, and fast-forward sound.

It also includes two MiSTer-only experimental aging effects:

- `Vinegar Syndrome`: Off, Mild, Strong, or Ruined;
- `Dead-Line Flicker`: Off, Subtle, Unstable, or Severe.

The experimental controls default to Off. Dead-line flicker only has a visible effect when dead lines are enabled.

## Current behavior

The BrickBoy renderer always consumes the Game Boy's two-bit DMG LCD stream. GBC software therefore passes through the DMG panel model instead of MiSTer's normal colour renderer. SGB borders and MiSTer's normal video filters are not composited into this output. Status bits formerly used by Pocket-irrelevant GBC/SGB display behavior are used for the experimental aging controls.

## Build

Open `Gameboy.qpf` in Quartus Prime Lite 17.0 or run:

```powershell
quartus_sh --flow compile Gameboy
```

The resulting bitstream is `output_files/Gameboy.rbf`. Copy it to `RELEASE/BrickBoy_DMG.rbf` when preparing a release.

The `rtl/brickboy/` directory contains the BrickBoy-specific panel, audio, input, persistence, crosstalk, grain, grid, finishing, dead-line, and aging RTL. The remainder is the MiSTer Game Boy framework and MiSTer platform support required for a self-contained build.

## Provenance

- BrickBoy Pocket core and panel model: this repository
- MiSTer framework: [MiSTer-devel/Gameboy_MiSTer](https://github.com/MiSTer-devel/Gameboy_MiSTer)
- Original Game Boy FPGA core lineage: MiST/MiSTer Game Boy core contributors

The combined work retains the licenses and source headers of its components.
