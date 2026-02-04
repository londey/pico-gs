# Feature Specification: SPI GPU Register Map Rework

**Feature Branch**: `001-spi-register-rework`
**Created**: 2026-01-29
**Status**: Draft
**Input**: User description: "Rework SPI register map to support 4 textures with blend modes, compressed formats, z-buffer and alpha blending"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Multi-Texture Rendering (Priority: P1)

A developer needs to render 3D objects with up to 4 different textures applied simultaneously (e.g., diffuse map, normal map, specular map, and detail texture), each with independent UV coordinates.

**Why this priority**: Multi-texturing is fundamental to modern 3D rendering and enables rich visual effects. Without this, developers can only apply a single texture per draw call, severely limiting visual quality.

**Independent Test**: Can be fully tested by configuring 4 texture units with different source images and UV coordinates, rendering a test quad, and verifying all 4 textures appear correctly combined in the output.

**Acceptance Scenarios**:

1. **Given** the GPU is idle, **When** a developer configures 4 texture units with unique addresses and UV coordinates, **Then** all 4 textures are sampled and combined in a single draw call
2. **Given** multiple texture units are configured, **When** each texture has different dimensions (e.g., 256x256, 512x512, 128x64), **Then** each texture is sampled correctly according to its specified dimensions
3. **Given** texture units are configured with RGBA8 format, **When** rendering occurs, **Then** all color components are correctly read and applied

---

### User Story 2 - Texture Blend Modes (Priority: P2)

A developer wants to control how multiple textures combine together using different mathematical operations (multiply for lighting, add for glow effects, subtract for masking).

**Why this priority**: Blend modes enable complex visual effects like lighting, shadows, and special effects. This is essential for achieving professional-quality graphics but depends on multi-texturing being functional first.

**Independent Test**: Can be tested by rendering two textured quads with different blend modes (multiply, add, subtract, inverse subtract) and verifying the output matches expected mathematical operations on a per-component basis.

**Acceptance Scenarios**:

1. **Given** 2 texture units are configured with multiply blend mode, **When** rendering occurs, **Then** output color equals texture1.rgba * texture2.rgba component-wise
2. **Given** 2 texture units are configured with add blend mode, **When** rendering occurs, **Then** output color equals texture1.rgba + texture2.rgba component-wise
3. **Given** 2 texture units are configured with subtract blend mode, **When** rendering occurs, **Then** output color equals texture1.rgba - texture2.rgba component-wise
4. **Given** 2 texture units are configured with inverse subtract blend mode, **When** rendering occurs, **Then** output color equals texture2.rgba - texture1.rgba component-wise

---

### User Story 3 - Depth Testing and Z-Buffer (Priority: P3)

A developer rendering 3D scenes needs depth testing to ensure objects at different distances are drawn in the correct order, with closer objects obscuring farther ones.

**Why this priority**: Z-buffering is critical for 3D rendering but can be tested independently from texturing. It enables proper depth sorting without requiring CPU-side polygon sorting.

**Independent Test**: Can be tested by rendering two overlapping triangles at different Z depths with various compare functions and verifying that only pixels passing the depth test are written to the framebuffer.

**Acceptance Scenarios**:

1. **Given** z-buffer is configured with "less than" compare function, **When** a triangle at Z=0.5 is drawn after a triangle at Z=0.3, **Then** only pixels from the closer triangle (Z=0.3) remain visible
2. **Given** z-buffer is configured with "greater than" compare function, **When** triangles are drawn in any order, **Then** farther pixels pass the depth test
3. **Given** z-buffer is configured with "always" compare function, **When** any triangle is drawn, **Then** depth test always passes regardless of z-value
4. **Given** z-buffer is configured with "equal" compare function, **When** two triangles have identical Z values, **Then** both can be drawn to the same pixels
5. **Given** z-buffer base address is configured, **When** depth testing occurs, **Then** depth values are read from and written to the correct memory location

---

### User Story 4 - Alpha Blending (Priority: P4)

A developer wants to render transparent or semi-transparent objects (glass, water, particle effects) by blending new pixels with existing framebuffer content based on alpha values.

