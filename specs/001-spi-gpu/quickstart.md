# Quickstart Validation Guide

**Version**: 1.0  
**Date**: January 2026

---

## Overview

This document provides validation scenarios for the ICEpi GPU. Each scenario verifies a specific capability and builds on previous ones. Complete them in order.

---

## Prerequisites

**Hardware**:
- ICEpi Zero board with ECP5-25K
- 32 MB SRAM (on-board or connected)
- RP2350 development board (Pico 2 or equivalent)
- DVI/HDMI monitor with 640×480 support
- Logic analyzer (optional, for debugging)

**Software**:
- OSS CAD Suite (yosys, nextpnr-ecp5, openFPGALoader)
- Verilator and cocotb
- RP2350 SDK (Pico SDK 2.0+)
- Python 3.9+

**Connections**:
| RP2350 Pin | GPU Pin | Function |
|------------|---------|----------|
| GP18 | SPI_SCK | SPI Clock |
| GP19 | SPI_MOSI | SPI Data Out |
| GP16 | SPI_MISO | SPI Data In |
| GP17 | SPI_CS | Chip Select |
| GP20 | CMD_FULL | FIFO Full |
| GP21 | CMD_EMPTY | FIFO Empty |
| GP22 | VSYNC | Vertical Sync |

---

## Scenario 1: SPI Communication

**Objective**: Verify basic register read/write over SPI.

**Steps**:
1. Synthesize `spi_slave` module with loopback test register
2. Program FPGA
3. Run host test:
   ```c
   // Write to test register
   gpu_write(0x7F, 0xDEADBEEF12345678);
   
   // Read back
   uint64_t val = gpu_read(0x7F);
   
   // Verify
   assert(val == GPU_ID_VALUE);  // ID register is read-only
   ```

**Expected Result**: GPU responds to SPI transactions. ID register returns expected value.

**Pass Criteria**:
- [ ] CS, SCK, MOSI signals visible on logic analyzer
- [ ] MISO returns valid data during read
- [ ] ID register reads 0x00000100_00006701 (version 1.0)

---

## Scenario 2: GPIO Status Signals

**Objective**: Verify CMD_FULL, CMD_EMPTY, VSYNC GPIO outputs.

**Steps**:
1. Monitor GPIO pins while idle
2. Burst multiple writes and observe CMD_FULL
3. Wait and observe CMD_EMPTY
4. Observe VSYNC timing

**Test Code**:
```c
// Check initial state
assert(gpio_get(PIN_CMD_EMPTY) == 1);  // Should be empty
assert(gpio_get(PIN_CMD_FULL) == 0);   // Should not be full

// Burst writes to fill FIFO
for (int i = 0; i < 20; i++) {
    gpu_write(REG_COLOR, i);
}

// Should see CMD_FULL assert
assert(gpio_get(PIN_CMD_FULL) == 1);

// Wait for FIFO to drain
sleep_ms(10);
assert(gpio_get(PIN_CMD_EMPTY) == 1);

// Measure VSYNC period
uint32_t t0 = time_us_32();
while (!gpio_get(PIN_VSYNC));
while (gpio_get(PIN_VSYNC));
while (!gpio_get(PIN_VSYNC));
uint32_t t1 = time_us_32();

// Should be ~16.67ms (60 Hz)
assert(abs((t1 - t0) - 16667) < 100);
```

**Pass Criteria**:
- [ ] CMD_EMPTY high when idle
- [ ] CMD_FULL asserts under load
- [ ] VSYNC pulses at 60 Hz ± 0.1%

---

## Scenario 3: Display Output

**Objective**: Verify DVI output with test pattern.

**Steps**:
1. Synthesize full design with test pattern generator
2. Connect to monitor via DVI/HDMI
3. Verify stable image

**Test Pattern** (hardcoded for initial test):
```verilog
// Color bars test pattern
always_comb begin
    if (x < 80) color = 24'hFF0000;       // Red
    else if (x < 160) color = 24'h00FF00; // Green
    else if (x < 240) color = 24'h0000FF; // Blue
    else if (x < 320) color = 24'hFFFF00; // Yellow
    else if (x < 400) color = 24'hFF00FF; // Magenta
    else if (x < 480) color = 24'h00FFFF; // Cyan
    else if (x < 560) color = 24'hFFFFFF; // White
    else color = 24'h000000;               // Black
end
```

