# Data Model: ICEpi GPU Internal State

**Version**: 1.0  
**Date**: January 2026

---

## Overview

This document describes the internal data structures and state machines within the GPU. These are not directly visible to the host but are essential for understanding the implementation.

---

## Vertex State

### Vertex Buffer (3 entries)

```
vertex_buffer[0..2] = {
    x:      17 bits (12.4 signed fixed-point + overflow)
    y:      17 bits (12.4 signed fixed-point + overflow)
    z:      25 bits (depth value)
    r:      8 bits
    g:      8 bits
    b:      8 bits
    a:      8 bits
    u_q:    16 bits (U/W, 1.15 fixed-point)
    v_q:    16 bits (V/W, 1.15 fixed-point)
    q:      16 bits (1/W, 1.15 fixed-point)
}
```

**Total per vertex**: 139 bits  
**Total buffer**: 417 bits

### Vertex Counter

```
vertex_count: 2 bits (0, 1, 2)
```

State transitions:
```
VERTEX write → vertex_buffer[vertex_count] = {latched_color, latched_uv, xyz}
            → vertex_count = (vertex_count + 1) mod 3
            → if vertex_count was 2: emit triangle_valid
```

### Latched Attributes

```
latched_color = {
    r: 8 bits
    g: 8 bits
    b: 8 bits
    a: 8 bits
}

latched_uv = {
    u_q: 16 bits
    v_q: 16 bits
    q:   16 bits
}
```

Updated by COLOR and UV register writes respectively.

---

## Triangle Setup Output

### Edge Equations

For each edge (3 total):

```
edge[0..2] = {
    a:  32 bits (coefficient for x, signed)
    b:  32 bits (coefficient for y, signed)
    c:  32 bits (constant term, signed)
}
```

Edge function: E(x,y) = a*x + b*y + c

Sign indicates inside/outside.

### Attribute Gradients

For each interpolated attribute:

```
gradient = {
    dx: 32 bits (change per pixel in x, signed fixed-point)
    dy: 32 bits (change per pixel in y, signed fixed-point)
}
```

Attributes requiring gradients:
- R, G, B, A (4 gradients)
- U/W, V/W, 1/W (3 gradients for texturing)
- Z (1 gradient for depth)

**Total gradients**: 8 × 2 × 32 = 512 bits

### Bounding Box

```
bbox = {
    x_min: 10 bits (0-639)
    x_max: 10 bits (0-639)
    y_min: 9 bits (0-479)
    y_max: 9 bits (0-479)
}
```

**Total**: 38 bits

### Initial Attribute Values

Starting values at (x_min, y_min):

```
attr_start = {
    r:   16 bits (extended precision)
    g:   16 bits
    b:   16 bits
    a:   16 bits
    u_q: 24 bits (extended for accumulation)
    v_q: 24 bits
    q:   24 bits
    z:   32 bits (extended for interpolation)
}
```

**Total**: 168 bits

---

## Rasterizer State

### State Machine

```
enum rasterizer_state {
    IDLE,           // Waiting for triangle
    SETUP,          // Computing edge equations and gradients
    SCANLINE_START, // Beginning new scanline
    PIXEL,          // Processing pixels
    SCANLINE_END,   // Completed scanline
    DONE            // Triangle complete
}
```

### Iteration Variables

```
current_y:    10 bits (current scanline)
current_x:    10 bits (current pixel)
span_start:   10 bits (left edge of current span)
span_end:     10 bits (right edge of current span)
```

### Edge Accumulators

```
edge_val[0..2]: 32 bits each (current edge function value)
```

Updated per-pixel: `edge_val[i] += edge[i].a`  
Updated per-scanline: `edge_val[i] += edge[i].b` (and reset x component)

### Attribute Accumulators

```
attr_accum = {
    r:   16 bits
    g:   16 bits
    b:   16 bits
    a:   16 bits
    u_q: 24 bits
    v_q: 24 bits
    q:   24 bits
    z:   32 bits
}
```

Updated per-pixel: `attr += gradient.dx`  
Updated per-scanline: `attr = attr_start + (y - y_min) * gradient.dy`

---

## Pixel Pipeline State

### Pipeline Registers

The pixel pipeline is a multi-stage pipeline. Each stage has its own set of registers:

**Stage 1: Coordinate + Raw Attributes**
```
pipe1 = {
    valid:  1 bit
    x:      10 bits
    y:      10 bits
    r:      8 bits
    g:      8 bits
    b:      8 bits
    a:      8 bits
    u_q:    16 bits
    v_q:    16 bits
    q:      16 bits
    z:      24 bits
}
```

**Stage 2: Reciprocal Lookup**
```
pipe2 = {
    valid:  1 bit
    x:      10 bits
    y:      10 bits
    r, g, b, a: (pass through)
    u_q, v_q: (pass through)
    recip_est: 16 bits (from LUT)
    z:      24 bits
}
```

**Stage 3: Reciprocal Refinement**
```
pipe3 = {
    valid:  1 bit
    x, y, r, g, b, a: (pass through)
    u_q, v_q: (pass through)
    recip:  16 bits (refined 1/Q)
    z:      24 bits
}
```

