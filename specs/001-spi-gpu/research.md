# Research Notes: ICEpi SPI GPU

**Date**: January 2026

---

## PS2 Graphics Synthesizer Reference

### Architecture Overview

The PlayStation 2 GS was a dedicated rasterizer that received pre-transformed primitives from the Emotion Engine (EE) and Vector Units (VU0/VU1). Key characteristics:

- **Not a GPU in the modern sense**: No vertex shaders, no programmable pipeline
- **Pure rasterizer**: Takes screen-space triangles, fills pixels
- **High bandwidth**: 48 GB/s internal bandwidth (embedded DRAM)
- **Register-based interface**: Primitives submitted via register writes

### GS Primitive Submission

The GS used a "GIF" (Graphics Interface) to receive commands. Primitives were submitted by writing vertex data to registers, with a "kick" mechanism to trigger drawing:

```
PRIM    - Primitive type and attributes
RGBAQ   - Vertex color + Q (1/W)
ST      - Texture coordinates (S/T, pre-divided by Q)
UV      - Alternative texture coords (integer)
XYZ2    - Vertex position + kick
XYZ3    - Vertex position + kick (with fog)
```

The pattern of "set attributes, then write XYZ to push vertex" directly inspires our register interface.

### Perspective Correction

The GS received Q = 1/W from the VUs. Texture coordinates were pre-divided:
- S = U/W
- T = V/W
- Q = 1/W

Per pixel, the GS computed:
```
U_final = S / Q = (U/W) / (1/W) = U
V_final = T / Q = (V/W) / (1/W) = V
```

This moves the expensive division to per-vertex (done by VUs) rather than per-pixel.

### What We're Borrowing

1. Register-based vertex submission with implicit kick
2. Pre-divided texture coordinates (U/W, V/W, 1/W)
3. Separation of vertex processing (host) from rasterization (GPU)
4. Fixed-function pipeline with configurable modes

### What We're Simplifying

1. Single texture unit (GS had complex multitexture)
2. No CLUT (color lookup table)
3. No alpha blending (initially)
4. No fog
5. Much lower bandwidth target

---

## ECP5 FPGA Resources

### Lattice ECP5-25K Specifications

| Resource | Count |
|----------|-------|
| LUTs (4-input) | 24,288 |
| Flip-flops | 24,288 |
| Distributed RAM | 194 kbits |
| Block RAM (EBR) | 1,008 kbits (56 × 18kbit) |
| DSP blocks (MULT18X18D) | 28 |
| PLLs | 2 |
| SERDES channels | 2 (up to 3.125 Gbps each) |

### Block RAM (EBR) Configuration

Each 18kbit EBR can be configured as:
- 16K × 1
- 8K × 2
- 4K × 4
- 2K × 9
- 1K × 18
- 512 × 36

For scanline FIFO (2 × 640 × 32 = 40,960 bits):
- Need 3 EBRs in 1K × 18 mode (cascaded for width)
- Or 2 EBRs in 512 × 36 mode + extra for depth

### DSP Block (MULT18X18D)

- 18×18 signed multiply
- Optional accumulator
- Pipeline registers available
- Can cascade for larger operations

**Usage in GPU**:
- Edge function evaluation: 3-4 DSPs
- Attribute interpolation: 4-6 DSPs
- Reciprocal iteration: 2 DSPs
- Texture coordinate multiply: 2 DSPs
- Color blending: 3-4 DSPs

### SERDES for DVI

ECP5 SERDES can output 10-bit TMDS at up to 3.125 Gbps:
- 640×480@60 requires 251.75 Mbps per channel
- Well within capability
- Use DDR output mode for lower SERDES rate

---

## DVI/HDMI Output

### TMDS Encoding

Transition Minimized Differential Signaling:
1. XOR or XNOR the 8 input bits based on bit count
2. Conditionally invert to maintain DC balance
3. Output 10-bit symbol

```
Algorithm:
  if popcount(D) > 4 or (popcount(D) == 4 and D[0] == 0):
    q_m = XNOR encoding
  else:
    q_m = XOR encoding
    
  // DC balance based on running disparity
  if disparity == 0 or popcount(q_m) == 4:
    if q_m[8] == 0:
      q_out = {~q_m[8], q_m[8], ~q_m[7:0]}
    else:
      q_out = {~q_m[8], q_m[8], q_m[7:0]}
  else:
    // Complex balancing logic...
```