**Pass Criteria**:
- [ ] Monitor detects 640×480 @ 60 Hz signal
- [ ] No rolling, tearing, or flicker
- [ ] Colors display correctly (no channel swap)
- [ ] Image stable for >1 minute

---

## Scenario 4: Framebuffer Clear

**Objective**: Verify SRAM writes via clear command.

**Steps**:
1. Set FB_DRAW to buffer A
2. Set FB_DISPLAY to buffer A
3. Clear to red
4. Verify red screen
5. Clear to blue
6. Verify blue screen

**Test Code**:
```c
gpu_write(REG_FB_DRAW, 0x000000);
gpu_write(REG_FB_DISPLAY, 0x000000);

// Clear to red
gpu_write(REG_CLEAR_COLOR, 0xFF0000FF);  // RGBA red
gpu_write(REG_CLEAR, 0);

// Wait for clear to complete
while (gpu_read(REG_STATUS) & STATUS_BUSY);

// Should see red screen
sleep_ms(1000);

// Clear to blue
gpu_write(REG_CLEAR_COLOR, 0xFFFF0000);  // RGBA blue  
gpu_write(REG_CLEAR, 0);
while (gpu_read(REG_STATUS) & STATUS_BUSY);

// Should see blue screen
```

**Pass Criteria**:
- [ ] Screen fills with solid red
- [ ] Screen fills with solid blue
- [ ] Clear completes in <5 ms
- [ ] No artifacts or partial clears

---

## Scenario 5: Flat-Shaded Triangle

**Objective**: Render a single solid-color triangle.

**Steps**:
1. Clear screen to black
2. Submit a flat-shaded triangle
3. Verify triangle appears

**Test Code**:
```c
// Clear to black
gpu_write(REG_FB_DRAW, 0x000000);
gpu_write(REG_CLEAR_COLOR, 0xFF000000);
gpu_write(REG_CLEAR, 0);
while (gpu_read(REG_STATUS) & STATUS_BUSY);

// Set flat shading mode
gpu_write(REG_TRI_MODE, 0x00);

// Red triangle
gpu_write(REG_COLOR, 0xFF0000FF);

// Vertex 0: top center
gpu_write(REG_VERTEX, PACK_XYZ(320<<4, 100<<4, 0));

// Vertex 1: bottom left
gpu_write(REG_VERTEX, PACK_XYZ(160<<4, 380<<4, 0));

// Vertex 2: bottom right (triggers draw)
gpu_write(REG_VERTEX, PACK_XYZ(480<<4, 380<<4, 0));

// Wait for completion
while (gpu_read(REG_STATUS) & STATUS_BUSY);

// Display the buffer
gpu_write(REG_FB_DISPLAY, 0x000000);
```

**Pass Criteria**:
- [ ] Red triangle visible on black background
- [ ] Triangle has correct shape (centered, pointing up)
- [ ] Edges are clean (no gaps or overdrawn pixels)
- [ ] No pixels outside triangle boundary

---

## Scenario 6: Gouraud-Shaded Triangle

**Objective**: Verify per-vertex color interpolation.

**Steps**:
1. Clear screen
2. Submit triangle with red, green, blue vertices
3. Verify smooth color gradient

**Test Code**:
```c
gpu_write(REG_TRI_MODE, TRI_GOURAUD);  // Enable Gouraud

// Red vertex
gpu_write(REG_COLOR, 0xFF0000FF);
gpu_write(REG_VERTEX, PACK_XYZ(320<<4, 100<<4, 0));

// Green vertex
gpu_write(REG_COLOR, 0xFF00FF00);
gpu_write(REG_VERTEX, PACK_XYZ(160<<4, 380<<4, 0));

// Blue vertex
gpu_write(REG_COLOR, 0xFFFF0000);
gpu_write(REG_VERTEX, PACK_XYZ(480<<4, 380<<4, 0));
```

**Pass Criteria**:
- [ ] Vertices show correct colors (red, green, blue)
- [ ] Smooth gradient across triangle
- [ ] No banding artifacts
- [ ] Center of triangle shows mixed color (grayish)

---

## Scenario 7: Z-Buffer Depth Test

**Objective**: Verify depth-correct rendering of overlapping triangles.

**Steps**:
1. Enable Z-test and Z-write
2. Clear Z-buffer
3. Draw blue triangle at Z=0.5
4. Draw red triangle at Z=0.7 (further), overlapping
5. Verify blue triangle is in front

