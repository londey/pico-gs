# INT-021: Render Command Format

## Type

Internal

## Serves Requirement Areas

- Area 7: Vertex Transformation (REQ-007.01, REQ-007.02)
- Area 8: Scene Graph/ECS (REQ-008.01, REQ-008.02, REQ-008.03, REQ-008.04)

## Parties

- **Provider:** UNIT-026 (Inter-Core Queue)
- **Consumer:** UNIT-020 (Core 0 Scene Manager)
- **Consumer:** UNIT-021 (Core 1 Render Executor)
- **Consumer:** UNIT-027 (Demo State Machine)

## Referenced By

- REQ-008.01 (Scene Management) — Area 8: Scene Graph/ECS
- REQ-008.02 (Render Pipeline Execution) — Area 8: Scene Graph/ECS
- REQ-009.01 (USB Keyboard Input) — Area 9: Keyboard and Controller Input
- REQ-007.01 (Matrix Transformation Pipeline) — Area 7: Vertex Transformation
- REQ-008.03 (Scene Graph Management) — Area 8: Scene Graph/ECS
- REQ-008.04 (Render Command Queue) — Area 8: Scene Graph/ECS
- REQ-007.02 (Render Mesh Patch) — Area 7: Vertex Transformation

Note: REQ-111 (Dual-Core Architecture) is retired; its reference has been removed.

## Specification

## Overview

The render command queue is the inter-core communication channel between Core 0 (scene management) and Core 1 (render execution). Core 0 produces render commands; Core 1 consumes and executes them against the GPU driver.

---

## Queue Properties

| Property | Value |
|----------|-------|
| Type | Single-producer, single-consumer (SPSC) |
| Producer | Core 0 (scene management) |
| Consumer | Core 1 (render execution) |
| Ordering | Strict FIFO |
| Backpressure | Producer blocks when queue is full |
| Thread safety | Lock-free (no mutexes, no spinlocks on shared data) |
| Drop policy | Never drop commands |

---

## Command Types

### RenderMeshPatch

Render a pre-built mesh patch: Core 1 DMA-prefetches patch data from flash, transforms vertices (MVP), computes Gouraud lighting, performs back-face culling, optionally clips triangles against frustum planes, and submits the resulting triangles to the GPU.

**Input**:
| Field | Type | Description |
|-------|------|-------------|
| patch | &'static MeshPatchDescriptor | Reference to const patch data in flash (single SoA blob of u16/i16 vertex data + u8 indices, AABB) |
| mvp_matrix | Mat4x4 | Combined model-view-projection matrix |
| mv_matrix | Mat4x4 | Model-view matrix (for normal/lighting transform) |
| lights | [DirectionalLight; 4] | Directional light sources |
| ambient | AmbientColor | Ambient light level |
| flags | RenderFlags | textured, z_test, z_write, gouraud, color_write |
| combiner_mode | u32 | Color combiner configuration (CC_MODE register value) |
| clip_flags | u8 | 6-bit frustum plane crossing bitmask from Core 0 culling (bit per plane: left, right, bottom, top, near, far) |

