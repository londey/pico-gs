# UNIT-024: Lighting Calculator

## Parent Area

7. Vertex Transformation (Pico Software)

## Purpose

Gouraud shading calculations

## Implements Requirements

- REQ-008.02 (Render Pipeline Execution) — parent area 8 (Scene Graph/ECS)
- REQ-007.02 (Render Mesh Patch) — parent area 7 (Vertex Transformation)
- REQ-014.02 (Static Mesh Directional Lighting) — area 14: Rendering Quality
- REQ-014 (Render Modes)
- REQ-007 (Vertex Transformation)

## Interfaces

### Provides

None

### Consumes

None

### Internal Interfaces

- **UNIT-021 (Core 1 Render Executor)**: Called from Core 1's RenderMeshPatch handler per vertex. Lighting parameters carried in the RenderMeshPatch command.
- **UNIT-020 (Core 0 Scene Manager)**: Lighting parameters (`DirectionalLight` array, `AmbientLight`) are defined in `scene::demos` and passed through `render_teapot()`.

## Design Description

### Inputs

- **`normal: Vec3`**: Eye-space unit normal vector for the vertex (output of `transform_normal()`).
- **`base_color: [u8; 4]`**: RGBA base surface color of the mesh (0-255 per channel).
- **`lights: &[DirectionalLight; 4]`**: Array of 4 directional lights, each with a unit `direction: Vec3` (toward the light) and `color: Vec3` (per-channel intensity, 0.0-1.0). Unused lights have `color = Vec3::ZERO`.
- **`ambient: &AmbientLight`**: Ambient light with `color: Vec3` (per-channel intensity, 0.0-1.0).

### Outputs

- **Returns `[u8; 4]`**: Lit vertex color as [R, G, B, A] with each channel clamped to 0-255. Alpha is passed through unchanged from `base_color[3]`.

### Internal State

- No persistent state; `compute_lighting()` is a pure function.
- Local accumulators `lit_r`, `lit_g`, `lit_b` (f32) accumulate light contributions before modulation.

### Algorithm / Behavior

1. Initialize per-channel light accumulators with ambient color: `lit_r = ambient.color.x`, etc.
2. For each of the 4 directional lights:
   a. Compute `n_dot_l = max(0, dot(normal, light.direction))` (Lambertian diffuse factor).
   b. Add `n_dot_l * light.color.{x,y,z}` to the respective accumulator.
3. Modulate by base color: `r = (lit_r * base_color[0] as f32) as u32`, clamped to 255.
4. Alpha channel passes through unchanged.
5. Return `[r, g, b, a]`.

This implements standard Gouraud shading: per-vertex lighting with Lambertian diffuse from multiple directional lights plus ambient. No specular component.

## Implementation

- `crates/pico-gs-core/src/render/lighting.rs`: `compute_lighting()` function

## Verification

- **Ambient-only test**: With all directional lights at zero intensity, output should equal `ambient.color * base_color` per channel.
- **Single light test**: With one directional light aligned with the normal (dot=1.0), verify output equals `(ambient + light_color) * base_color`.
- **Back-facing test**: With normal opposite to light direction (dot < 0), verify directional contribution is zero (clamped by `max(0, ...)`).
- **Clamp test**: With very bright lights, verify output channels saturate at 255 and do not wrap.
- **Alpha passthrough test**: Verify output alpha always equals `base_color[3]` regardless of lighting.

## Design Notes

**Note on quantized normals**: When mesh normals are stored as i16 1:15 fixed-point (per INT-031), the caller (Core 1 render executor) converts i16 → f32 by dividing by 32767.0 and normalizing before calling `compute_lighting()`.
This conversion happens at the call site; `compute_lighting()` always receives a Vec3 f32 normal.

Migrated from speckit module specification.
