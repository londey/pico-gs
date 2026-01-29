# Feature Specification: ICEpi SPI GPU

**Branch**: 001-spi-gpu
**Date**: January 2026
**Status**: Active Development
**Current Version**: 2.0

---

## Version History

**Version 2.0** (January 2026) - Multi-Texture Rework:
- Added 4 independent texture units with separate UV coordinates
- Added texture blend modes (multiply, add, subtract, inverse subtract)
- Added compressed texture format with 8-bit indexed lookup
- Added swizzle patterns for channel reordering (16 patterns)
- Added UV wrapping modes (repeat, clamp, clamp-to-zero, mirror)
- Added configurable z-buffer compare functions (8 modes)
- Added alpha blending modes (4 modes)
- Added memory upload interface (MEM_ADDR/MEM_DATA)
- Removed CLEAR_COLOR, CLEAR, CLEAR_Z registers (use triangle rendering)
- Reorganized register address space for logical grouping
- **Breaking Changes**: Register addresses moved, see [contracts/register-map.md](contracts/register-map.md) v2.0 Migration Guide
- **Design Rationale**: See [specs/001-spi-register-rework/](../../specs/001-spi-register-rework/)

**Version 1.0** (January 2026) - Initial Release:
- Basic triangle rasterization with edge walking
- Single texture unit with perspective-correct UV mapping
- Gouraud shading and flat shading modes
- Z-buffer depth testing
- SPI register interface
- DVI display output

---

## Overview

### Problem Statement

Building 3D graphics applications on microcontrollers is constrained by limited CPU cycles for both geometry processing and pixel rendering. While the RP2350's dual M33 cores with hardware float can handle vertex transforms, the fill-rate demands of rasterization quickly become a bottleneck for anything beyond trivial scenes.

### Solution

A dedicated GPU implemented on the ICEpi Zero's ECP5 FPGA that offloads triangle rasterization, texture mapping, and framebuffer management from the host MCU. The host submits screen-space triangles over SPI; the GPU handles pixel-level operations and display output.

### Inspiration

The architecture draws from the PlayStation 2 Graphics Synthesizer (GS):
- Host performs transforms and submits primitives (like EE/VU → GS)
- GPU handles rasterization with perspective-correct texturing
- Register-based command interface with implicit state accumulation
- High memory bandwidth dedicated to fill rate

### Success Criteria

**v1.0 Goals:**
1. Render a lit, rotating Utah teapot at ≥30 FPS
2. Render a textured, rotating cube at ≥30 FPS
3. Stable 640×480 @ 60Hz DVI output with no tearing
4. Host CPU utilization ≤50% during rendering (leaving cycles for game logic)

**v2.0 Goals:**
5. Render objects with up to 4 textures simultaneously (e.g., diffuse + normal + specular + detail)
6. Demonstrate texture blend modes (multiply for lighting, add for glow effects)
7. Render with compressed textures achieving 4:1 memory reduction
8. Render transparent objects with alpha blending at ≥25 FPS
9. Maintain ≥30 FPS with 2 active texture units per triangle

---

## User Stories

### US-1: Basic Host Communication

**As a** firmware developer  
**I want to** write to GPU registers over SPI  
**So that** I can configure the GPU and submit primitives

**Acceptance Criteria:**
- [ ] SPI slave accepts 72-bit transactions (1 R/W + 7 addr + 64 data)
- [ ] Register writes complete within predictable cycle count
- [ ] CMD_FULL GPIO asserts when command buffer is near capacity
- [ ] CMD_EMPTY GPIO asserts when safe to read status registers
- [ ] VSYNC GPIO pulses at frame boundaries

---

### US-2: Framebuffer Management

**As a** firmware developer  
**I want to** configure draw target and display source addresses  
**So that** I can implement double-buffering without tearing

**Acceptance Criteria:**
- [ ] FB_DRAW register sets where triangles render
- [ ] FB_DISPLAY register sets which buffer is scanned out
- [ ] Buffer swap (changing FB_DISPLAY) takes effect at next VSYNC
- [ ] CLEAR command fills FB_DRAW with CLEAR_COLOR at full bandwidth
- [ ] 4K-aligned addresses allow multiple buffers in 32MB SRAM

---