**Why this priority**: Alpha blending enables transparency effects and is commonly used in games and visualizations. It can be implemented and tested independently after basic rendering works.

**Independent Test**: Can be tested by rendering a semi-transparent quad over an opaque background with different blend modes and verifying the mathematical correctness of the blended output.

**Acceptance Scenarios**:

1. **Given** alpha blend mode is "disabled", **When** a pixel is rendered, **Then** the new pixel completely replaces the framebuffer value regardless of alpha
2. **Given** alpha blend mode is "add", **When** a pixel is rendered, **Then** output equals source.rgba + destination.rgba component-wise
3. **Given** alpha blend mode is "subtract", **When** a pixel is rendered, **Then** output equals source.rgba - destination.rgba component-wise
4. **Given** alpha blend mode is "a + (1-a)" (standard alpha blend), **When** a pixel with alpha=0.5 is rendered over an existing pixel, **Then** output equals (source * 0.5) + (destination * 0.5) component-wise

---

### User Story 5 - Compressed Texture Format (Priority: P5)

A developer with limited texture memory wants to use compressed textures to store more texture data, reducing memory bandwidth and storage requirements.

**Why this priority**: Compression is an optimization that can be added after basic texturing works. It delivers value for memory-constrained systems but isn't required for initial functionality.

**Independent Test**: Can be tested by loading a compressed texture with known tile values, rendering it, and comparing the output to an uncompressed reference to verify correct decompression and lookup.

**Acceptance Scenarios**:

1. **Given** a texture is configured with compressed format, **When** a pixel is sampled, **Then** the 8-bit index is read and used to lookup a 2x2 tile from the palette
2. **Given** a compressed texture with lookup table configured, **When** sampling occurs, **Then** the correct RGBA8 values are fetched from the lookup table based on the index
3. **Given** a compressed texture with 2x2 tiles, **When** UV coordinates are provided, **Then** the appropriate texel within the tile is selected based on fractional UV coordinates

---

### User Story 6 - Simplified Clear Operations (Priority: P6)

A developer wants to clear the framebuffer and z-buffer by drawing full-screen triangles instead of using dedicated clear registers, providing more flexibility in clearing operations.

**Why this priority**: This is a simplification that removes unused registers. The functionality is replaced by existing triangle rasterization, so it can be validated by confirming clear registers are removed and triangle-based clearing works.

**Independent Test**: Can be tested by drawing a full-screen triangle with solid color and verifying framebuffer is cleared, and drawing with maximum Z depth to verify z-buffer is cleared.

**Acceptance Scenarios**:

1. **Given** clear_color register is removed, **When** a developer wants to clear the framebuffer, **Then** they draw a full-screen triangle with the desired clear color
2. **Given** clear and clear_z registers are removed, **When** a developer wants to clear z-buffer, **Then** they draw a full-screen triangle with Z=max_depth and Z-compare set to "always"

---

### Edge Cases

