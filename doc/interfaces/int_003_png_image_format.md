# INT-003: Texture Input Formats

## Type

External Standard (Multi-format)

## External Specifications

- **PNG**: PNG 1.2 specification for image decoding
- **DDS**: DirectDraw Surface format (Microsoft DDS specification)
- **KTX2**: Khronos Texture Format 2.0 (Khronos KTX2 specification)

## Parties

- **Provider:** External (asset authoring tools, texture compressors)
- **Consumer:** UNIT-030 (Texture Loader)

## Referenced By

- REQ-200 (Unknown)

## Specification

**Version**: 2.0 (Multi-format support)
**Date**: February 2026

### Overview

The asset build tool supports multiple texture input formats for maximum workflow flexibility:
- **DDS (DirectDraw Surface)**: Primary format for production assets with pre-compressed BC1 data and mipmaps
- **KTX2 (Khronos Texture)**: Alternative modern format for BC1 textures with mipmaps
- **PNG**: Fallback format for rapid iteration; mipmaps generated at build time

### Format Selection

**Format detection**: Automatic based on file extension
- `.dds` → DDS loader
- `.ktx2` or `.ktx` → KTX2 loader
- `.png` → PNG loader with mipmap generation

**Format preference**:
1. **DDS/KTX2** for production assets:
   - Pre-compressed BC1 data (no build-time compression needed)
   - Pre-generated mipmaps with high-quality filtering (Lanczos, Mitchell, etc.)
   - Smaller source files than PNG
   - Faster build times

2. **PNG** for rapid iteration:
   - Universally supported by image editors
   - Auto-generates BC1 compression and mipmaps at build time
   - Slower builds but no specialized tools required

### PNG Format (Existing)

**Standard**: PNG 1.2 specification

**Usage**:
- Load as RGBA8
- Validate power-of-2 dimensions (8-1024 pixels)
- Compress to BC1 using texpresso crate
- Generate mipmap chain using bilinear downsampling
- Output per INT-031 (Asset Binary Format)

**Limitations**:
- Build-time BC1 compression (slower than pre-compressed DDS)
- Build-time mipmap generation (lower quality than offline tools)

### DDS Format (New)

**Standard**: DirectDraw Surface (Microsoft DDS format)

**Supported Variants**:
- **DXGI_FORMAT_BC1_UNORM**: BC1 compressed texture (required)
- Mipmaps: Optional but recommended
- Cubemaps: Not supported
- Volume textures: Not supported

**Validation**:
- Format must be BC1_UNORM (reject others)
- Dimensions must be power-of-2 (8-1024 pixels)
- If mipmaps present, verify chain integrity (correct sizes, no gaps)
- BC1 dimensions must be multiples of 4

**Extraction**:
- Read BC1 data directly (no decompression needed)
- Extract all mipmap levels
- Output per INT-031 (Asset Binary Format)

**Library**: `ddsfile` crate (v0.5+)

### KTX2 Format (New)

**Standard**: Khronos Texture Format 2.0

**Supported Variants**:
- **VK_FORMAT_BC1_RGB_UNORM_BLOCK**: BC1 compressed texture (required)
- Mipmaps: Optional but recommended
- Cubemaps: Not supported
- Texture arrays: Not supported

**Validation**:
- Format must be BC1_RGB_UNORM_BLOCK (reject others)
- Dimensions must be power-of-2 (8-1024 pixels)
- If mipmaps present, verify chain integrity
- BC1 dimensions must be multiples of 4

**Extraction**:
- Read BC1 data directly (no decompression needed)
- Extract all mipmap levels
- Output per INT-031 (Asset Binary Format)

**Library**: `ktx` crate (v0.3+)

### Error Handling

| Error | Condition | Action |
|-------|-----------|--------|
| UnsupportedFormat | DDS/KTX2 format is not BC1 | Reject with error message |
| InvalidDimensions | Dimensions not power-of-2 or out of range [8,1024] | Reject with error message |
| MipmapIntegrityError | Mipmap chain has incorrect sizes or gaps | Reject with error message |
| BC1DimensionError | BC1 texture dimensions not multiples of 4 | Reject with error message |

### Conversion Workflow

**DDS/KTX2 → Binary**:
1. Parse file format
2. Validate BC1 format and dimensions
3. Extract BC1 data and mipmaps (no conversion needed)
4. Generate Rust wrapper per INT-031
5. Write binary files

**PNG → Binary**:
1. Load PNG as RGBA8
2. Validate dimensions
3. Compress base level to BC1 using texpresso
4. Generate mipmap chain (bilinear downsample + BC1 compress)
5. Generate Rust wrapper per INT-031
6. Write binary files

## Constraints

- All input textures must be power-of-2 dimensions (8, 16, 32, 64, 128, 256, 512, 1024)
- DDS/KTX2 files must contain BC1-compressed data (other formats rejected)
- BC1 textures must have dimensions that are multiples of 4

## Notes

This specification replaces INT-003 v1.0 (PNG-only) to support industry-standard texture formats with pre-compressed data and mipmaps.

### External Tool Recommendations

**DDS Creation**:
- AMD Compressonator (free, best quality BC1 encoding)
- Substance Painter (direct DDS export with mipmaps)
- NVIDIA Texture Tools Exporter (Photoshop plugin)

**KTX2 Creation**:
- Khronos KTX-Software tools (toktx command-line tool)
- Unity Engine (KTX2 export)

**PNG Fallback**:
- Any standard image editor (GIMP, Photoshop, Krita, etc.)
