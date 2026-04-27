# UNIT-011.01: UV Coordinate Processing

## Purpose

Applies wrap mode to incoming Q4.12 UV coordinates, extracts the sub-texel quadrant from the wrapped low bits, and outputs half-resolution index-cache addresses to UNIT-011.03 (Index Cache).
The quadrant bits select which of the four palette colors (NW/NE/SW/SE) within a 2×2 apparent-texel tile is returned for the fragment.

## Implements Requirements

- REQ-003.05 (UV Wrapping Modes) — implements REPEAT, CLAMP, and MIRROR modes per TEXn_CFG.U_WRAP / V_WRAP

## Interfaces

### Provides

(none — internal to UNIT-011)

### Consumes

- INT-010 (GPU Register Map) — TEXn_CFG.U_WRAP, TEXn_CFG.V_WRAP fields

### Internal Interfaces

- Receives Q4.12 UV coordinates (UV0 or UV1) from the UNIT-006 fragment bus
- Outputs half-resolution index-cache address `(u_idx, v_idx)` to UNIT-011.03
- Outputs `quadrant[1:0] = {v_wrapped[0], u_wrapped[0]}` to UNIT-011.06

## Design Description

### Inputs

- `uv_q412[15:0]`: Q4.12 signed fixed-point UV coordinate (16-bit; sign at [15], integer at [14:12], fractional at [11:0]).
  Perspective correction is performed upstream by UNIT-005.05; this unit receives true U, V values.
- `tex_u_wrap[1:0]`, `tex_v_wrap[1:0]`: wrap mode from TEXn_CFG (REPEAT=0, CLAMP=1, MIRROR=2)
- `tex_width_log2[3:0]`, `tex_height_log2[3:0]`: apparent texture dimensions from TEXn_CFG

### Outputs

- `u_idx[N-2:0]`, `v_idx[N-2:0]`: half-resolution index-cache coordinates after wrap/clamp/mirror; width is `tex_width_log2 − 1` and `tex_height_log2 − 1` respectively
- `quadrant[1:0]`: sub-texel quadrant `{v_wrapped[0], u_wrapped[0]}` — selects NW (00), NE (10), SW (01), or SE (11) palette entry

### Algorithm / Behavior

**UV Coordinate Extraction:**

The Q4.12 UV value encodes the texture coordinate as a signed fixed-point number.
The integer portion `uv[14:12]` selects the apparent texel column/row.
The sign bit `uv[15]` indicates negative coordinates, used by wrap/mirror logic.

**Wrap Mode Application (applied independently to U and V on apparent coordinates):**

Wrap is applied to the full apparent integer texel coordinate before the quadrant split.
`tex_size` is the apparent texture width (or height) = `1 << tex_width_log2` (or `tex_height_log2`).

- **REPEAT:** Mask to texture size − 1: `texel_int = uv_int & (tex_size − 1)`.
  Two's-complement integer bits wrap correctly using the same AND mask.
- **CLAMP:** Saturate: `texel_int = max(0, min(uv_int, tex_size − 1))`.
- **MIRROR:** Reflect at each integer boundary.
  Even integer parts use the apparent fractional/integer coordinate directly; odd integer parts mirror by subtracting: `(tex_size − 1) − uv_int_masked`.
  The final coordinate is masked to `tex_size − 1` after reflection.
  For MIRROR wrap with INDEXED8_2X2, the quadrant split naturally swaps NE↔NW (when u is mirrored) and SE↔SW (when v is mirrored), so mirrored tiles exhibit correct left-right / top-bottom symmetry without additional logic.

**Quadrant Extraction:**

After wrap mode is applied, the low bit of each apparent coordinate becomes the quadrant selector:

```text
quadrant[1:0] = {v_wrapped[0], u_wrapped[0]}
```

This selects the palette entry for the 2×2 apparent-texel tile:

```text
quadrant = 2'b00  →  NW (u_wrapped even,  v_wrapped even)
quadrant = 2'b10  →  NE (u_wrapped odd,   v_wrapped even)
quadrant = 2'b01  →  SW (u_wrapped even,  v_wrapped odd)
quadrant = 2'b11  →  SE (u_wrapped odd,   v_wrapped odd)
```

**Half-Resolution Address Computation:**

The half-resolution index-cache address is derived by right-shifting the wrapped apparent coordinate by 1:

```text
u_idx = u_wrapped >> 1
v_idx = v_wrapped >> 1
```

These are the coordinates in the INDEXED8_2X2 index array (INT-014), where each index byte covers a 2×2 apparent-texel tile.

## Implementation

- `rtl/components/texture/detail/uv-coord/src/texture_uv_coord.sv`: UV coordinate wrapping, quadrant extraction, and half-resolution address output
- `twin/components/texture/detail/uv-coord/src/lib.rs`: `gs-tex-uv-coord` digital twin — `UvCoord::process`, `compute_quadrant`, REPEAT/CLAMP/MIRROR wrap modes
- `twin/components/texture/detail/uv-coord/src/bin/gen_uv_coord_vectors.rs`: stimulus and expected-output hex vector generator for the Verilator testbench

The authoritative algorithmic design is the gs-texture twin crate (`twin/components/texture/detail/uv-coord/`).
RTL behavior must be bit-identical to the twin at the quadrant and index-coordinate level.

## Design Notes

**No division required:** All wrap, clamp, and mirror operations are implemented using bit masking and saturation.
Power-of-two texture dimensions (required by INT-014) mean modulo wrap reduces to a single AND mask.

**Minimum texture size:** `WIDTH_LOG2 ≥ 1` and `HEIGHT_LOG2 ≥ 1` are enforced by INT-014.
This guarantees that `u_idx` and `v_idx` are at least 1 bit wide and that the quadrant split always yields a valid half-resolution address.

**No mip level output:** Mipmapping is not supported in the INDEXED8_2X2 architecture.
`frag_lod` from the rasterizer is not consumed by this unit.
