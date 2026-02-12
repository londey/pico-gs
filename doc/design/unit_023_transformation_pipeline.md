# UNIT-023: Transformation Pipeline

## Purpose

MVP matrix transforms

## Implements Requirements

- REQ-102 (Unknown)
- REQ-115 (Render Mesh Patch)
- REQ-104 (Matrix Transformation Pipeline)

## Interfaces

### Provides

None

### Consumes

None

### Internal Interfaces

- **UNIT-020 (Core 0 Scene Manager)**: Called from `main.rs` to build projection (`perspective()`), view (`look_at()`), and model (`rotate_y()`) matrices.
- **UNIT-022 (GPU Driver Layer)**: Uses `gpu::registers::SCREEN_WIDTH` (640) and `SCREEN_HEIGHT` (480) for viewport mapping.
- **`render::mesh`**: Called from `render_teapot()` for per-vertex transform (`transform_vertex()`), normal transform (`transform_normal()`), and back-face culling (`is_front_facing()`).

## Design Description

### Inputs

- **`transform_vertex(position, mvp)`**: Object-space `Vec3` position and `&Mat4` MVP matrix.
- **`transform_normal(normal, mv)`**: Object-space `Vec3` normal and `&Mat4` model-view matrix.
- **`is_front_facing(v0, v1, v2)`**: Three `&ScreenVertex` references in screen space.
- **`perspective(fov_y, aspect, near, far)`**: FOV in radians, aspect ratio, near/far clip planes.
- **`look_at(eye, target, up)`**: Camera position, look-at target, and up vector as `Vec3`.
- **`rotate_y(angle)`**: Rotation angle in radians.

### Outputs

- **`transform_vertex()` returns `ScreenVertex`**: `x` (0..639), `y` (0..479) in pixel coordinates; `z` (0.0..1.0) normalized depth; `w` is clip-space W for perspective-correct interpolation.
- **`transform_normal()` returns `Vec3`**: Renormalized eye-space normal vector.
- **`is_front_facing()` returns `bool`**: `true` if the triangle's screen-space winding is counter-clockwise (front-facing).
- **Matrix builders return `Mat4`**: `perspective()`, `look_at()`, `rotate_y()` each return a `glam::Mat4`.

### Internal State

- **`ScreenVertex`** struct: `x: f32`, `y: f32`, `z: f32`, `w: f32`. Intermediate representation between world-space transform and GPU vertex packing.
- No persistent state; all functions are stateless/pure.

### Algorithm / Behavior

1. **`transform_vertex()`**:
   a. Multiply position by MVP matrix to get clip-space `Vec4`.
   b. Perspective divide: compute `inv_w = 1/w` (guarded against near-zero W), derive NDC coordinates `(x, y, z) * inv_w`.
   c. Viewport transform: map NDC `[-1,+1]` to screen pixels. X: `(ndc_x + 1) * 0.5 * 639`. Y: `(1 - ndc_y) * 0.5 * 479` (Y-axis flipped). Z: `(ndc_z + 1) * 0.5`, clamped to [0, 1].
   d. Return `ScreenVertex { x, y, z, w }` where `w` is the original clip-space W.
2. **`transform_normal()`**: Multiply normal (as `Vec4` with w=0) by the model-view matrix, extract xyz, normalize. This is correct for uniform-scale MV matrices.
3. **`is_front_facing()`**: Compute 2D cross product of screen-space edge vectors `(v1-v0)` and `(v2-v0)`. Positive cross product indicates counter-clockwise winding (front-facing).
4. **Matrix builders**: Delegate to `glam` library functions: `Mat4::perspective_rh()`, `Mat4::look_at_rh()`, `Mat4::from_rotation_y()`.

## Implementation

- `crates/pico-gs-core/src/render/transform.rs`: All transform functions and `ScreenVertex` type

## Verification

- **Vertex transform test**: Verify a known object-space point transforms to the expected screen-space pixel coordinates through a known MVP matrix.
- **Normal transform test**: Verify normals remain unit-length after transformation and point in expected directions.
- **Back-face culling test**: Verify CCW-wound triangles return `true` and CW-wound triangles return `false`.
- **Viewport mapping test**: Verify NDC corners (-1,-1), (1,1) map to screen corners (0,479), (639,0) respectively.
- **Edge case test**: Verify near-zero W values in perspective divide do not produce NaN or infinity.

## Design Notes

Migrated from speckit module specification.