**Test Code**:
```c
gpu_write(REG_TRI_MODE, TRI_GOURAUD | TRI_Z_TEST | TRI_Z_WRITE);

// Clear Z-buffer
gpu_write(REG_CLEAR_Z, 0);
while (gpu_read(REG_STATUS) & STATUS_BUSY);

// Blue triangle, closer (Z = 0x800000, mid-range)
gpu_write(REG_COLOR, 0xFFFF0000);
gpu_write(REG_VERTEX, PACK_XYZ(320<<4, 100<<4, 0x800000));
gpu_write(REG_VERTEX, PACK_XYZ(100<<4, 400<<4, 0x800000));
gpu_write(REG_VERTEX, PACK_XYZ(540<<4, 400<<4, 0x800000));

// Red triangle, further (Z = 0xC00000), overlapping
gpu_write(REG_COLOR, 0xFF0000FF);
gpu_write(REG_VERTEX, PACK_XYZ(320<<4, 200<<4, 0xC00000));
gpu_write(REG_VERTEX, PACK_XYZ(50<<4, 450<<4, 0xC00000));
gpu_write(REG_VERTEX, PACK_XYZ(590<<4, 450<<4, 0xC00000));
```

**Pass Criteria**:
- [ ] Blue triangle fully visible
- [ ] Red triangle only visible where not occluded by blue
- [ ] Intersection edge is clean (no Z-fighting)
- [ ] Reversing draw order produces same result

---

## Scenario 8: Textured Triangle

**Objective**: Verify texture mapping with perspective correction.

**Setup**: Upload a test texture (checkerboard pattern) to SRAM at 0x384000.

**Texture Data** (8×8 checkerboard for simplicity):
```c
uint32_t checkerboard[64];
for (int y = 0; y < 8; y++) {
    for (int x = 0; x < 8; x++) {
        checkerboard[y*8+x] = ((x ^ y) & 1) ? 0xFFFFFFFF : 0xFF000000;
    }
}
// Upload to GPU memory (requires MEM_ADDR/MEM_DATA or pre-load)
```

**Test Code**:
```c
gpu_write(REG_TRI_MODE, TRI_GOURAUD | TRI_TEXTURED);
gpu_write(REG_TEX_BASE, 0x384000);
gpu_write(REG_TEX_FMT, 0x33);  // 8×8 (log2(8) = 3)

// White vertex color (no tint)
// UV coordinates: (0,0), (1,0), (0.5,1)
// With perspective: assume W=1 for flat quad

float w = 1.0f;
gpu_write(REG_COLOR, 0xFFFFFFFF);
gpu_write(REG_UV, PACK_UVQ(0, 0, 1.0f/w));
gpu_write(REG_VERTEX, PACK_XYZ(160<<4, 120<<4, 0x800000));

gpu_write(REG_COLOR, 0xFFFFFFFF);
gpu_write(REG_UV, PACK_UVQ(1.0f, 0, 1.0f/w));
gpu_write(REG_VERTEX, PACK_XYZ(480<<4, 120<<4, 0x800000));

gpu_write(REG_COLOR, 0xFFFFFFFF);
gpu_write(REG_UV, PACK_UVQ(0.5f, 1.0f, 1.0f/w));
gpu_write(REG_VERTEX, PACK_XYZ(320<<4, 400<<4, 0x800000));
```

**Pass Criteria**:
- [ ] Checkerboard pattern visible on triangle
- [ ] Pattern is not distorted (perspective correct)
- [ ] Texture wraps correctly at boundaries
- [ ] No texture corruption or garbage pixels

---

## Scenario 9: Animated Cube

**Objective**: Render a rotating cube with per-face colors.

**Steps**:
1. Implement rotation matrix on host
2. Transform cube vertices each frame
3. Submit 12 triangles (2 per face)
4. Use double-buffering for smooth animation