- What happens when texture dimensions are not power-of-2 (e.g., 100x100)? System should handle arbitrary dimensions or clearly document restrictions.
- What happens when texture address points to invalid or unmapped memory? System should handle gracefully (return default color or error state).
- What happens when UV coordinates exceed texture bounds (e.g., U=2.5 for a 256px texture)? Need to specify wrap/clamp/repeat behavior.
- What happens when all 4 blend operations are chained together? Define the order of operations (texture0 op1 texture1 op2 texture2 op3 texture3).
- What happens when alpha blend mode is enabled but source or destination alpha is 0 or 1? Verify mathematical correctness at boundary values.
- What happens when z-buffer memory overlaps framebuffer memory? Should be prevented by configuration validation or clearly undefined behavior.
- What happens when compressed texture index exceeds lookup table size? System should clamp or wrap the index, or document as undefined behavior.
- What happens when texture swizzle pattern is invalid? System should use default pattern or document valid swizzle configurations.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Register map MUST support configuration of 4 independent texture units
- **FR-002**: Each texture unit MUST have its own UV coordinate registers
- **FR-003**: Each texture unit MUST support blend function configuration with operations: multiply, add, subtract, inverse subtract
- **FR-004**: Blend functions MUST be applied per-component (independently to R, G, B, A channels)
- **FR-005**: Each texture unit MUST have registers for: base address, width, height, storage format, swizzle pattern
- **FR-006**: Register map MUST support RGBA8 texture format (8 bits per channel, 32 bits per pixel); framebuffer uses RGB565 (16 bits per pixel) for bandwidth efficiency
- **FR-007**: Register map MUST support compressed texture format with 8-bit index per 2x2 texel tile
- **FR-008**: Compressed texture format MUST include lookup table configuration for mapping indices to RGBA8 values
- **FR-009**: Register map MUST NOT include clear_color, clear, or clear_z registers (functionality replaced by triangle rendering)
- **FR-010**: Register map MUST include FB_ZBUFFER register with z-buffer base address configuration
- **FR-011**: FB_ZBUFFER register MUST include z-compare function: less, less-or-equal, equal, greater, greater-or-equal, always
- **FR-012**: Register map MUST reserve space for future stencil operation configuration
- **FR-013**: Register map MUST include alpha blend mode register with modes: disabled, add, subtract, standard alpha blend (a + (1-a))
- **FR-014**: Swizzle patterns MUST allow reordering/selection of RGBA components from texture memory
- **FR-015**: Texture blend order MUST be deterministic when multiple textures are configured (define evaluation order)

### Key Entities

- **Texture Unit**: Represents one of 4 independent texture samplers, with attributes: unit index (0-3), UV coordinates (U, V), blend function (multiply/add/subtract/inverse subtract), base address, dimensions (width, height), storage format (RGBA8, compressed), swizzle pattern

- **Texture Configuration**: Defines how texture data is stored and accessed, with attributes: base memory address, width in pixels, height in pixels, format identifier, swizzle pattern, [for compressed: lookup table address, lookup table size]

- **Z-Buffer Configuration**: Defines depth testing behavior, with attributes: z-buffer base address, z-compare function (less/less-or-equal/equal/greater/greater-or-equal/always), [reserved: stencil enable, stencil operations, stencil reference value]

- **Alpha Blend Configuration**: Defines framebuffer blending behavior, with attributes: blend mode (disabled/add/subtract/alpha blend), [future: separate blend functions for RGB and Alpha]

- **Register Map**: Collection of memory-mapped hardware registers that configure GPU rendering state, including all texture units, z-buffer, and alpha blend settings

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Developers can configure and render with up to 4 independent textures in a single draw call
- **SC-002**: Texture blend modes produce mathematically correct results verified by automated pixel-perfect regression tests (100% accuracy for all blend mode combinations)
- **SC-003**: Z-buffer depth testing correctly sorts geometry (100% correctness for all 6 compare functions in test scenes with known depth values)
- **SC-004**: Alpha blending produces mathematically correct transparency effects (100% accuracy verified against reference calculations)
- **SC-005**: Compressed texture format reduces memory usage by at least 4:1 compared to RGBA8 for appropriate content (e.g., palettized textures)
- **SC-006**: Register map eliminates 3 clear-related registers while maintaining ability to clear buffers via triangle rendering
- **SC-007**: Register map documentation clearly specifies the address, bit layout, and function of every register
- **SC-008**: All edge cases have defined behavior (no undefined or unspecified scenarios remain after design finalization)

### Assumptions

- Texture memory and framebuffer memory are accessed via the same memory interface with consistent addressing
- UV coordinates are provided in a standard format (assumed normalized 0.0-1.0 range unless specified otherwise)
- Z-buffer format is compatible with the rendering pipeline's Z-value output format
- Register writes take effect before the next draw call (no explicit synchronization required)
- The SPI interface has sufficient bandwidth to configure all registers within acceptable setup time
- Compressed texture lookup table is stored in a memory region accessible by the texture units
- Swizzle patterns operate on read texture data before blend operations
- Default/reset values for all registers are well-defined (assumed 0 or disabled state)
- The framebuffer format (RGB565, 16 bits per pixel) is the target output format for all blending operations; stored in lower 16 bits of 32-bit words for addressing simplicity
