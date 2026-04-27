## Verification Method

Test — Verilator golden-image simulation that renders a representative real-world pixel-art texture through the full INDEXED8_2X2 pipeline and compares the framebuffer against an approved PNG.
The test exists to demonstrate visually that texture asset loading, large index-cache fills, and the 256-entry palette codebook all behave correctly on representative content, and to surface what INDEXED8_2X2 quantisation artefacts look like on a real image.

The test sources `integration/scripts/gen/nissan_skyline_r32_pixel_art/textures/Material.001_baseColor.png` (256×256 RGBA pixel-art) and compresses it on the fly: each 2×2 RGBA tile becomes a feature vector, k-means with `k=256` clusters them into 256 palette entries (NW/NE/SW/SE quadrants), and each tile is replaced by the 8-bit cluster id.
The compression seed is fixed (`0xC0FFEE`) so the golden output is reproducible across hosts.

## Verifies Requirements

- REQ-003.01 (Textured Triangle) — large-texture textured rendering through the integrated pipeline
- REQ-003.06 (Texture Sampling) — INDEXED8_2X2 sampling with full 8-bit index domain
- REQ-003.08 (Texture Cache) — multi-block index-cache fill behaviour (1024 blocks → cache eviction and refill across the frame)
- REQ-003.09 (Palette Slots) — 256-entry palette codebook, slot 0, single sampler

## Verified Design Units

- UNIT-003 (Register File — TEX0_CFG, PALETTE0, MEM_DATA upload path)
- UNIT-005 (Rasterizer — UV interpolation across the quad)
- UNIT-006 (Pixel Pipeline — fragment dispatch into the texture sampler)
- UNIT-011 (Texture Sampler — full INDEXED8_2X2 path)
- UNIT-011.01 (UV Coordinate Processing — REPEAT wrap, quadrant extraction)
- UNIT-011.03 (Index Cache — fill / hit / eviction across 1024 distinct 4×4 index blocks)
- UNIT-011.06 (Palette LUT — 256-entry slot 0 codebook, UNORM8 → UQ1.8 promotion)

## Preconditions

- The texture compression helper (`integration/scripts/gen/indexed8_compress.py`) requires Pillow, numpy, and scipy.
  The devcontainer image installs all three.
- The k-means seed in `compress_indexed8_2x2` is fixed.
  Changing the seed, the source PNG, the clustering iteration count, or the centroid initialisation strategy will change the golden image and require re-approval.

## Procedure

1. **Compress the source texture.**
   Run `compress_indexed8_2x2` on `Material.001_baseColor.png` to produce a 4096-byte palette blob, a 16384-byte index array (block-tiled per INT-014), and a reconstructed RGBA preview.
   **Pass:** the compressor returns a 4096-byte palette and a 16384-byte index payload.

2. **Stage palette and index data in SDRAM.**
   The hex script issues `MEM_FILL` + `MEM_DATA` writes to populate palette slot 0 (`BASE_ADDR=0x0880`, byte address `0x110000`) and the texture index array (`BASE_ADDR=0x0800`, byte address `0x100000`), then triggers `PALETTE0.LOAD_TRIGGER=1`.
   **Pass:** SDRAM contains the palette and index data; `palette_lut.slot_ready(0)` is true after the load completes.

3. **Configure TEX0 for INDEXED8_2X2 256×256.**
   `TEX0_CFG`: `ENABLE=1`, `FORMAT=INDEXED8_2X2`, `FILTER=NEAREST`, `WIDTH_LOG2=8`, `HEIGHT_LOG2=8`, `U_WRAP=V_WRAP=REPEAT`, `PALETTE_IDX=0`, `BASE_ADDR=0x0800`.
   **Pass:** the register write invalidates the index cache and latches the new configuration.

4. **Render a 512×480 textured quad.**
   Two triangles with white vertex colours and `MODULATE` combiner — covers the full FB area with `S,T ∈ [0,1]` mapped 1:1 to the texture.
   **Pass:** the pipeline emits one fragment per covered pixel; the index cache services miss fills across all 1024 4×4 index blocks of the texture.

5. **Read back the framebuffer and PNG-encode it.**
   Output goes to `integration/sim_out/ver_017_indexed_pixel_art.png` for the RTL harness, or `build/dt_out/ver_017_indexed_pixel_art.png` for the digital twin.
   **Pass:** the output PNG is 512×480 RGB565 → RGB8.

6. **Pixel-exact comparison.**
   `diff -q integration/sim_out/ver_017_indexed_pixel_art.png integration/golden/ver_017_indexed_pixel_art.png`.
   **Pass:** identical bytes.

## Test Implementation

- `integration/scripts/gen/ver_017.py`: Hex-stimulus generator.
  Calls the compressor, emits palette + index uploads, configures TEX0, kicks the quad.
- `integration/scripts/gen/indexed8_compress.py`: 2×2 RGBA → INDEXED8_2X2 compressor (k-means).
- `integration/scripts/ver_017_indexed_pixel_art.hex`: Generated stimulus consumed by the Verilator harness and the digital-twin CLI.
- `integration/golden/ver_017_indexed_pixel_art.png`: Approved golden image (re-approved any time the source PNG, compression algorithm, or seed changes).
- `rtl/tb/harness.cpp`: Scene name `indexed_pixel_art` runs this test.

## Notes

- The image is *not* expected to be a pixel-exact match to the source PNG.
  The 256-entry palette × 4-quadrant codebook covers ≤ 1024 distinct sub-pixel patterns, so flat regions reproduce well and high-frequency edges are quantised to the nearest cluster centroid.
  Reconstruction PSNR on this asset is ≈ 39 dB.
- Because the compression seed is fixed, two runs on the same source produce byte-identical hex / golden outputs.
  The seed lives in `indexed8_compress.compress_indexed8_2x2` and must not drift without an explicit re-approval pass.
- VER-017 stresses the index-cache miss-and-refill path more than any other golden test in the suite: the 256×256 apparent texture has 128×128 indices arranged in 32×32 = 1024 cache blocks, far exceeding the 32-set direct-mapped cache, so the frame inevitably evicts and refills every line many times.
