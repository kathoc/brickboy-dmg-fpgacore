# BrickBoy Pocket

DMG-only Analogue Pocket core with brickboy's display and speaker pipeline.

- Emulation: MiSTer Gameboy lineage via budude2/openfpga-GBC (Till Harbaum 2015,
  MiSTer-devel, budude2's APF port). SGB and GBC are removed - this core is DMG
  only, by design.
- Display and audio output stages: ported from brickboy (`src/display/`,
  `src/ui/speaker-model.ts`). Not yet - see the plan.
- Plan: ../analogue/docs/plans/2026-08-03-dmg-brickboy-plan.md

## Status

Milestone 1: DMG-only strip, pass-through display. In progress.