**Test Code** (pseudocode):
```c
float angle = 0;
uint32_t draw_buffer = 0x000000;
uint32_t display_buffer = 0x12C000;

while (1) {
    // Wait for VSYNC
    while (!gpio_get(PIN_VSYNC));
    
    // Swap buffers
    uint32_t temp = draw_buffer;
    draw_buffer = display_buffer;
    display_buffer = temp;
    
    gpu_write(REG_FB_DRAW, draw_buffer);
    gpu_write(REG_FB_DISPLAY, display_buffer);
    
    // Clear draw buffer
    gpu_write(REG_CLEAR_COLOR, 0xFF202020);  // Dark gray
    gpu_write(REG_CLEAR, 0);
    gpu_write(REG_CLEAR_Z, 0);
    
    // Transform and submit cube
    mat4 model = rotate_y(angle) * rotate_x(angle * 0.7f);
    mat4 mvp = projection * view * model;
    
    for (int face = 0; face < 6; face++) {
        uint32_t color = face_colors[face];
        for (int tri = 0; tri < 2; tri++) {
            gpu_write(REG_TRI_MODE, TRI_GOURAUD | TRI_Z_TEST | TRI_Z_WRITE);
            
            for (int v = 0; v < 3; v++) {
                vec4 world = cube_verts[face][tri][v];
                vec4 clip = mvp * world;
                
                // Perspective divide
                float x_ndc = clip.x / clip.w;
                float y_ndc = clip.y / clip.w;
                float z_ndc = clip.z / clip.w;
                
                // Viewport transform
                int x_screen = (int)((x_ndc + 1.0f) * 320.0f);
                int y_screen = (int)((1.0f - y_ndc) * 240.0f);
                uint32_t z_buf = (uint32_t)((z_ndc + 1.0f) * 0x7FFFFF);
                
                gpu_write(REG_COLOR, color);
                gpu_write(REG_VERTEX, PACK_XYZ(x_screen<<4, y_screen<<4, z_buf));
            }
        }
    }
    
    angle += 0.02f;
}
```

**Pass Criteria**:
- [ ] Cube rotates smoothly (no stuttering)
- [ ] Faces occlude correctly (back faces hidden)
- [ ] No tearing between frames
- [ ] ~60 FPS achieved (12 triangles should be trivial)

---

## Scenario 10: Textured Cube

**Objective**: Render cube with texture on each face.

**Setup**: Upload 64×64 texture (e.g., crate texture or gradient).

**Test Code**: Same as Scenario 9, but add texture coordinates:
```c
gpu_write(REG_TRI_MODE, TRI_GOURAUD | TRI_TEXTURED | TRI_Z_TEST | TRI_Z_WRITE);
gpu_write(REG_TEX_BASE, 0x384000);
gpu_write(REG_TEX_FMT, 0x66);  // 64×64

for (int v = 0; v < 3; v++) {
    // ... transform vertex as before ...
    
    // UV coordinates for this vertex
    float u = cube_uvs[face][tri][v].u;
    float v_coord = cube_uvs[face][tri][v].v;
    float w = clip.w;
    
    gpu_write(REG_COLOR, 0xFFFFFFFF);  // No tint
    gpu_write(REG_UV, PACK_UVQ(u/w, v_coord/w, 1.0f/w));
    gpu_write(REG_VERTEX, PACK_XYZ(x_screen<<4, y_screen<<4, z_buf));
}
```

**Pass Criteria**:
- [ ] Texture visible on all faces
- [ ] Perspective-correct (no PS1-style warping)
- [ ] Texture coordinates match face orientation
- [ ] Performance still ~60 FPS

---

## Scenario 11: Utah Teapot

**Objective**: THE milestone. Render the iconic teapot with lighting.

**Setup**:
- Load teapot mesh (~1000 triangles)
- Compute vertex normals
- Implement simple diffuse lighting on host

**Test Code** (pseudocode):
```c
// Load teapot data
vec3 light_dir = normalize(vec3(1, 1, 1));

while (1) {
    wait_vsync_and_swap();
    clear_buffers();
    
    mat4 mvp = projection * view * rotate_y(angle);
    mat3 normal_mat = transpose(inverse(mat3(model)));
    
    for (int i = 0; i < teapot_tri_count; i++) {
        gpu_write(REG_TRI_MODE, TRI_GOURAUD | TRI_Z_TEST | TRI_Z_WRITE);
        
        for (int v = 0; v < 3; v++) {
            vec3 pos = teapot_verts[i][v];
            vec3 normal = teapot_normals[i][v];
            
            // Transform
            vec4 clip = mvp * vec4(pos, 1.0);
            vec3 world_normal = normalize(normal_mat * normal);
            
            // Lighting
            float ndotl = max(0.0, dot(world_normal, light_dir));
            float ambient = 0.2;
            float diffuse = ndotl * 0.8;
            uint8_t intensity = (uint8_t)((ambient + diffuse) * 255);
            
            // Copper-ish color
            uint32_t color = (0xFF << 24) | 
                             ((intensity * 180 / 255) << 0) |   // R
                             ((intensity * 120 / 255) << 8) |   // G
                             ((intensity * 80 / 255) << 16);    // B
            
            // Screen transform
            // ... as before ...
            
            gpu_write(REG_COLOR, color);
            gpu_write(REG_VERTEX, PACK_XYZ(x<<4, y<<4, z));
        }
    }
    
    angle += 0.01f;
}
```

