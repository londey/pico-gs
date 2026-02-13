# INT-021: Render Command Format

## Type

Internal

## Parties

- **Provider:** UNIT-026 (Inter-Core Queue)
- **Consumer:** UNIT-020 (Core 0 Scene Manager)
- **Consumer:** UNIT-021 (Core 1 Render Executor)
- **Consumer:** UNIT-027 (Demo State Machine)

## Referenced By

- REQ-101 (Unknown)
- REQ-102 (Unknown)
- REQ-103 (Unknown)
- REQ-104 (Unknown)
- REQ-111 (Dual-Core Architecture)
- REQ-114 (Render Command Queue)
- REQ-115 (Render Mesh Patch)
- REQ-112 (Scene Graph Management)

## Specification


**Version**: 1.0
**Date**: 2026-01-30
**Implements**: FR-005, FR-006, FR-006a, FR-007, FR-008, FR-009, FR-010, FR-011

---

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
| patch | &'static MeshPatchDescriptor | Reference to const patch data in flash (positions, normals, UVs, indices, AABB) |
| mvp_matrix | Mat4x4 | Combined model-view-projection matrix |
| mv_matrix | Mat4x4 | Model-view matrix (for normal/lighting transform) |
| lights | [DirectionalLight; 4] | Directional light sources |
| ambient | AmbientColor | Ambient light level |
| flags | RenderFlags | textured, z_test, z_write, gouraud |
| clip_flags | u8 | 6-bit frustum plane crossing bitmask from Core 0 culling (bit per plane: left, right, bottom, top, near, far) |

**Processing (Core 1)**:
1. DMA-prefetch patch data from flash into SRAM input buffer (double-buffered: process one buffer while next patch DMA's in)
2. For each vertex in patch:
   a. Transform position by MVP matrix → clip space
   b. Perspective divide → NDC
   c. Viewport transform → screen space (12.4 fixed-point)
   d. Compute Z as 16-bit unsigned
   e. Transform normal by model-view matrix
   f. Compute Gouraud lighting: `color = ambient + Σ(max(0, dot(N, L[i])) × light_color[i])`
   g. If textured: compute U/W, V/W, 1/W in 1.15 fixed-point
   h. Pack into GpuVertex format and store in clip-space vertex cache
3. Configure GPU RENDER_MODE register based on flags
4. For each index entry in the packed u8 strip command stream:
   a. Extract vertex index (bits [7:4]) and kick control (bits [3:2])
   b. Look up transformed vertex from cache
   c. If kick != NOKICK: perform back-face cull (cross product of screen-space edges)
   d. If clip_flags != 0 and triangle crosses a frustum plane: clip triangle (Sutherland-Hodgman)
   e. Write COLOR, UV0 (if textured), then VERTEX register (NOKICK/KICK_012/KICK_021 based on kick bits)
5. Output packed GPU register writes to double-buffered SPI output buffer (DMA/PIO sends one buffer while Core 1 fills the next)

**Output**: GPU register writes via DMA/PIO SPI (RP2350) or SPI thread (PC)

**Core 1 Working RAM per patch**: ~8 KB (see DD-016 for detailed breakdown)

---

### UploadTexture

Transfer texture pixel data to GPU SRAM.

**Input**:
| Field | Type | Description |
|-------|------|-------------|
| data_ptr | *const u32 | Pointer to RGBA8888 pixel data |
| data_len | u32 | Number of 32-bit words |
| gpu_address | u32 | Target GPU SRAM address (4K aligned) |

**Processing (Core 1)**:
1. Call `gpu_upload_memory(gpu_address, data)`
2. This writes MEM_ADDR then MEM_DATA × data_len

**Performance note**: Texture upload at 25 MHz SPI ≈ 3 MB/s. A 256×256 RGBA texture (256 KB) takes ~85 ms. Textures should be uploaded once during demo initialization, not per-frame.

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
1. Set TRI_MODE: flat shading, no texture, no Z-test/write
2. Set COLOR to fill color
3. Submit 2 triangles covering full 640×480 viewport:
   - Triangle 1: (0,0), (639,0), (639,479)
   - Triangle 2: (0,0), (639,479), (0,479)
4. If clear_depth:
   a. Set FB_ZBUFFER compare to ALWAYS, Z_WRITE=1
   b. Submit same 2 triangles with Z = 0x1FFFFFF (far plane)
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
| RenderMeshPatch size | ~264 bytes (2× Mat4 + lights + patch ref + flags) |
| Queue depth | 64 entries (sufficient for ~32 commands/frame) |
| Queue memory | 64 × ~264 bytes ≈ 16.5 KB |

**Note**: RenderMeshPatch commands are larger than the previous SubmitScreenTriangle (~80 bytes) but there are far fewer per frame (~29 vs ~144). Consider sharing per-frame state (MVP matrix, lights) via a separate mechanism to reduce per-command size.


## Constraints

See specification details above.

## Notes

Migrated from speckit contract: specs/002-rp2350-host-software/contracts/render-commands.md