**Stage 4: UV Computation**
```
pipe4 = {
    valid:  1 bit
    x, y, r, g, b, a, z: (pass through)
    u:      16 bits (final texture U)
    v:      16 bits (final texture V)
}
```

**Stage 5: Texture Address**
```
pipe5 = {
    valid:  1 bit
    x, y, r, g, b, a, z: (pass through)
    tex_addr: 24 bits (SRAM address for texel)
}
```

**Stage 6: Texture Fetch (wait for SRAM)**
```
pipe6 = {
    valid:  1 bit
    x, y, r, g, b, a, z: (pass through)
    tex_r, tex_g, tex_b, tex_a: 8 bits each
}
```

**Stage 7: Color Blend**
```
pipe7 = {
    valid:  1 bit
    x, y, z: (pass through)
    final_r, final_g, final_b, final_a: 8 bits each
}
```

**Stage 8: Z-Test (wait for Z read)**
```
pipe8 = {
    valid:  1 bit
    x, y: (pass through)
    final_color: 32 bits
    z_new:      24 bits
    z_pass:     1 bit
}
```

**Stage 9: Write**
```
// Output to SRAM arbiter
write_req = {
    valid:      1 bit
    fb_addr:    24 bits
    fb_data:    32 bits
    fb_we:      1 bit
    z_addr:     24 bits
    z_data:     24 bits
    z_we:       1 bit
}
```

---

## SRAM Arbiter State

### Request Queues

```
display_req = {
    valid:  1 bit
    addr:   24 bits
}

texture_req = {
    valid:  1 bit
    addr:   24 bits
}

fb_write_req = {
    valid:  1 bit
    addr:   24 bits
    data:   32 bits
}

z_req = {
    valid:  1 bit
    addr:   24 bits
    data:   24 bits (for write)
    we:     1 bit
}
```

### Arbiter State

```
enum arbiter_state {
    IDLE,
    DISPLAY_READ,
    TEXTURE_READ,
    FB_WRITE_LO,
    FB_WRITE_HI,
    Z_READ,
    Z_WRITE
}

current_grant: 2 bits (which requestor is active)
```

### SRAM Interface State

```
sram_state = {
    addr:   24 bits (active address)
    wdata:  16 bits (write data)
    rdata:  16 bits (read data, latched)
    we:     1 bit
    oe:     1 bit
    pending_high: 1 bit (for 32-bit operations)
}
```

---

## Display Controller State

### Timing State

```
h_count:    10 bits (0 to H_TOTAL-1 = 799)
v_count:    10 bits (0 to V_TOTAL-1 = 524)
h_sync:     1 bit
v_sync:     1 bit
h_blank:    1 bit
v_blank:    1 bit
active:     1 bit (in visible region)
```

### Scanline FIFO State

```
fifo_wptr:  11 bits (write pointer, 2 scanlines × 640)
fifo_rptr:  11 bits (read pointer)
fifo_count: 11 bits (entries in FIFO)
```

### Prefetch State

```
prefetch_y:     9 bits (scanline being prefetched)
prefetch_x:     10 bits (pixel being prefetched)
prefetch_active: 1 bit
```

---

## Command FIFO State

### FIFO Structure

```
cmd_fifo[0..15] = {
    addr: 7 bits
    data: 64 bits
}
```

**Total per entry**: 71 bits  
**Total FIFO**: 71 × 16 = 1,136 bits

### Pointers

```
write_ptr:  4 bits (gray-coded for CDC)
read_ptr:   4 bits (gray-coded for CDC)
```

### Derived Signals

```
fifo_empty:       (write_ptr == read_ptr)
fifo_full:        (write_ptr == read_ptr + 16) // with wrap
fifo_almost_full: (count >= 14)
fifo_count:       (write_ptr - read_ptr) // with wrap handling
```

---

## Configuration Registers (Active Values)

These are the register values currently in effect (as opposed to the register file which holds written values):

```
config = {
    tri_mode:   8 bits
    tex_base:   20 bits (4K-aligned address >> 12)
    tex_width:  4 bits (log2)
    tex_height: 4 bits (log2)
    fb_draw:    20 bits (4K-aligned address >> 12)
    fb_display: 20 bits (4K-aligned address >> 12)
    clear_color: 32 bits
}
```

**Note**: `fb_display` update is deferred to VSYNC to prevent tearing.

---

## Status Flags

```
status = {
    busy:           1 bit (any operation in progress)
    raster_busy:    1 bit (rasterizer active)
    clear_busy:     1 bit (clear in progress)
    fifo_depth:     5 bits (0-16)
    vblank:         1 bit (in vertical blanking)
}
```

---

## Total State Summary

| Component | Bits | Notes |
|-----------|------|-------|
| Vertex buffer | 417 | 3 vertices |
| Latched attributes | 80 | Color + UV |
| Triangle setup | ~750 | Edges + gradients |
| Rasterizer | ~200 | Counters + accumulators |
| Pixel pipeline | ~800 | 9 stages |
| SRAM arbiter | ~100 | Requests + state |
| Display controller | ~100 | Timing + prefetch |
| Command FIFO | ~1,200 | 16 entries + pointers |
| Config registers | ~130 | Active configuration |
| **Total** | ~3,800 bits | ~475 bytes |

This easily fits in ECP5 flip-flops with room to spare.