### 640×480@60 Timing (CEA-861)

| Parameter | Value |
|-----------|-------|
| Pixel clock | 25.175 MHz |
| H active | 640 |
| H front porch | 16 |
| H sync | 96 |
| H back porch | 48 |
| H total | 800 |
| V active | 480 |
| V front porch | 10 |
| V sync | 2 |
| V back porch | 33 |
| V total | 525 |
| H sync polarity | Negative |
| V sync polarity | Negative |

### HDMI Compatibility

DVI and HDMI share the same TMDS encoding. For HDMI:
- Data island periods contain audio/info
- We're not implementing audio, so pure DVI signal
- Most HDMI monitors accept DVI signals

---

## Triangle Rasterization Algorithms

### Edge Function Approach

For edge from vertex A to vertex B, the edge function is:
```
E(P) = (B.x - A.x)(P.y - A.y) - (B.y - A.y)(P.x - A.x)
```

A point P is inside the triangle if all three edge functions have the same sign (or zero for on-edge).

**Advantages**:
- Embarrassingly parallel (each pixel independent)
- Simple hardware implementation
- Natural for fill rule handling

**For scanline rasterization**:
- Evaluate at (x, y)
- Increment: E(x+1, y) = E(x, y) + (B.y - A.y)
- New scanline: E(x, y+1) = E(x, y) - (B.x - A.x)

### Bresenham vs Edge Walking

**Bresenham** (for lines):
- Integer only
- Single pixel per step
- Not directly applicable to filled triangles

**Edge Walking** (our approach):
- Track left and right edges
- For each scanline, walk from left to right
- Simple and predictable memory access pattern

### Top-Left Fill Rule

To avoid double-drawing shared edges:
- A pixel is inside if it's strictly inside, OR
- On a "top" edge (horizontal, above other vertices), OR  
- On a "left" edge (going down-left)

Implementation: Bias edge functions by small epsilon for top/left edges.

---

## Fixed-Point Arithmetic

### Format Notation

X.Y means X integer bits (including sign) and Y fractional bits.

Example: 12.4 signed
- Total bits: 16
- Range: -2048.0 to +2047.9375
- Resolution: 0.0625 (1/16)

### Required Formats

| Quantity | Format | Bits | Range | Resolution |
|----------|--------|------|-------|------------|
| Screen X, Y | 12.4 signed | 16 | ±2048 | 1/16 pixel |
| Z depth | 0.24 unsigned | 24 | 0-1 | 1/16M |
| Color channel | 0.8 unsigned | 8 | 0-255 | 1 |
| UV coordinate | 1.15 signed | 16 | ±1 | 1/32768 |
| 1/W (Q) | 1.15 signed | 16 | ±1 | 1/32768 |

### Multiplication Considerations

12.4 × 12.4 = 24.8 (needs 32-bit intermediate)
1.15 × 1.15 = 2.30 (needs 32-bit, then truncate)

DSP blocks handle 18×18 signed, sufficient for our formats.

---

## Reciprocal Approximation

### Newton-Raphson Method

To find 1/D:
1. Initial estimate r₀ (from LUT)
2. Iterate: r_{n+1} = r_n × (2 - D × r_n)

Each iteration roughly doubles precision.

### LUT Sizing

For 16-bit Q input:
- Use top 8 bits as LUT index
- 256 entries × 16 bits = 512 bytes (4 EBRs in minimal config, or use distributed RAM)
- One NR iteration gives ~16 bits precision

### Implementation

```verilog
// Stage 1: LUT lookup (combinational)
wire [15:0] r0 = recip_lut[q_in[15:8]];

// Stage 2: First multiply D × r0
wire [31:0] dr0 = q_in * r0;

// Stage 3: Subtract from 2.0 (in 1.15 format, 2.0 = 0x10000 conceptually)
// Actually compute (2 - D×r0) in appropriate format
wire [15:0] two_minus_dr0 = 16'h8000 - dr0[30:15];  // Adjust for format

// Stage 4: Second multiply r0 × (2 - D×r0)
wire [31:0] r1_full = r0 * two_minus_dr0;
wire [15:0] r1 = r1_full[30:15];  // Final reciprocal
```

---

## SRAM Interface Timing

### Async SRAM Typical Timing (10ns grade)

