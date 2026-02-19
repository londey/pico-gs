# UNIT-030: PNG Decoder

## Purpose

PNG file loading, RGBA conversion, and texture format encoding (RGBA4444/BC1)

## Implements Requirements

- REQ-012.01 (PNG Asset Processing) — area 13: Game Data Preparation/Import

## Interfaces

### Provides

None

### Consumes

- INT-003 (PNG Image Format)
- INT-014 (Texture Memory Layout)

### Internal Interfaces

- Called by UNIT-034 (Build.rs Orchestrator) via `load_and_convert()` function
- Produces `TextureAsset` struct consumed by UNIT-033 (Codegen Engine) for output generation
- Uses `identifier::generate_identifier()` for asset naming

## Design Description

### Inputs

- PNG image file path
- Target texture format (RGBA4444 or BC1)

### Outputs

- Binary texture data in target format (block-organized per INT-014)
- Texture metadata (width, height, format, byte count)

### Internal State

None (stateless processing)

### Algorithm / Behavior

The PNG decoder converts PNG image files to GPU texture formats:

1. **Load PNG:** Use `image` crate to load PNG file
2. **Convert to RGBA8:** `to_rgba8()` method handles all color spaces
3. **Validate dimensions:**
   - Must be power-of-2 (8, 16, 32, 64, 128, 256, 512, 1024)
   - All valid power-of-2 dimensions are automatically multiples of 4
4. **Format conversion:**
   - **RGBA4444:** Quantize each 8-bit channel to 4 bits
   - **BC1:** Compress using BC1 encoder
5. **Block organization:** Arrange pixels into 4x4 blocks (INT-014)
6. **Output binary:** Write to `.bin` file

### Implementation Notes

**RGBA8 -> RGBA4444 Quantization:**
```rust
fn quantize_rgba4444(rgba8: &[u8], width: usize, height: usize) -> Vec<u8> {
    let mut output = Vec::new();
    for block_y in 0..(height / 4) {
        for block_x in 0..(width / 4) {
            for texel_y in 0..4 {
                for texel_x in 0..4 {
                    let px = block_x * 4 + texel_x;
                    let py = block_y * 4 + texel_y;
                    let i = (py * width + px) * 4;
                    let r4 = (rgba8[i] >> 4) as u16;
                    let g4 = (rgba8[i + 1] >> 4) as u16;
                    let b4 = (rgba8[i + 2] >> 4) as u16;
                    let a4 = (rgba8[i + 3] >> 4) as u16;
                    let packed = (r4 << 12) | (g4 << 8) | (b4 << 4) | a4;
                    output.extend_from_slice(&packed.to_le_bytes());
                }
            }
        }
    }
    output
}
```

**BC1 Compression:**
Use external crate: `texpresso` (pure Rust BC1 encoder)
```rust
use texpresso::Format;

fn compress_bc1(rgba8: &[u8], width: usize, height: usize) -> Vec<u8> {
    let mut output = vec![0u8; (width * height) / 2]; // 0.5 bpp

    Format::Bc1.compress(
        rgba8,
        width,
        height,
        texpresso::Params::default(),
        &mut output,
    );

    output
}
```

### Dependencies

- `image` crate v0.25+ (existing)
- `texpresso` crate v0.3+ (new dependency for BC1 compression)

## Implementation

- `crates/asset-build-tool/src/png_converter.rs`: Main implementation
- `crates/asset-build-tool/src/format_rgba4444.rs`: RGBA4444 converter (new)
- `crates/asset-build-tool/src/format_bc1.rs`: BC1 encoder wrapper (new)

## Verification

- Unit test: RGBA4444 quantization of known pixel values
- Unit test: BC1 compression roundtrip (compress + decompress should approximate original)
- Integration test: PNG -> RGBA4444 -> binary file matches expected output
- Integration test: PNG -> BC1 -> binary file matches expected output

## Design Notes

Migrated from speckit module specification. Updated for RGBA4444/BC1 texture formats (v3.0).