**Pass Criteria**:
- [ ] Teapot is recognizable (spout, handle, lid visible)
- [ ] Lighting creates visible shading gradient
- [ ] No obvious holes or missing triangles
- [ ] Smooth rotation (≥30 FPS target)
- [ ] Z-buffer handles self-occlusion correctly

---

## Performance Validation

### Triangle Throughput Test

```c
// Submit maximum triangles per frame
int triangles_drawn = 0;
uint32_t frame_start = time_us_32();

while (time_us_32() - frame_start < 16667) {  // One frame @ 60Hz
    // Minimal triangle (flat, no Z)
    gpu_write(REG_TRI_MODE, 0x00);
    gpu_write(REG_COLOR, 0xFFFFFFFF);
    gpu_write(REG_VERTEX, PACK_XYZ(0, 0, 0));
    gpu_write(REG_VERTEX, PACK_XYZ(16, 0, 0));
    gpu_write(REG_VERTEX, PACK_XYZ(0, 16, 0));
    triangles_drawn++;
}

printf("Triangles per frame: %d\n", triangles_drawn);
printf("Triangles per second: %d\n", triangles_drawn * 60);
```

**Expected Results**:
| Metric | Target | Notes |
|--------|--------|-------|
| Tri/frame (SPI-limited) | ~500 | At 25 MHz SPI |
| Tri/frame (fill-limited) | ~2000 | Small triangles |
| Fill rate | 25 Mpix/s | Full pipeline |

### Memory Bandwidth Test

```c
// Clear entire screen repeatedly
uint32_t clears = 0;
uint32_t test_start = time_us_32();

while (time_us_32() - test_start < 1000000) {  // 1 second
    gpu_write(REG_CLEAR, 0);
    while (gpu_read(REG_STATUS) & STATUS_BUSY);
    clears++;
}

// 640*480*4 bytes per clear
float bandwidth = (clears * 640 * 480 * 4) / 1000000.0f;
printf("Clear bandwidth: %.1f MB/s\n", bandwidth);
```

**Expected**: >50 MB/s clear bandwidth

---

## Troubleshooting

### No Display Output

1. Check DVI cable connection
2. Verify PLL lock (status LED if available)
3. Try different monitor (some don't support 640×480)
4. Check TMDS signal integrity with oscilloscope

### SPI Communication Fails

1. Verify voltage levels (3.3V)
2. Check SPI mode (Mode 0)
3. Reduce SPI clock speed
4. Verify CS polarity (active low)

### Triangles Not Visible

1. Check vertex winding order (CCW default)
2. Verify coordinate range (0-639, 0-479)
3. Check TRI_MODE register setting
4. Ensure FB_DRAW and FB_DISPLAY are set

### Z-Buffer Issues

1. Verify Z-buffer is cleared before frame
2. Check Z value range (0 = near, 0xFFFFFF = far)
3. Ensure Z_TEST and Z_WRITE are enabled

### Texture Corruption

1. Verify texture is uploaded to correct address
2. Check TEX_BASE is 4K aligned
3. Verify TEX_FMT matches actual dimensions
4. Check UV coordinate range (0.0 - 1.0)

---

## Checklist Summary

| Scenario | Description | Status |
|----------|-------------|--------|
| 1 | SPI Communication | [ ] |
| 2 | GPIO Status Signals | [ ] |
| 3 | Display Output | [ ] |
| 4 | Framebuffer Clear | [ ] |
| 5 | Flat-Shaded Triangle | [ ] |
| 6 | Gouraud-Shaded Triangle | [ ] |
| 7 | Z-Buffer Depth Test | [ ] |
| 8 | Textured Triangle | [ ] |
| 9 | Animated Cube | [ ] |
| 10 | Textured Cube | [ ] |
| 11 | Utah Teapot | [ ] |

**All scenarios passing = Project complete!**
