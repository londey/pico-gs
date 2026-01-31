# Data Model: RP2350 Host Software

**Feature Branch**: `002-rp2350-host-software`
**Date**: 2026-01-30

---

## Entity Overview

```
┌──────────────┐     generates     ┌──────────────────┐     consumed by     ┌───────────────┐
│   Demo       │─────────────────▶│  Render Command   │───────────────────▶│  Render Core  │
│  (Core 0)    │                   │  (Inter-core Q)   │                    │  (Core 1)     │
└──────┬───────┘                   └──────────────────┘                    └───────┬───────┘
       │                                                                          │
       │ manages                                                                  │ submits to
       ▼                                                                          ▼
┌──────────────┐                                                         ┌───────────────┐
│ Scene Graph  │                                                         │   SPI GPU     │
│  ├─ Meshes   │                                                         │  (External)   │
│  ├─ Transforms│                                                        └───────────────┘
│  ├─ Lights   │
│  └─ Textures │
└──────────────┘
```

---

## Core Entities

### Vertex

A single point in 3D space with associated rendering attributes.

| Field | Type | Description |
|-------|------|-------------|
| position | Vec3f | Object-space XYZ coordinates |
| normal | Vec3f | Unit normal vector for lighting |
| color | RGBA8 | Vertex color (R, G, B, A as u8) |
| uv | Vec2f | Texture coordinates (U, V) |

**Constraints**:
- Normal must be unit length (normalized before lighting)
- UV coordinates are in texture space (0.0-1.0 for standard mapping)
- Color alpha is 255 for opaque geometry

### Mesh

A complete 3D model stored in flash, composed of vertices and triangle indices.

| Field | Type | Description |
|-------|------|-------------|
| vertices | [Vertex] | Array of all vertices in the mesh |
| indices | [u16] | Triangle index list (groups of 3) |
| vertex_count | u16 | Total number of vertices |
| index_count | u16 | Total number of indices |

**Constraints**:
- Indices reference valid vertices (0..vertex_count-1)
- Index count is a multiple of 3 (complete triangles)
- Stored in flash; loaded to RAM via DMA before processing

### MeshPatch

A batch of vertices and indices extracted from a Mesh, sized to fit within the render command's capacity. This is the unit of work submitted to the render core.

| Field | Type | Description |
|-------|------|-------------|
| vertices | [Vertex; ≤128] | Subset of mesh vertices for this patch |
| indices | [u16] | Triangle indices referencing patch-local vertices |
| vertex_count | u8 | Number of vertices in this patch (1-128) |
| index_count | u16 | Number of indices in this patch |

**Constraints**:
- vertex_count ≤ 128
- Indices reference patch-local vertices (0..vertex_count-1)
- Patch boundaries are chosen to minimize vertex duplication across patches

### TransformMatrix

A 4x4 matrix combining model, view, and projection transforms.

| Field | Type | Description |
|-------|------|-------------|
| m | [[f32; 4]; 4] | 4x4 matrix in column-major order |

**Operations**:
- `transform_vertex(v: Vec3f) → ScreenVertex`: Apply MVP to object-space vertex, perform perspective divide and viewport transform
- `transform_normal(n: Vec3f) → Vec3f`: Apply inverse-transpose of model-view for lighting normals

**Derived output**: ScreenVertex

### ScreenVertex

A vertex after transformation, ready for GPU submission.

| Field | Type | Description |
|-------|------|-------------|
| x | i16_4 | Screen X in 12.4 fixed-point (GPU format) |
| y | i16_4 | Screen Y in 12.4 fixed-point (GPU format) |
| z | u25 | Depth value (25-bit unsigned, GPU format) |
| color | RGBA8 | Lit vertex color after lighting calculation |
| uq | i16_15 | U/W in 1.15 fixed-point (GPU format) |
| vq | i16_15 | V/W in 1.15 fixed-point (GPU format) |
| q | i16_15 | 1/W in 1.15 fixed-point (GPU format) |

**Constraints**:
- X range: -2048.0 to +2047.9375 (12.4 signed)
- Y range: -2048.0 to +2047.9375 (12.4 signed)
- Z range: 0 to 0x1FFFFFF (25-bit unsigned)
- UV/Q in 1.15 fixed-point: -1.0 to +0.99997

### LightSource

A directional light used for Gouraud shading calculations.

| Field | Type | Description |
|-------|------|-------------|
| direction | Vec3f | Unit direction vector (toward light) |
| color | RGB_f32 | Light color/intensity (0.0-1.0 per channel) |

**Constraints**:
- Direction must be normalized
- System supports exactly 4 directional lights plus 1 ambient level

### AmbientLight

| Field | Type | Description |
|-------|------|-------------|
| color | RGB_f32 | Ambient light color/intensity (0.0-1.0) |

### Texture

A rectangular image for GPU texture mapping.

