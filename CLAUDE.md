# pico-gs Development Guidelines

Auto-generated from all feature plans. Last updated: 2026-01-31

## Active Technologies
- Rust (stable), target `thumbv8m.main-none-eabihf` (Cortex-M33 with hardware FPU) + `rp235x-hal` ~0.2.x, `cortex-m-rt` 0.7.x, `heapless` 0.8.x, `glam` 0.29.x (no_std), `fixed` 1.28.x, `defmt` 0.3.x, TinyUSB (C FFI for USB host) (002-rp2350-host-software)
- Flash (4 MB) for mesh data, texture data, and firmware binary; RP2350 SRAM (520 KB) for runtime state (002-rp2350-host-software)
- Rust stable (1.75+) (003-asset-data-prep)
- File I/O (input: .png/.obj files, output: .rs source files + .bin data files) (003-asset-data-prep)

- (002-rp2350-host-software)

## Project Structure

```text
backend/
frontend/
tests/
```

## Commands

# Add commands for 

## Code Style

: Follow standard conventions

## Recent Changes
- 003-asset-data-prep: Added Rust stable (1.75+)
- 002-rp2350-host-software: Added Rust (stable), target `thumbv8m.main-none-eabihf` (Cortex-M33 with hardware FPU) + `rp235x-hal` ~0.2.x, `cortex-m-rt` 0.7.x, `heapless` 0.8.x, `glam` 0.29.x (no_std), `fixed` 1.28.x, `defmt` 0.3.x, TinyUSB (C FFI for USB host)

- 002-rp2350-host-software: Added

<!-- MANUAL ADDITIONS START -->
<!-- MANUAL ADDITIONS END -->
