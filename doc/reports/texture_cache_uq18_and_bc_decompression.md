# Technical Report: Texture Cache UQ1.8 Storage and BC Decompression Design

Date: 2026-03-14
Status: Superseded (see note below)

## Background

**Superseded Note (2026-03-15):** The switchable 18/36-bit cache mode investigated in this report (DD-040) has been superseded.
The texture cache now operates exclusively in UQ1.8 (36-bit) mode; the RGBA5652 (18-bit) path was never implemented and the CACHE_MODE register bit is reserved.
This report is retained for historical context on the investigation that led to the UQ1.8-only decision.
See DD-040 in `design_decisions.md` for the supersession record.

The texture cache architecture (INT-032) originally specified RGBA5652 (18-bit) as the cache storage format, with decompressed texels promoted to Q4.12 for the fragment pipeline.
As the project approached detailed design and digital twin implementation of the texture sampler caches and BC block decompression, several design refinements were identified that could improve quality, reduce DSP consumption, and enable future optimizations.

This report investigated five interrelated design questions before committing them to the gs-twin detailed design:
1. Storing texels as 36-bit RGBA UQ1.8 instead of 18-bit RGBA5652 in cache EBRs
2. Four-bank interleaved texel access for single-cycle bilinear sampling
3. 4x4 block cache line alignment with BC block boundaries
4. Texture prefetch to overlap SDRAM fetches with active sampling
5. BC texture decompression without DSP multiply units

## Scope

### Questions investigated

1. **EBR feasibility of switchable 18/36-bit cache:** Can the texture cache support both 18-bit RGBA5652 (high capacity) and 36-bit UQ1.8 (high quality) storage modes using the same EBR allocation? *(Outcome: feasible, but the switchable mode was superseded in favor of UQ1.8-only; see DD-040.)*
2. **Quality benefit of UQ1.8 cache storage:** What precision improvements does pre-expanded UQ1.8 provide over RGBA5652, per source format?
3. **Bilinear bank interleaving edge cases:** Does the 4-bank scheme produce correct results when texture mirroring or clamping causes bilinear taps to alias?
4. **Prefetch feasibility:** Is the rasterizer's traversal pattern predictable enough for effective texture prefetch, and what is the hardware cost?
5. **BC decompression without DSP:** Can BC1/BC2/BC3/BC4 palette interpolation be implemented without consuming MULT18X18D blocks?

### Out of scope

- Trilinear filtering (LOD blending between mip levels)
- Cycle-level SDRAM arbiter scheduling
- SPI transport and command FIFO interactions
- Display controller and scan-out

## Investigation

### Documents and code examined

- INT-032 (`doc/interfaces/int_032_texture_cache_architecture.md`) — Cache architecture specification
- INT-014 (`doc/interfaces/int_014_texture_memory_layout.md`) — Texture memory layout
- REQ-003.03 (compressed-texture requirement; document since removed during INDEXED8_2X2 pivot) — Compressed texture requirement
- ARCHITECTURE.md — EBR budget (lines 320–333), DSP budget, pipeline description
- `spi_gpu/src/render/texture_cache.sv` — RTL cache implementation (700 lines)
- `spi_gpu/src/render/texture_bc1.sv` — BC1 decoder (146 lines)
- `spi_gpu/src/render/texture_bc2.sv` — BC2 decoder (106 lines)
- `spi_gpu/src/render/texture_bc3.sv` — BC3 decoder (130 lines)
- `spi_gpu/src/render/texture_bc4.sv` — BC4 decoder (85 lines)
- `spi_gpu/dt/gs-twin/src/pipeline/tex_sample.rs` — Digital twin texture sampler (776 lines)
- `spi_gpu/dt/gs-twin/src/mem.rs` — Digital twin memory model (358 lines)
- `.claude/skills/ecp5-sv-yosys-verilator/SKILL.md` — ECP5 primitive reference
- `.claude/skills/ecp5-sv-yosys-verilator/references/dsp_guide.md` — DSP tile architecture
- `.claude/skills/ecp5-sv-yosys-verilator/references/ecp5_bram_guide.md` — DP16KD/PDPW16KD reference
- `doc/design/design_decisions.md` — DD-035, DD-039, DD-040 (DSP budget history)