### US-3: Flat-Shaded Triangle

**As a** firmware developer  
**I want to** submit a triangle with a single color  
**So that** I can render simple geometry without texture overhead

**Acceptance Criteria:**
- [ ] Set TRI_MODE to flat shading (GOURAUD=0, TEXTURED=0)
- [ ] Set COLOR register once (used for all three vertices)
- [ ] Write three VERTEX registers; third write triggers rasterization
- [ ] Triangle renders correctly for all orientations (CW/CCW)
- [ ] Subpixel precision prevents "dancing" vertices during animation

---

### US-4: Gouraud-Shaded Triangle

**As a** firmware developer  
**I want to** submit a triangle with per-vertex colors  
**So that** I can render smooth lighting gradients

**Acceptance Criteria:**
- [ ] Set TRI_MODE with GOURAUD=1
- [ ] Set COLOR register before each VERTEX write
- [ ] Colors interpolate linearly across triangle in screen space
- [ ] No banding artifacts visible in 8-bit per channel output

---

### US-5: Depth-Tested Triangle

**As a** firmware developer  
**I want to** enable Z-buffer testing  
**So that** overlapping triangles render in correct depth order

**Acceptance Criteria:**
- [ ] Set TRI_MODE with Z_TEST=1, Z_WRITE=1
- [ ] Z-buffer stored in SRAM (separate from color buffer)
- [ ] Depth comparison is less-than-or-equal (closer pixels win)
- [ ] Z values interpolate correctly across triangle
- [ ] Z-buffer can be cleared independently of color buffer

---

### US-6: Textured Triangle

**As a** firmware developer  
**I want to** submit a triangle with texture coordinates  
**So that** I can render textured surfaces

**Acceptance Criteria:**
- [ ] Set TRI_MODE with TEXTURED=1
- [ ] Set TEX_BASE to texture address in SRAM
- [ ] Set TEX_FMT with texture dimensions (power-of-two, log2 encoded)
- [ ] Set UV register (U/W, V/W, 1/W) before each VERTEX write
- [ ] Texture sampling is perspective-correct (no affine warping)
- [ ] Texture coordinates wrap or clamp (configurable)
- [ ] Final pixel = texture color × vertex color

---

### US-7: Display Output

**As a** user
**I want** the GPU to output video to a standard monitor
**So that** I can see the rendered graphics

**Acceptance Criteria:**
- [ ] 640×480 @ 60Hz resolution via DVI/HDMI
- [ ] TMDS encoding using ECP5 SERDES blocks
- [ ] Stable sync signals (no rolling, tearing, or flicker)
- [ ] Display refresh never stalls regardless of draw load

---

## Version 2.0 User Stories

### US-8: Multi-Texture Rendering (v2.0)

**As a** firmware developer
**I want to** render triangles with up to 4 textures simultaneously
**So that** I can create rich visual effects like diffuse + lightmap + specular + detail

**Acceptance Criteria:**
- [ ] Configure up to 4 independent texture units (TEX0-TEX3)
- [ ] Each texture unit has its own UV coordinate registers (UV0-UV3)
- [ ] Set UV0-UV3 registers before each VERTEX write
- [ ] All enabled textures sample and blend in a single draw call
- [ ] Textures can have different dimensions (e.g., 256×256 diffuse, 64×64 lightmap)
- [ ] Each texture unit has independent base address and format configuration
- [ ] See [contracts/register-map.md](contracts/register-map.md) for register details

**Design Reference**: [specs/001-spi-register-rework/](../../specs/001-spi-register-rework/)

---

### US-9: Texture Blend Modes (v2.0)

**As a** firmware developer
**I want to** control how multiple textures combine together
**So that** I can achieve effects like modulated lighting, additive glow, and subtractive masking

**Acceptance Criteria:**
- [ ] Set TEXn_BLEND register for each texture unit (except TEX0)
- [ ] Support MULTIPLY blend mode (texture × previous result)
- [ ] Support ADD blend mode (texture + previous result, saturate)
- [ ] Support SUBTRACT blend mode (previous - texture, saturate)
- [ ] Support INVERSE_SUBTRACT blend mode (texture - previous, saturate)
- [ ] Blend operations apply per-component (R, G, B, A independently)
- [ ] Textures evaluate sequentially (TEX0 → TEX1 → TEX2 → TEX3)
- [ ] Verify mathematical correctness with test patterns