| Field | Type | Description |
|-------|------|-------------|
| data | [u32] | RGBA8888 pixel data |
| width | u16 | Width in pixels (power of 2, 8-1024) |
| height | u16 | Height in pixels (power of 2, 8-1024) |
| gpu_address | u32 | Target address in GPU texture memory (4K aligned) |

**Constraints**:
- Width and height must be powers of 2
- Width and height between 8 and 1024
- Total size: width × height × 4 bytes
- Must fit within GPU texture memory (starts at 0x384000, ~768 KB)

---

## Render Commands

### RenderCommand (enum)

The unit of work flowing through the inter-core command queue.

| Variant | Payload | Description |
|---------|---------|-------------|
| RenderMeshPatch | MeshPatchCommand | Transform, light, and submit a mesh patch |
| UploadTexture | UploadTextureCommand | Upload texture data to GPU memory |
| WaitVsync | (none) | Wait for GPU vertical sync signal |
| ClearFramebuffer | ClearCommand | Clear screen to a solid color |

### MeshPatchCommand

| Field | Type | Description |
|-------|------|-------------|
| patch | MeshPatch | Vertex and index data |
| model_view | TransformMatrix | Combined model-view matrix |
| projection | TransformMatrix | Projection matrix |
| lights | [LightSource; 4] | Directional light sources |
| ambient | AmbientLight | Ambient light level |
| textured | bool | Whether texture coordinates should be submitted |
| z_test | bool | Whether depth testing is enabled |
| z_write | bool | Whether depth writes are enabled |

### UploadTextureCommand

| Field | Type | Description |
|-------|------|-------------|
| texture | &Texture | Reference to texture data (in flash/RAM) |
| gpu_address | u32 | Target GPU SRAM address (4K aligned) |

### ClearCommand

| Field | Type | Description |
|-------|------|-------------|
| color | RGBA8 | Fill color |
| clear_depth | bool | Also clear z-buffer to far plane |

---

## Scene Graph

### Demo (enum)

| Variant | Description |
|---------|-------------|
| GouraudTriangle | Single Gouraud-shaded triangle (no texture, no depth) |
| TexturedTriangle | Single textured triangle (texture, no depth) |
| SpinningTeapot | Animated Utah Teapot (mesh, transform, lighting, depth) |

### Scene

| Field | Type | Description |
|-------|------|-------------|
| active_demo | Demo | Currently selected demo |
| meshes | [&Mesh] | References to mesh data in flash |
| textures | [&Texture] | References to texture data in flash |
| model_transform | TransformMatrix | Current model rotation/position |
| view_transform | TransformMatrix | Camera transform |
| projection | TransformMatrix | Perspective projection matrix |
| lights | [LightSource; 4] | Directional light configuration |
| ambient | AmbientLight | Ambient light level |
| animation_time | f32 | Current animation time (seconds) |

**State Transitions**:
```
┌─────────────────────┐   key "1"   ┌─────────────────────┐
│  GouraudTriangle    │◄────────────│  TexturedTriangle   │
│  (default on boot)  │────────────▶│                     │
└─────────┬───────────┘   key "2"   └──────────┬──────────┘
          │                                     │
          │ key "3"                     key "3" │
          ▼                                     ▼
┌─────────────────────────────────────────────────────────┐
│                   SpinningTeapot                         │
│  key "1" → GouraudTriangle, key "2" → TexturedTriangle  │
└─────────────────────────────────────────────────────────┘
```

---

## Inter-Core Command Queue

| Property | Value |
|----------|-------|
| Direction | Core 0 (producer) → Core 1 (consumer) |
| Backpressure | Core 0 blocks when queue is full |
| Ordering | FIFO, strict order preserved |
| Thread safety | Lock-free (single producer, single consumer) |

---

## GPU Register Interaction Map

Mapping from host operations to GPU register writes:

| Host Operation | GPU Registers Used |
|---|---|
| Verify GPU present | Read ID (0x7F) → expect 0x6702 |
| Set draw framebuffer | Write FB_DRAW (0x40) |
| Set display framebuffer | Write FB_DISPLAY (0x41) |
| Configure z-buffer | Write FB_ZBUFFER (0x42) |
| Set rendering mode | Write TRI_MODE (0x30) |
| Set vertex color | Write COLOR (0x00) |
| Set texture UVs | Write UV0 (0x01) |
| Push vertex (triggers tri on 3rd) | Write VERTEX (0x05) |
| Configure texture unit 0 | Write TEX0_BASE (0x10), TEX0_FMT (0x11), TEX0_WRAP (0x14) |
| Upload memory (texture data) | Write MEM_ADDR (0x70), then MEM_DATA (0x71) × N |
| Swap buffers | Write FB_DRAW/FB_DISPLAY after VSYNC |
| Check flow control | Read GPIO CMD_FULL pin |
| Wait for vsync | Wait for GPIO VSYNC rising edge |