**Processing (Core 1)**:
1. DMA-prefetch patch data from flash into SRAM input buffer (double-buffered: process one buffer while next patch DMA's in)
2. For each vertex in patch:
   a. Unpack vertex data from SoA blob: read u16 position components at offsets [0, N×2, N×4], i16 normal components at offsets [N×6, N×8, N×10], i16 UV components at offsets [N×12, N×14] (where N = vertex_count)
   b. Convert position u16 → f32 (VCVT.F32.U16 on Cortex-M33). Note: quantization bias is already folded into the MVP matrix by Core 0
   c. Transform position by MVP matrix → clip space
   d. Perspective divide → NDC
   e. Viewport transform → screen space (12.4 fixed-point)
   f. Compute Z as 16-bit unsigned
   g. Convert normal i16 → f32 (divide by 32767.0, then normalize). Transform by model-view matrix
   h. Compute Gouraud lighting: `color = ambient + Σ(max(0, dot(N, L[i])) × light_color[i])`
   i. If textured: convert UV i16 → f32 (divide by 8192.0). Compute U/W, V/W, 1/W in 1.15 fixed-point
   j. Pack into GpuVertex format and store in clip-space vertex cache
3. Configure GPU RENDER_MODE register based on flags (includes GOURAUD, Z_TEST_EN, Z_WRITE_EN, COLOR_WRITE_EN, Z_COMPARE, ALPHA_BLEND, CULL_MODE)
3a. Configure GPU CC_MODE register from combiner_mode
4. For each index entry in the packed u8 strip command stream:
   a. Extract vertex index (bits [7:4]) and kick control (bits [3:2])
   b. Look up transformed vertex from cache
   c. If kick != NOKICK: perform back-face cull (cross product of screen-space edges)
   d. If clip_flags != 0 and triangle crosses a frustum plane: clip triangle (Sutherland-Hodgman)
   e. Write COLOR, UV0_UV1 (if textured, holds UV for up to 2 texture units), then VERTEX register (NOKICK/KICK_012/KICK_021 based on kick bits)
5. Output packed GPU register writes to double-buffered SPI output buffer (DMA/PIO sends one buffer while Core 1 fills the next)

**Output**: GPU register writes via DMA/PIO SPI (RP2350) or SPI thread (PC)

**Core 1 Working RAM per patch**: ~7.5 KB (see DD-016 for detailed breakdown; input buffers reduced from ~1,136 B to ~608 B due to u16/i16 vertex data)

---

### UploadTexture

Transfer texture pixel data to GPU SRAM.

**Input**:
| Field | Type | Description |
|-------|------|-------------|
| data_ptr | *const u64 | Pointer to RGBA8888 pixel data (packed 2 pixels per 64-bit dword) |
| data_len | u32 | Number of 64-bit dwords |
| gpu_dword_addr | u32 | Target GPU SDRAM dword address (22-bit, byte address >> 3) |

**Processing (Core 1)**:
1. Call `gpu_upload_memory(gpu_dword_addr, data)`
2. This writes MEM_ADDR then MEM_DATA × data_len

**Performance note**: Texture upload at 25 MHz SPI ≈ 6 MB/s (64-bit dwords per 72-bit transaction). A 256×256 RGBA texture (256 KB) takes ~43 ms. Textures should be uploaded once during demo initialization, not per-frame.

---

### WaitVsync

Synchronize with the display refresh cycle.

**Input**: None

**Processing (Core 1)**:
1. Call `gpu_wait_vsync()`
2. After VSYNC: swap draw/display framebuffers
3. Return

**Timing**: Blocks until next VSYNC pulse (~16.67 ms worst case)

---

### ClearFramebuffer

Fill the screen with a solid color using a full-viewport triangle.

**Input**:
| Field | Type | Description |
|-------|------|-------------|
| color | RGBA8 | Fill color |
| clear_depth | bool | Also clear z-buffer |

**Processing (Core 1)**:
1. Set RENDER_MODE: flat shading, no texture, no Z-test/write
2. Set COLOR to fill color
3. Submit 2 triangles covering full 640×480 viewport:
   - Triangle 1: (0,0), (639,0), (639,479)
   - Triangle 2: (0,0), (639,479), (0,479)
4. If clear_depth:
   a. Set FB_ZBUFFER compare to ALWAYS, Z_WRITE=1
   b. Submit same 2 triangles with Z = 0xFFFF (far plane)
   c. Restore FB_ZBUFFER compare to LEQUAL

**GPU writes**: 8 register writes for color clear, 16 for color+depth clear

---

## Frame Sequence

A typical frame follows this command sequence:

```
1. ClearFramebuffer { color: bg_color, clear_depth: true }
2. RenderMeshPatch { patch: &mesh.patches[0], mvp, mv, lights, ambient, flags, clip_flags }
3. RenderMeshPatch { patch: &mesh.patches[1], mvp, mv, lights, ambient, flags, clip_flags }
   ... (one per visible mesh patch after Core 0 frustum culling)
N. WaitVsync
N+1. (implicit: swap framebuffers)
```

Core 0 performs frustum culling per frame: tests each model's overall AABB, then each patch's AABB against the view frustum. Only patches that pass culling are enqueued as `RenderMeshPatch` commands. Core 0 also computes a 6-bit clip_flags bitmask indicating which frustum planes each patch crosses, enabling Core 1 to skip triangle clipping for fully-inside patches.

---

## Queue Capacity Sizing

| Factor | Value |
|--------|-------|
| Utah Teapot patches | ~29 patches (estimated, ~460 vertices / 16 per patch) |
| Visible patches per frame | ~20-29 (after frustum culling) |
| Commands per frame | ~22-32 (1 clear + 20-29 patches + 1 vsync) |
| RenderMeshPatch size | ~268 bytes (2× Mat4 + lights + patch ref + flags + combiner_mode) |
| Queue depth | 64 entries (sufficient for ~32 commands/frame) |
| Queue memory | 64 × ~264 bytes ≈ 16.5 KB |

**Note**: RenderMeshPatch commands are larger than the previous SubmitScreenTriangle (~80 bytes) but there are far fewer per frame (~29 vs ~144). Consider sharing per-frame state (MVP matrix, lights) via a separate mechanism to reduce per-command size.


## Constraints

See specification details above.

## Notes

Migrated from speckit contract: specs/002-rp2350-host-software/contracts/render-commands.md

The Verilator integration simulation harness (used by VER-010 through VER-014 golden image tests) injects render stimulus by driving UNIT-003 register-file inputs directly, replicating the register-write sequences that `RenderMeshPatch` and `ClearFramebuffer` commands produce.
The harness must faithfully encode all register writes per this interface specification to produce correct simulation results.

**Register fields with behavioral effect after pixel pipeline integration**: The `combiner_mode` field (written to CC_MODE register 0x18), UV0/UV1 coordinates (written to UV0_UV1 register), COLOR1 (specular vertex color, packed into the COLOR register's upper 32 bits), and all RENDER_MODE flags (GOURAUD, ALPHA_BLEND, CULL_MODE, DITHER_EN, STIPPLE_EN, ALPHA_TEST, ALPHA_REF) were previously stored in the register file but had no downstream consumer in the active data path.
After pixel pipeline integration (UNIT-006), these fields are live inputs to the per-fragment processing stages.
Test harnesses that previously relied on these fields having no rendering effect must be reviewed; golden images for VER-010 through VER-014 require re-approval after integration (see impact analysis).