---

### US-10: Compressed Texture Format (v2.0)

**As a** firmware developer
**I want to** use compressed textures with indexed palettes
**So that** I can reduce memory usage and bandwidth for texture-heavy scenes

**Acceptance Criteria:**
- [ ] Set TEXn_FMT.COMPRESSED=1 to enable compressed mode
- [ ] Configure TEXn_LUT_BASE with lookup table address
- [ ] Texture data uses 8-bit indices (one per 2×2 texel tile)
- [ ] LUT contains 256 entries, each with 4 RGBA8 texels (16 bytes per entry)
- [ ] Sampling correctly fetches and decodes 2×2 tiles
- [ ] Achieve 4:1 memory reduction vs RGBA8 for appropriate content
- [ ] Upload LUT via MEM_ADDR/MEM_DATA registers

---

### US-11: Swizzle Patterns (v2.0)

**As a** firmware developer
**I want to** reorder texture color channels
**So that** I can use grayscale textures efficiently and handle different texture formats

**Acceptance Criteria:**
- [ ] Set TEXn_FMT.SWIZZLE to select channel ordering
- [ ] Support RGBA (identity, default)
- [ ] Support BGRA (swap red/blue)
- [ ] Support RRR1 (grayscale - replicate R to RGB, alpha=1)
- [ ] Support at least 13 predefined swizzle patterns
- [ ] Undefined patterns default to RGBA
- [ ] Swizzle applies before texture blending

---

### US-12: UV Wrapping Modes (v2.0)

**As a** firmware developer
**I want to** control texture coordinate wrapping behavior
**So that** I can prevent edge artifacts and achieve repeating or clamped textures

**Acceptance Criteria:**
- [ ] Set TEXn_WRAP register for U and V independently
- [ ] Support REPEAT mode (wrap around, UV mod texture_size)
- [ ] Support CLAMP_TO_EDGE mode (clamp to [0, size-1])
- [ ] Support CLAMP_TO_ZERO mode (out of bounds = transparent)
- [ ] Support MIRROR mode (reflect at boundaries)
- [ ] U and V can have different wrap modes
- [ ] Wrapping applies correctly for all texture dimensions

---

### US-13: Alpha Blending (v2.0)

**As a** firmware developer
**I want to** blend rendered pixels with framebuffer content based on alpha
**So that** I can render transparent and semi-transparent objects

**Acceptance Criteria:**
- [ ] Set ALPHA_BLEND register to select blend mode
- [ ] Support DISABLED mode (overwrite destination)
- [ ] Support ADD mode (source + destination, saturate)
- [ ] Support SUBTRACT mode (source - destination, saturate)
- [ ] Support ALPHA_BLEND mode (standard Porter-Duff source-over)
- [ ] Alpha blend applies per-component (R, G, B, A)
- [ ] Disable Z_WRITE when rendering transparent objects (Z_TEST still enabled)
- [ ] Verify correct transparency with alpha=0, 0.5, and 1.0

---

### US-14: Enhanced Z-Buffer (v2.0)

**As a** firmware developer
**I want to** configure z-buffer compare functions
**So that** I can control depth testing behavior (reverse Z, equal test, always pass, etc.)

**Acceptance Criteria:**
- [ ] Set FB_ZBUFFER register with base address and compare function
- [ ] Support LESS compare (incoming < zbuffer)
- [ ] Support LEQUAL compare (incoming ≤ zbuffer)
- [ ] Support EQUAL compare (incoming = zbuffer)
- [ ] Support GEQUAL compare (incoming ≥ zbuffer)
- [ ] Support GREATER compare (incoming > zbuffer)
- [ ] Support NOTEQUAL compare (incoming ≠ zbuffer)
- [ ] Support ALWAYS compare (always pass)
- [ ] Support NEVER compare (always fail)
- [ ] Space reserved in register for future stencil operations

---

### US-15: Memory Upload Interface (v2.0)

**As a** firmware developer
**I want to** efficiently upload textures and lookup tables via SPI
**So that** I can dynamically load content without pre-programming SRAM