## Findings

### 1. Switchable 18/36-bit cache is feasible at zero extra EBR cost

#### Current design

Each sampler uses 4 bilinear-interleaved banks, each bank comprising 4 depth-cascaded DP16KD blocks in 1024x18 mode:
- 4 EBR per bank x 4 banks = 16 EBR per sampler
- 2 samplers x 16 = 32 EBR total
- 4096 entries per bank (4 x 1024), 1024 cache lines, 16,384 texels cached

#### Proposed design: PDPW16KD in 512x36 mode

DP16KD cannot be configured at 36-bit data width — that configuration requires PDPW16KD (ECP5 skill pitfall #7: "You cannot set DATA_WIDTH_A=36 and use DP16KD — that is a PDPW16KD").

PDPW16KD is pseudo-dual-port: one write-only port (always 36 bits in Yosys flow per pitfall #2) and one read-only port (configurable at 9, 18, or 36 bits).
This maps naturally to the texture cache's access pattern: cache fill writes, texture sampling reads.

With 4 depth-cascaded PDPW16KD per bank (each 512x36):

| Mode              | Entry width            | Entries/bank | Texels/bank | Cache lines | Texels cached | Equivalent area |
| ----------------- | ---------------------- | ------------ | ----------- | ----------- | ------------- | --------------- |
| **36-bit UQ1.8**  | 36 bits (4x UQ1.8)     | 2048         | 2048        | 512         | 8,192         | ~90x90          |
| **18-bit packed** | 2x RGBA5652 in 36 bits | 2048         | 4096        | 1024        | 16,384        | ~128x128        |

**EBR cost: identical to current design** — 16 EBR per sampler, 32 total.
The 36-bit mode trades half the cache capacity for higher texel precision.

#### Read path implementation

Always read 36 bits from the PDPW16KD read port.
In 18-bit packed mode, the texel address LSB selects upper or lower 18-bit half via a 2:1 mux (~18 LUTs).
In 36-bit mode, the full 36-bit output is the UQ1.8 texel (R9, G9, B9, A9).

The mode bit would be a per-sampler configuration field in TEXn_CFG, allowing different textures to use different cache formats.

#### Fill path implications

In UQ1.8 mode, the decompression logic must produce 36-bit UQ1.8 texels instead of 18-bit RGBA5652.
This means the format decoders should:
1. Decode to their natural precision (e.g., 8-bit interpolated alpha for BC3, 8-bit RGB for BC1 after expanding endpoints to 8-bit)
2. Convert to UQ1.8 using the MSB-replication formulas already defined in `tex_sample.rs` lines 199–222
3. Write 36-bit entries to the PDPW16KD write port

In RGBA5652 mode, the existing decode-and-pack path is used, writing two 18-bit texels per 36-bit entry.

#### Concurrent fill and sample (prefetch enabler)

PDPW16KD's independent read and write ports enable concurrent cache fill (to a victim line) and texture sampling (from a hit line) without port contention.
This is a prerequisite for the prefetch optimization discussed in Finding 4.
By contrast, DP16KD true dual-port would also support this but cannot be configured at 36-bit width.

### 2. Quality benefit analysis by source format

The quality difference between RGBA5652 and UQ1.8 cache storage depends on the source format's native precision.
When the source has more precision than RGBA5652 can represent, truncation destroys information that UQ1.8 would preserve.

#### Per-format analysis

**BC1 colors (FORMAT=0):**
- Endpoints are RGB565 (5/6/5 bits per channel)
- The DXT specification defines interpolated colors (1/3 and 2/3 blends) in 8-bit-expanded space
- Current RTL (`texture_bc1.sv` lines 72–84) interpolates in 5/6/5-bit space, producing the same precision as endpoints
- With UQ1.8 storage, endpoints can be expanded to 8-bit first (R5 -> R8 via MSB replication), interpolated at 8-bit precision, then stored as UQ1.8
- Worked example (R5 channel, endpoints 31 and 0):
  - Current (5-bit): `(2*31 + 0 + 1)/3 = 21` → stored as R5=21 → UQ1.8 = 174
  - Proposed (8-bit): expand 31→255, 0→0, `(2*255 + 0 + 1)/3 = 170` → stored as UQ1.8 = 170
  - Difference: 4 UQ1.8 LSBs (~1.6% of full scale)
- **Verdict:** Moderate improvement. Smoother color ramps within compressed blocks.

**BC2 (FORMAT=1):**
- Color: same improvement as BC1 (8-bit interpolation)
- Alpha: 4-bit explicit alpha, currently truncated to A2 (4 levels). UQ1.8 preserves the full 4-bit alpha as 16 levels (expanded via `(a4 << 4) | a4` to 8-bit, then to UQ1.8).
- **Verdict:** Significant alpha improvement (16 levels vs 4).

**BC3 (FORMAT=2):**
- Color: same improvement as BC1
- Alpha: 8-bit interpolated palette (6 or 8 entries between two 8-bit endpoints), currently truncated to A2 (4 levels!). UQ1.8 preserves the full 8-bit interpolated alpha.
- **Verdict:** Major alpha improvement (256 levels vs 4). This is the single largest quality win.

**BC4 (FORMAT=3):**
- Single-channel 8-bit with BC3-style interpolation
- Currently truncated to R5 (32 levels), replicated to G6, B5
- UQ1.8 preserves the full 8-bit red channel (256 levels), replicated uniformly
- **Verdict:** Major improvement (256 vs 32 levels) for heightmaps, grayscale, or AO maps.

**RGB565 (FORMAT=4):**
- Source precision matches RGBA5652 exactly (5/6/5 bits)
- UQ1.8 expansion adds no new information (the 32/64/32 distinct levels remain the same)
- **Verdict:** No quality difference. Capacity-conscious textures should use 18-bit packed mode.

**RGBA8888 (FORMAT=5):**
- R: 256 levels truncated to 32 (R5). UQ1.8 preserves all 256.
- G: 256 levels truncated to 64 (G6). UQ1.8 preserves all 256.
- B: 256 levels truncated to 32 (B5). UQ1.8 preserves all 256.
- A: 256 levels truncated to 4 (A2). UQ1.8 preserves all 256.
- **Verdict:** Massive improvement across all channels. RGBA8888 textures should always use 36-bit mode.

**R8 (FORMAT=6):**
- 256 levels truncated to 32 (R5). UQ1.8 preserves all 256.
- **Verdict:** Major improvement (256 vs 32 levels).

#### Summary table

| Source format | RGBA5652 levels (R/G/B/A) | UQ1.8 levels (R/G/B/A) | Quality gain        | Recommended mode |
| ------------- | ------------------------- | ---------------------- | ------------------- | ---------------- |
| BC1           | 32/64/32/2                | ~86/171/86/2           | Moderate (color)    | 36-bit           |
| BC2           | 32/64/32/4                | ~86/171/86/16          | Significant (alpha) | 36-bit           |
| BC3           | 32/64/32/4                | ~86/171/86/256         | Major (alpha)       | 36-bit           |
| BC4           | 32/64/32/—                | 256/256/256/—          | Major               | 36-bit           |
| RGB565        | 32/64/32/—                | 32/64/32/—             | None                | 18-bit packed    |
| RGBA8888      | 32/64/32/4                | 256/256/256/256        | Massive             | 36-bit           |
| R8            | 32/64/32/—                | 256/256/256/—          | Major               | 36-bit           |

The "BC1 levels" column for UQ1.8 reflects the approximately 86 distinct R5-derived UQ1.8 values achievable after 8-bit interpolation between two 5-bit endpoints.
The actual number of representable values depends on the specific endpoint pair.

#### Impact on bilinear filtering

Bilinear filtering interpolates between 4 texels in UQ1.8 space.
The filtering itself is identical regardless of cache format — the DSP multiply precision is the same.
The difference is in the starting values: more distinct UQ1.8 levels means the bilinear output has finer gradations.
For BC3 alpha, the difference is dramatic: bilinear filtering over 4 levels (A2) produces only 4+3=7 possible outputs, while filtering over 256 levels (UQ1.8) produces smooth gradients.

### 3. Four-bank interleaving with wrap modes

#### Normal operation (no wrap boundary)

The 4-bank interleaving guarantees that any 2x2 bilinear quad reads exactly one texel from each bank.
Bank assignment within a 4x4 block: `bank = {local_y[0], local_x[0]}`.
A 2x2 quad at `(x, y)` always spans parities `(even, even)`, `(odd, even)`, `(even, odd)`, `(odd, odd)` — all different banks.

#### Cross-block bilinear (addressed in INT-032)

When the bilinear quad straddles a 4x4 block boundary (e.g., the texel at local x=3 needs a neighbor at local x=0 in the next block), both blocks must be resident in the cache.
The pixel pipeline must perform two cache lookups (one per block) and assemble the 4 texels.
This is an existing design requirement documented in INT-032 and is independent of the 18/36-bit format choice.

#### Mirroring at texture edges

When texture mirroring causes two bilinear taps to map to the same wrapped texel coordinate, the taps have different raw (pre-wrap) coordinates but identical post-wrap coordinates.
The gs-twin handles this correctly in `wrap_bilinear()` (lines 425–429) because each tap is wrapped independently, and the bilinear weights still produce the mathematically correct result (weighted average where some taps are duplicates).

In the RTL, the cache lookup uses the wrapped coordinates.
If two taps produce the same wrapped block address and local offset, they would be in the same bank — but the cache reads one entry per bank at a fixed address, so there is no bank conflict.
The bilinear filter would receive a valid texel from the correct bank and a "don't care" value from the other bank, but the weight for the mirrored tap would select the correct value.

**Conclusion:** The 4-bank scheme is correct with mirroring.
The key is that the bilinear address generation and weight computation (in the pixel pipeline, not the cache) must correctly handle the wrapped coordinates.
No hardware changes needed.

#### Clamping at texture edges

When `ClampToEdge` clamps two adjacent taps to the same edge texel, the situation is identical to mirroring: two taps share a coordinate, weights handle it correctly.
The bilinear result converges to the edge texel value as expected.

### 4. Texture prefetch feasibility

#### Rasterizer traversal pattern

The rasterizer walks the triangle bounding box in 4x4 tile order (ARCHITECTURE.md line 62), scanning within each tile left-to-right, top-to-bottom.
This means:
- Adjacent pixels within a tile have very similar UV coordinates (differing by `dU/dx`, `dV/dx`)
- Adjacent tiles have UV coordinates offset by `4 * dU/dx` or `4 * dV/dy`
- Texture block boundaries are crossed at predictable intervals

#### Prefetch strategy

**Simple next-block prefetch:** When sampling texel at `(u, v)`, compute `(u + 4*dU/dx, v)` (next tile's approximate U coordinate).
If this maps to a different cache block, issue a background fill while the current sample completes.

**Benefits:**
- Hides cache fill latency (11–39 cycles depending on format) during sampling
- Most effective for textures with UV slopes that cross block boundaries within a tile row
- PDPW16KD's independent read/write ports enable concurrent fill and sample without port contention

**Hardware cost:**
- Second tag comparison: ~100 LUTs (24-bit tag compare, 4-way)
- Prefetch address generation: ~100–150 LUTs (block coordinate + SDRAM address computation)
- Prefetch state register: ~50 LUTs (track pending prefetch, avoid redundant requests)
- **Total: ~250–300 LUTs**

**Risks and mitigations:**
- Wasted SDRAM bandwidth on misprediction: mitigated by only prefetching when the predicted block differs from the current one (no speculative fills for same-block access)
- Increased arbiter contention: texture port is lowest priority (port 3 in UNIT-007), so prefetch requests yield to higher-priority traffic
- Prefetch may evict a still-useful cache line: mitigated by pseudo-LRU eviction policy, which prefers the least-recently-used way

**Recommendation:** Prefetch is a viable optimization but not essential for initial implementation.
The cache's documented 90%+ hit rate for typical textures means prefetch primarily helps with large, non-repeating textures where misses are more frequent.
The PDPW16KD choice for the switchable cache format already enables prefetch as a future enhancement without architectural changes.

### 5. BC decompression without DSP — already achieved

#### Current RTL analysis

The existing BC decoder modules use Verilog `/` and `*` operators for interpolation:

**BC1 (`texture_bc1.sv` lines 72–84):**
```
interp13_r = ({2'b0, c0_r} + {2'b0, c0_r} + {2'b0, c1_r} + 7'd1) / 7'd3
```
The "multiply by 2" is implemented as addition (`c0 + c0`).
The division by 3 is a constant divisor that Yosys synthesizes as combinational LUT logic, not a DSP multiply.

**BC3/BC4 (`texture_bc3.sv` lines 61–66, `texture_bc4.sv` lines 54–59):**
```
alpha_palette[2] = 8'((({2'b0, alpha0} * 10'd6) + ({2'b0, alpha1} * 10'd1) + 10'd3) / 10'd7)
```
The multiply by small constants (1–6) and division by 7 are synthesized to LUT logic when using the `-nodsp` flag in `synth_ecp5`.

**Conclusion:** BC decompression already consumes zero MULT18X18D blocks in the current design.

#### Explicit shift+add optimization

While the Verilog `/` operator works, replacing it with explicit reciprocal-multiply formulas gives the synthesizer more optimization headroom and produces deterministic LUT counts:

**Division by 3** (for BC1 color interpolation, inputs 0..94 for R5/B5, 0..190 for G6):
```
x / 3 = (x * 171 + 256) >> 9
```
Where `171 = 128 + 32 + 8 + 2 + 1`, computed as `(x<<7) + (x<<5) + (x<<3) + (x<<1) + x` — 4 additions.
Exact for all inputs in range 0..190.

**Division by 5** (for BC3/BC4 6-entry mode, inputs 0..1022):
```
x / 5 = (x * 205 + 512) >> 10
```
Where `205 = 128 + 64 + 8 + 4 + 1`, computed as `(x<<7) + (x<<6) + (x<<3) + (x<<2) + x` — 4 additions.

**Division by 7** (for BC3/BC4 8-entry mode, inputs 0..1533):
```
x / 7 = (x * 147 + 512) >> 10
```
Where `147 = 128 + 16 + 2 + 1`, computed as `(x<<7) + (x<<4) + (x<<1) + x` — 3 additions.

**Multiply by small constants** (for BC3/BC4 weighted blends):

| Weight | Implementation        | Adds |
| ------ | --------------------- | ---- |
| *1     | `x`                   | 0    |
| *2     | `x << 1`              | 0    |
| *3     | `(x << 1) + x`        | 1    |
| *4     | `x << 2`              | 0    |
| *5     | `(x << 2) + x`        | 1    |
| *6     | `(x << 2) + (x << 1)` | 1    |

Total per palette entry (BC3/BC4, 8-entry mode): 1 add (weight multiply) + 1 add (weighted sum) + 3 adds (÷7) = ~5 adders.
For all 8 palette entries: ~40 adders total — well within the LUT budget.

**Recommendation:** Replace Verilog `/` with explicit reciprocal-multiply formulas in the RTL for deterministic resource usage.
This is a minor optimization since the current approach already avoids DSP, but it removes the synthesizer's freedom to produce suboptimal circuits for constant division.

### 6. Additional finding: PDPW16KD Yosys flow constraint

The ECP5 skill documents an important constraint (pitfall #2): "PDPW16KD write port is always 36 bits in the Yosys flow."
This is actually favorable for the switchable cache design: the write port is always 36 bits wide, which accommodates both UQ1.8 (native 36-bit) and packed RGBA5652 (2x18 bits in 36).
The read port can be configured at 9, 18, or 36 bits; for the switchable mode, configuring it at 36 bits and selecting 18-bit halves in logic is the simplest approach.

## Conclusions

### Answers to scoping questions

**Q1: Is switchable 18/36-bit cache feasible?**
Yes.
PDPW16KD in 512x36 mode with 4 depth-cascaded blocks per bank uses the same 16 EBR per sampler as the current design.
The 36-bit mode halves cache capacity (8,192 vs 16,384 texels) but preserves up to 8x more precision per channel.
The 18-bit packed mode maintains current capacity.
A per-sampler config bit selects the mode.
*(Superseded: the cache now operates exclusively in UQ1.8 (36-bit) mode; the switchable mode and CACHE_MODE register bit were not implemented. See DD-040.)*

**Q2: Does UQ1.8 storage improve quality?**
Yes, significantly for most formats.
The biggest wins are BC3/BC4 alpha (256 vs 4 levels) and RGBA8888 (256 vs 32 levels per color channel).
BC1 color interpolation also benefits from performing the blend in 8-bit rather than 5/6/5-bit space.
RGB565 sees no improvement from UQ1.8 storage, but uses UQ1.8 uniformly since the switchable mode was not implemented.

**Q3: Does mirroring cause bank conflicts?**
No.
The 4-bank read scheme reads one entry from each bank at the same address.
Mirrored/clamped taps that alias to the same coordinate produce correct bilinear results via the weight computation, with no bank conflict.
Cross-block bilinear (where taps span two 4x4 blocks) requires two cache lookups regardless of wrap mode — this is an existing design constraint.

**Q4: Is prefetch worthwhile?**
Feasible (~250–300 LUTs) but not essential for initial implementation.
The rasterizer's tile-order traversal provides predictable spatial locality.
PDPW16KD's independent read/write ports enable future prefetch without architectural changes.
Recommended as a post-initial-implementation optimization.

**Q5: Can BC decompression avoid DSP?**
Yes — it already does.
The current RTL's Verilog `/` and `*` operators for small constants are synthesized to LUT logic, consuming zero MULT18X18D blocks.
Explicit shift+add reciprocal-multiply formulas (`÷3 = *171>>9`, `÷5 = *205>>10`, `÷7 = *147>>10`) can replace the Verilog `/` for more predictable resource usage.

### What remains uncertain

- **Exact LUT cost of switchable mode:** The PDPW16KD depth-cascade decode and 18/36-bit read mux add logic, but the amount is estimated (~50–100 LUTs). Synthesis will determine the actual cost.
- **Cache hit rate impact of halved capacity:** The 8,192-texel cache (36-bit mode) covers approximately a 90x90 texture area. For larger textures with non-repeating access patterns, the reduced capacity may increase miss rate. Profiling with representative workloads would quantify this.
- **Cross-block bilinear implementation:** The RTL's handling of bilinear quads that span two 4x4 blocks needs detailed design (multiple cache lookups, texel assembly). This is independent of the format choice but affects the texture sampling pipeline latency.

## Recommendations

*Note: Recommendations 1–3 and 6 were acted upon, but the switchable dual-mode aspect was superseded in favor of UQ1.8-only operation (DD-040 superseded 2026-03-15).
The cache uses PDPW16KD 512x36 exclusively in UQ1.8 mode; no RGBA5652 path was implemented.*

1. **Adopt PDPW16KD 512x36 as the EBR primitive for texture cache banks.**
   This provides the independent read/write ports needed for future prefetch.
   *(Adopted; the cache uses PDPW16KD 512x36 exclusively in UQ1.8 mode.)*

2. **Implement UQ1.8 cache format for all texture formats.**
   The quality improvements are substantial, especially for alpha channels.
   *(Adopted; all formats use UQ1.8 unconditionally. The per-format 18-bit packed mode was not implemented.)*

3. **Update BC decoders to produce UQ1.8 output.**
   BC1/BC2/BC3 color interpolation should expand endpoints to 8-bit first, interpolate at 8-bit precision, then convert to UQ1.8.
   BC3/BC4 alpha interpolation already produces 8-bit results that can be directly stored as UQ1.8.

4. **Replace Verilog `/` operators in BC decoders with explicit shift+add reciprocal-multiply formulas.**
   This produces identical results with deterministic LUT usage and makes the zero-DSP guarantee explicit rather than relying on synthesizer behavior.

5. **Defer prefetch to post-initial-implementation.**
   The PDPW16KD choice preserves the option; implement after profiling cache miss rates on representative scenes.

6. **Implement the cache in gs-twin first,** following the project's established workflow (CLAUDE.md: "implement in gs-twin first, verify with golden image tests, then implement the RTL to match").
   *(The UQ1.8-only cache was implemented; the dual RGBA5652/UQ1.8 output paths from the original recommendation were not needed.)*