| Parameter | Symbol | Value |
|-----------|--------|-------|
| Read cycle time | t_RC | 10 ns |
| Address access time | t_AA | 10 ns |
| OE access time | t_OE | 4 ns |
| Write cycle time | t_WC | 10 ns |
| Write pulse width | t_WP | 7 ns |
| Data setup | t_DW | 5 ns |
| Data hold | t_DH | 0 ns |

### Controller State Machine

At 100 MHz (10 ns cycle), we can achieve single-cycle operations:

**Read**:
```
Cycle 0: Drive address, assert OE
Cycle 1: Data valid, latch result
```

**Write**:
```
Cycle 0: Drive address + data, assert WE
Cycle 1: Deassert WE (data latched on rising edge)
```

For 32-bit access (16-bit bus):
- 2 cycles for read (interleaved low/high)
- 2 cycles for write (sequential low/high)

---

## Host MCU: RP2350

### Specifications

| Feature | Value |
|---------|-------|
| Cores | Dual ARM Cortex-M33 |
| Clock | Up to 150 MHz |
| FPU | Single-precision hardware float |
| SRAM | 520 KB |
| Flash | External, up to 16 MB |
| SPI | 2× SPI controllers, up to 62.5 MHz |

### SPI Throughput

At 25 MHz SPI clock, 72-bit transactions:
```
72 bits / 25 MHz = 2.88 µs per transaction
~347,000 transactions/second
```

For triangles (assuming 10 transactions per tri):
```
347,000 / 10 = 34,700 triangles/second max
```

At 60 FPS: ~578 triangles per frame (SPI-limited)

### FPU Performance

Single-precision operations:
- Add/sub: 1 cycle
- Multiply: 1 cycle
- Divide: 14 cycles
- Sqrt: 14 cycles

Matrix multiply (4×4 × vec4): ~64 cycles
Per-vertex transform: ~100-150 cycles
At 150 MHz: ~1M vertices/second theoretical

---

## References

### Books & Papers

1. Abrash, Michael. "Graphics Programming Black Book"
   - Classic rasterization algorithms

2. Hecker, Chris. "Perspective Texture Mapping" (Game Developer, 1995-1996)
   - Detailed 1/W derivation

3. Pineda, Juan. "A Parallel Algorithm for Polygon Rasterization" (SIGGRAPH 1988)
   - Edge function approach

### Online Resources

1. Scratchapixel - Rasterization tutorials
   https://www.scratchapixel.com/

2. Fabien Sanglard - PS2 architecture
   https://fabiensanglard.net/

3. Project F - FPGA graphics tutorials
   https://projectf.io/

4. ECP5 Documentation
   - Lattice ECP5 Family Data Sheet
   - ECP5 sysCLOCK PLL Design Guide
   - ECP5 SERDES/PCS Design Guide

### Open Source Projects

1. **litex** - SoC builder with video output examples
   https://github.com/enjoy-digital/litex

2. **icestation-32** - FPGA game console with 3D graphics
   https://github.com/dan-rodrigues/icestation-32

3. **verilog-vga** - Simple VGA controller reference
   https://github.com/projf/projf-explore

4. **tinyTPU** - Small-scale GPU-like accelerator
   (various academic implementations)

---

## Open Design Questions

### Q1: Texture Wrap vs Clamp

**Current decision**: Wrap (repeat) mode only

**Rationale**: Simpler to implement (bitwise AND), most common use case

**Future**: Add mode bit for clamp if needed

### Q2: Z-Buffer Precision

**Current decision**: 24-bit

**Rationale**: 16-bit shows Z-fighting on large depth ranges; 24-bit is standard; 32-bit wastes bandwidth

**Observation**: PS2 used 24-bit Z

### Q3: Separate Clear Commands

**Current decision**: Separate CLEAR (color) and CLEAR_Z

**Rationale**: Allows clearing one without the other; common pattern is "clear Z every frame, clear color less often"

### Q4: Texture Format

**Current decision**: RGBA8888 only

**Rationale**: Simplest implementation; matches framebuffer format; no format conversion needed

**Future**: RGB565 would halve texture bandwidth

### Q5: Explicit Draw Kick

**Current decision**: Implicit on third vertex

**Rationale**: Matches GS pattern; fewer register writes; natural "immediate mode" feel

**Alternative**: Explicit DRAW register after setting all vertices - allows vertex reuse, but more complex