**Acceptance Criteria:**
- [ ] Set MEM_ADDR register to target SRAM address
- [ ] Write to MEM_DATA register to upload 32-bit word
- [ ] MEM_ADDR auto-increments by 4 after each MEM_DATA write
- [ ] Read from MEM_DATA to verify uploaded content
- [ ] Upload 1KB texture in <300 transactions (9ms @ 25MHz SPI)
- [ ] Support bulk uploads of textures, LUTs, and other GPU memory

---

### US-16: Triangle-Based Clearing (v2.0)

**As a** firmware developer
**I want to** clear framebuffer and z-buffer by rendering full-screen triangles
**So that** I have more flexible clearing with pattern fills and partial clears

**Acceptance Criteria:**
- [ ] CLEAR_COLOR, CLEAR, CLEAR_Z registers removed from register map
- [ ] Clear color buffer by rendering two triangles covering viewport
- [ ] Clear z-buffer by rendering triangles with Z_COMPARE=ALWAYS and Z=far_plane
- [ ] Achieve similar clear performance as dedicated hardware clear (<5ms)
- [ ] Support partial clears by drawing smaller triangles
- [ ] Support pattern/gradient fills by varying vertex colors

---

## Functional Requirements

### FR-1: SPI Interface

| Requirement | Description |
|-------------|-------------|
| FR-1.1 | SPI Mode 0 (CPOL=0, CPHA=0), active-low CS |
| FR-1.2 | Maximum SPI clock: 40 MHz |
| FR-1.3 | Transaction format: 72 bits (MSB first) |
| FR-1.4 | Bit 71: R/W̄ (1=read, 0=write) |
| FR-1.5 | Bits 70:64: Register address (7 bits, 128 registers) |
| FR-1.6 | Bits 63:0: Register value (64 bits) |
| FR-1.7 | Write transactions queue to command FIFO |
| FR-1.8 | Read transactions return register value on MISO |

### FR-2: Command Buffer

| Requirement | Description |
|-------------|-------------|
| FR-2.1 | FIFO depth: 8-16 commands minimum |
| FR-2.2 | CMD_FULL asserts when ≤2 slots remain |
| FR-2.3 | CMD_EMPTY asserts when FIFO is empty |
| FR-2.4 | Commands execute in FIFO order |
| FR-2.5 | Host may poll STATUS register for FIFO depth |

### FR-3: Vertex Submission

| Requirement | Description |
|-------------|-------------|
| FR-3.1 | GPU maintains internal vertex counter (0, 1, 2) |
| FR-3.2 | Writing COLOR latches color for next vertex |
| FR-3.3 | Writing UV latches texture coordinates for next vertex |
| FR-3.4 | Writing VERTEX latches position and increments counter |
| FR-3.5 | When counter reaches 3, triangle is queued for rasterization |
| FR-3.6 | Counter resets to 0 after triangle submission |
| FR-3.7 | TRI_MODE affects all subsequent triangles until changed |

### FR-4: Rasterization

| Requirement | Description |
|-------------|-------------|
| FR-4.1 | Edge-walking algorithm (not tile-based) |
| FR-4.2 | Top-left fill convention for consistent edges |
| FR-4.3 | Subpixel precision: 4 fractional bits minimum |
| FR-4.4 | Pixels outside 0 ≤ x < 640, 0 ≤ y < 480 are clipped |
| FR-4.5 | Degenerate triangles (zero area) produce no pixels |

### FR-5: Texture Sampling (v1.0 baseline, see FR-8-12 for v2.0 enhancements)

| Requirement | Description |
|-------------|-------------|
| FR-5.1 | Texture dimensions: power-of-two, 8×8 to 1024×1024 (v2.0: expanded range) |
| FR-5.2 | Texture format: RGBA8888 (32 bits per texel) + compressed 8-bit indexed (v2.0) |
| FR-5.3 | Addressing: U/W and V/W interpolated, divided by 1/W per pixel |
| FR-5.4 | Wrap mode: repeat (v1.0) → configurable REPEAT/CLAMP/CLAMP_TO_ZERO/MIRROR (v2.0) |
| FR-5.5 | Filter mode: nearest neighbor (no bilinear) |
| FR-5.6 | Texture base address: 4K aligned |
| FR-5.7 | Swizzle: N/A (v1.0) → 16 configurable patterns (v2.0) |

