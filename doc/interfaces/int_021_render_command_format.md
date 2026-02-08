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

Transform a mesh patch from object space to screen space, compute lighting, and submit triangles to the GPU.

**Input**:
| Field | Type | Description |
|-------|------|-------------|
| vertices | [Vertex; ≤128] | Object-space vertices |
| indices | [u16] | Triangle index list |
| vertex_count | u8 | Number of vertices (1-128) |
| index_count | u16 | Number of indices |
| mvp_matrix | Mat4x4 | Combined model-view-projection matrix |
| mv_matrix | Mat4x4 | Model-view matrix (for normal transform) |
| lights | [DirectionalLight; 4] | Light sources |
| ambient | AmbientColor | Ambient light level |
| flags | RenderFlags | textured, z_test, z_write, gouraud |

**Processing (Core 1)**:
1. For each vertex in patch:
   a. Transform position by MVP matrix → clip space
   b. Perspective divide → NDC
   c. Viewport transform → screen space (12.4 fixed-point)
   d. Compute Z as 25-bit unsigned
   e. Transform normal by inverse-transpose of model-view
   f. Compute Gouraud lighting: `color = ambient + Σ(max(0, dot(N, L[i])) × light_color[i])`
   g. If textured: compute U/W, V/W, 1/W in 1.15 fixed-point
   h. Pack into GpuVertex format
2. Configure GPU TRI_MODE register based on flags
3. For each triangle (indices[i], indices[i+1], indices[i+2]):
   a. Optional: back-face cull (cross product of screen-space edges)
   b. Submit 3 packed vertices to GPU via triangle strip or individual triangles

**Output**: GPU register writes via gpu_driver

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

A typical frame rendered by Core 1 follows this command sequence:

```
1. ClearFramebuffer { color: bg_color, clear_depth: true }
2. RenderMeshPatch { patch_0, transforms, lights, flags }
3. RenderMeshPatch { patch_1, transforms, lights, flags }
   ... (one per mesh patch in scene)
N. WaitVsync
N+1. (implicit: swap framebuffers)
```

Core 0 generates this sequence each frame and enqueues all commands before the render core finishes the previous frame (double-buffered pipeline).

---

## Queue Capacity Sizing

| Factor | Value |
|--------|-------|
| Utah Teapot patches | ~32 patches (estimated, ~500 vertices / 16 per patch) |
| Commands per frame | ~34 (1 clear + 32 patches + 1 vsync) |
| Command size | Variable (MeshPatch is largest, ~2-4 KB with 128 vertices) |
| Queue depth | Must hold at least 1 full frame of commands |

**Recommendation**: Queue depth of 64 commands or ring buffer with sufficient memory for command payloads.


## Constraints

See specification details above.

## Notes

Migrated from speckit contract: specs/002-rp2350-host-software/contracts/render-commands.md