### FR-6: Framebuffer

| Requirement | Description |
|-------------|-------------|
| FR-6.1 | Resolution: 640×480 |
| FR-6.2 | Color format: RGBA8888 (32 bits per pixel) |
| FR-6.3 | Size: 1,228,800 bytes per buffer |
| FR-6.4 | Z-buffer: 24 bits per pixel, same resolution (32-bit word with padding) |
| FR-6.5 | Z-buffer size: 1,228,800 bytes (921,600 used) |
| FR-6.6 | Clear operation: dedicated registers (v1.0) → triangle rendering (v2.0) |
| FR-6.7 | Z-buffer base address: fixed (v1.0) → configurable via FB_ZBUFFER (v2.0) |

### FR-7: Display Output

| Requirement | Description |
|-------------|-------------|
| FR-7.1 | Resolution: 640×480 @ 60Hz (pixel clock 25.175 MHz) |
| FR-7.2 | Interface: DVI (HDMI-compatible, no audio) |
| FR-7.3 | Encoding: TMDS via ECP5 SERDES |
| FR-7.4 | Timing: CEA-861 standard for 640×480p60 |
| FR-7.5 | Read-ahead FIFO: ≥1 scanline to mask SRAM latency |

### FR-8: Multi-Texture Support (v2.0)

| Requirement | Description |
|-------------|-------------|
| FR-8.1 | Support 4 independent texture units (TEX0-TEX3) |
| FR-8.2 | Each texture unit has separate UV coordinate registers |
| FR-8.3 | Each texture unit has independent configuration (base, format, wrap, blend, LUT) |
| FR-8.4 | Texture units can be independently enabled/disabled |
| FR-8.5 | All enabled textures sample in single rasterization pass |
| FR-8.6 | Texture blend order is deterministic (0→1→2→3) |

### FR-9: Texture Blend Modes (v2.0)

| Requirement | Description |
|-------------|-------------|
| FR-9.1 | Support MULTIPLY blend (result = prev × current) |
| FR-9.2 | Support ADD blend (result = prev + current, saturate) |
| FR-9.3 | Support SUBTRACT blend (result = prev - current, saturate) |
| FR-9.4 | Support INVERSE_SUBTRACT blend (result = current - prev, saturate) |
| FR-9.5 | Blend operations apply per-component (R, G, B, A independently) |
| FR-9.6 | TEX0_BLEND register ignored (no previous texture) |

### FR-10: Compressed Textures (v2.0)

| Requirement | Description |
|-------------|-------------|
| FR-10.1 | Support 8-bit indexed format with 2×2 tile lookup |
| FR-10.2 | LUT contains 256 entries, each 16 bytes (4 RGBA8 texels) |
| FR-10.3 | Each texture unit has independent LUT address |
| FR-10.4 | Compressed format achieves 4:1 memory reduction |
| FR-10.5 | Sampling correctly decodes tile index and selects texel |

### FR-11: Swizzle Patterns (v2.0)

| Requirement | Description |
|-------------|-------------|
| FR-11.1 | Support 16 predefined swizzle patterns (4-bit encoding) |
| FR-11.2 | Swizzle patterns reorder RGBA channels from memory |
| FR-11.3 | Support identity (RGBA), swap (BGRA), grayscale (RRR1), etc. |
| FR-11.4 | Undefined patterns default to RGBA |
| FR-11.5 | Swizzle applies before texture blending |

### FR-12: UV Wrapping (v2.0)

| Requirement | Description |
|-------------|-------------|
| FR-12.1 | Support REPEAT mode (UV mod texture_size) |
| FR-12.2 | Support CLAMP_TO_EDGE mode (clamp to [0, size-1]) |
| FR-12.3 | Support CLAMP_TO_ZERO mode (out of bounds = transparent) |
| FR-12.4 | Support MIRROR mode (reflect at boundaries) |
| FR-12.5 | U and V wrapping modes configurable independently |

### FR-13: Alpha Blending (v2.0)

| Requirement | Description |
|-------------|-------------|
| FR-13.1 | Support DISABLED mode (overwrite destination) |
| FR-13.2 | Support ADD mode (src + dst, saturate) |
| FR-13.3 | Support SUBTRACT mode (src - dst, saturate) |
| FR-13.4 | Support ALPHA_BLEND mode (Porter-Duff source-over) |
| FR-13.5 | Alpha blend applies per-component |
| FR-13.6 | Alpha blend occurs after texture blending and vertex color modulation |

### FR-14: Enhanced Z-Buffer (v2.0)

| Requirement | Description |
|-------------|-------------|
| FR-14.1 | Support 8 z-compare functions (LESS, LEQUAL, EQUAL, GEQUAL, GREATER, NOTEQUAL, ALWAYS, NEVER) |
| FR-14.2 | Z-buffer base address configurable (4K aligned) |
| FR-14.3 | Z-compare function and base address in single register |
| FR-14.4 | Space reserved for future stencil operations |

### FR-15: Memory Upload (v2.0)

| Requirement | Description |
|-------------|-------------|
| FR-15.1 | MEM_ADDR register sets target SRAM address |
| FR-15.2 | MEM_DATA register writes 32-bit word to SRAM |
| FR-15.3 | MEM_ADDR auto-increments by 4 after each write |
| FR-15.4 | MEM_DATA supports both read and write operations |
| FR-15.5 | Allows bulk upload of textures and LUTs via SPI |

### FR-16: Register Map Reorganization (v2.0)

| Requirement | Description |
|-------------|-------------|
| FR-16.1 | Registers organized by function (vertex, texture, rendering, framebuffer, status) |
| FR-16.2 | CLEAR_COLOR, CLEAR, CLEAR_Z registers removed |
| FR-16.3 | Version number incremented to 2.0 (device ID 0x6702) |
| FR-16.4 | Migration guide documents all address changes |
| FR-16.5 | Reserved register space for future expansion |

---

## Non-Functional Requirements

### NFR-1: Performance

| Requirement | Target (v1.0) | Target (v2.0) |
|-------------|---------------|---------------|
| NFR-1.1 | Triangle throughput | ≥20,000 triangles/sec | ≥18,000 triangles/sec (4 textures) |
| NFR-1.2 | Fill rate | ≥25 Mpixels/sec | ≥20 Mpixels/sec (multi-texture) |
| NFR-1.3 | Clear rate | Full screen in <5ms | Triangle-based clear in <5ms |
| NFR-1.4 | Register write latency | <100 cycles from CS↑ | <100 cycles from CS↑ |
| NFR-1.5 | Texture upload via SPI | N/A | 1KB in <10ms (via MEM_DATA) |
| NFR-1.6 | Single texture performance | ≥35,000 triangles/sec | ≥35,000 triangles/sec (maintained) |

### NFR-2: Resource Utilization

| Requirement | Target |
|-------------|--------|
| NFR-2.1 | LUT usage | ≤20,000 |
| NFR-2.2 | BRAM usage | ≤100 kbytes |
| NFR-2.3 | DSP usage | ≤24 blocks |
| NFR-2.4 | SRAM bandwidth | ≤200 MB/s total |

### NFR-3: Reliability

| Requirement | Description |
|-------------|-------------|
| NFR-3.1 | No display corruption under sustained draw load |
| NFR-3.2 | FIFO overflow handled gracefully (stall, not corrupt) |
| NFR-3.3 | Deterministic behavior for same input sequence |

---

## Out of Scope

The following features are explicitly **not** included in this specification:

**Permanently Out of Scope:**
- Programmable shaders or compute capabilities
- Audio output
- Hardware cursors or sprites (use triangles)

**Deferred to Future Versions:**
- Stencil buffer operations (space reserved in v2.0)
- Anti-aliasing (MSAA, FXAA, etc.)
- Line or point primitives (triangles only)
- Scissor rectangle / clipping planes
- Bilinear or trilinear texture filtering (nearest neighbor only)
- Mipmapping / LOD selection
- Vertex fog or atmospheric effects

**Now In Scope (v2.0):**
- ~~Multiple texture units or multitexturing~~ → 4 texture units (US-8)
- ~~Alpha blending or transparency~~ → Alpha blending modes (US-13)
- ~~Texture compression~~ → 8-bit indexed compression (US-10)

---

## Open Questions

> Items requiring clarification before implementation

**Resolved in v2.0:**
- [x] **Q1**: Texture coordinate wrapping → Resolved: Configurable per-texture (REPEAT/CLAMP/CLAMP_TO_ZERO/MIRROR)
- [x] **Q3**: CLEAR command behavior → Resolved: Removed dedicated clear registers, use triangle rendering
- [x] **Q4**: Texture pixel formats → Resolved: RGBA8 + compressed 8-bit indexed format

**Still Open:**
- [ ] **Q2**: Is 24-bit Z precision sufficient, or should we support 16-bit for bandwidth savings?
- [ ] **Q5**: Should we support a "kick" register for explicit draw trigger, vs implicit on third vertex?

**New Questions (v2.0):**
- [ ] **Q6**: Should compressed texture LUT be shared across all units or per-unit? (Currently: per-unit)
- [ ] **Q7**: Maximum LUT size - fixed at 256 entries or configurable?
- [ ] **Q8**: Should we support texture filtering hints for future hardware interpolation?
- [ ] **Q9**: Performance target for 4-texture rendering - aim for same fill rate as single texture?

---

## Review Checklist

**v1.0 Baseline:**
- [x] All user stories have measurable acceptance criteria
- [x] Functional requirements are complete and unambiguous
- [x] Non-functional requirements have quantified targets
- [x] Out-of-scope items are explicitly listed
- [x] Open questions are captured for clarification
- [x] Constitution principles are not violated

**v2.0 Additions:**
- [x] New user stories (US-8 through US-16) added with acceptance criteria
- [x] Functional requirements expanded (FR-8 through FR-16)
- [x] Performance targets updated for multi-texture scenarios
- [x] Out-of-scope section updated (multi-texture, alpha blend now in scope)
- [x] Version history documented with breaking changes noted
- [x] Register map contract updated (contracts/register-map.md v2.0)
- [ ] Design rationale documented (specs/001-spi-register-rework/)
- [ ] Implementation tasks generated (tasks.md to be updated)

---

## Implementation Notes

### v2.0 Breaking Changes

**Critical**: v2.0 introduces breaking changes to the register map. All host software must be updated:

1. **Register Address Changes**: Many registers moved to new addresses (see [Migration Guide](contracts/register-map.md#migration-guide-v10--v20))
2. **Removed Registers**: CLEAR_COLOR (0x0A), CLEAR (0x0B), CLEAR_Z (0x0C) removed
3. **New Clearing Method**: Use triangle rendering to clear framebuffer and z-buffer
4. **Device ID**: Changed from 0x6701 (v1.0) to 0x6702 (v2.0)
5. **Version Detection**: Host software should read ID register to detect GPU version

### Constitution Compliance (v2.0)

**Article IV - Interface Stability Covenant**:
- Breaking changes acknowledged and documented
- Major version increment (1.0 → 2.0) indicates breaking changes
- Migration guide provided
- Device ID changed to allow version detection

**Article VII - Simplicity Gate**:
- Multi-texturing deferred from v1.0 scope, now implemented in v2.0
- Features justified: multi-texture enables real-world game scenes
- Resource impact assessed (see performance targets)
- Maintains core goal: enhanced teapot and cube rendering

### Related Documentation

- **Register Map v2.0**: [contracts/register-map.md](contracts/register-map.md) - Complete register definitions with migration guide
- **Design Rationale**: [specs/001-spi-register-rework/](../../specs/001-spi-register-rework/) - Why multi-texture rework was needed
- **Memory Map**: [contracts/memory-map.md](contracts/memory-map.md) - SRAM allocation (verify compatibility)
- **SPI Protocol**: [contracts/spi-protocol.md](contracts/spi-protocol.md) - Transaction format (unchanged)

---

## Next Steps

1. **Review v2.0 Specification**: Validate requirements with stakeholders
2. **Update Implementation Tasks**: Run `/speckit.tasks` to regenerate tasks.md with v2.0 features
3. **Update Test Plan**: Extend test coverage for multi-texture, blend modes, compressed textures
4. **Implement Hardware**: Begin RTL updates for multi-texture pipeline
5. **Update Host Software**: Adapt firmware for new register map and features
