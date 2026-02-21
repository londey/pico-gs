# N64-Style Color Combiner Suitability for Lightmapping in pico-gs

## Technical Report: Rendering Technique Analysis

---

## 1. What is Lightmapping?

Lightmapping is a pre-computed lighting technique pioneered by John Carmack in Quake (1996).
Rather than computing lighting in real time, the contribution of all static light sources is computed offline (via radiosity or ray casting) and stored as a low-resolution texture called a **lightmap**.
At render time, the base diffuse texture is modulated (multiplied) by the lightmap to produce the final lit appearance.

**Key characteristics:**

- The lightmap is typically much lower resolution than the diffuse texture.
  In original Quake, the lightmap grid had one lumel (lighting texel) per 16x16 diffuse texels -- a resolution of approximately two feet in Quake's coordinate system.
- Each surface in the world gets a unique region of the lightmap atlas, requiring a second set of UV coordinates distinct from the tiling diffuse UVs.
- The fundamental equation is: `final_color = diffuse_texture(UV0) * lightmap_texture(UV1)`
- Bilinear filtering on the lightmap is essential to produce smooth lighting transitions despite its low resolution.

**Historical usage:**

- **Quake (1996):** Monochrome lightmaps, software-rendered surface cache that composited diffuse + lightmap into a temporary surface.
- **Quake II (1997):** Colored lightmaps (RGB), multi-texture hardware path on Voodoo2.
- **Half-Life (1998) / Quake III (1999):** Colored 128x128 lightmap pages stored in BSP files, hardware multi-texturing on consumer GPUs.
- **Half-Life 2 (2004):** Extended to Radiosity Normal Mapping with 3 directional lightmaps per surface for normal-map interaction.

The technique remains widely used in modern engines for static global illumination because it captures inter-surface light bounces (radiosity) that are prohibitively expensive to compute in real time.

---

## 2. Can the N64 Color Combiner Do Lightmapping?

### 2.1 The (A-B)*C+D Equation

The N64 RDP's color combiner uses the equation `(A - B) * C + D` where A, B, C, and D are selectable from a set of input sources.
This equation is evaluated independently for RGB and Alpha channels.
The pico-gs GPU adopts this same equation verbatim, as defined in the `CC_MODE` register at address `0x18` (`/workspaces/pico-gs/registers/rdl/gpu_regs.rdl`, line 176-188).

### 2.2 Basic Lightmap Setup: TEX0 * TEX1

The simplest lightmap operation is `diffuse * lightmap`.
This maps directly to the combiner equation:

```
A = TEX_COLOR0    (diffuse texture)
B = ZERO           (0x7)
C = TEX_COLOR1    (lightmap texture)
D = ZERO           (0x7)

result = (TEX_COLOR0 - 0) * TEX_COLOR1 + 0
       = TEX_COLOR0 * TEX_COLOR1
```

In pico-gs register terms, the CC_MODE write value would be:

```
CC_A_SOURCE = 0x0 (TEX_COLOR0)     bits [19:16]
CC_B_SOURCE = 0x7 (ZERO)           bits [23:20]
CC_C_SOURCE = 0x1 (TEX_COLOR1)     bits [27:24]
CC_D_SOURCE = 0x7 (ZERO)           bits [31:28]
```

### 2.3 Pico-gs vs. N64: Single-Cycle Advantage

On the actual N64 RDP, multi-texturing with TEXEL0 and TEXEL1 requires **2-cycle mode**.
In 1-cycle mode, the RDP can only sample one texture per pixel; accessing TEXEL1 in cycle 1 actually reads TEXEL0 from the next pixel, which is a known quirk that produces subtly incorrect results.
To properly use both texture units, the N64 must run in 2-cycle mode, which halves pixel throughput.

The pico-gs GPU does **not** have this limitation.
Its architecture samples both TEX0 and TEX1 independently in a single pipeline pass.
Both texture colors are provided simultaneously to the color combiner without requiring multi-cycle operation.
This means lightmapping comes at zero throughput cost compared to single-textured rendering -- a significant advantage over the original N64 RDP.

### 2.4 Enhanced Lightmap Formula with Vertex Color

A common extension adds per-vertex dynamic point light contributions to the diffuse texture *before* modulation by the lightmap:

```
final_color = (VERTEX_COLOR + TEX_COLOR0) * TEX_COLOR1
```

The single `(A-B)*C+D` equation cannot directly express this because it lacks a pre-addition step before the multiply.
There are two approaches to handle this:

**Approach A -- Two-pass rendering:**
1. First pass: render with `A=TEX0, B=ZERO, C=TEX1, D=ZERO` (diffuse * lightmap)
2. Second pass: additive blend with `A=VER0, B=ZERO, C=TEX1, D=ZERO` (vertex_color * lightmap)

**Approach B -- Approximate with combiner:**
```
A = TEX_COLOR0
B = ZERO
C = TEX_COLOR1
D = VER_COLOR0

result = TEX_COLOR0 * TEX_COLOR1 + VER_COLOR0
```
This gives `diffuse * lightmap + vertex_color`, which is close but not identical to `(diffuse + vertex_color) * lightmap`.
The difference is whether the vertex color contribution is attenuated by the lightmap or not.
For small vertex color values (typical for fill lights), the visual difference is acceptable.

**Approach C -- Bake vertex contribution into the diffuse texture or lightmap** at the asset pipeline level, avoiding the runtime composition entirely.

### 2.5 Did N64 Games Use Lightmapping?

N64 games generally did **not** use traditional PC-style lightmapping, primarily due to ROM cartridge storage constraints.
Lightmaps consume significant memory (each surface needs unique lightmap texels), and N64 cartridges had limited capacity (8-64 MB).

- **Quake 64** (Midway, 1998) used colored lighting as its primary visual feature, with pre-rendered lightmaps on world surfaces.
  It was one of the few N64 titles to employ this technique, compensating for reduced level geometry by emphasizing colored lighting effects.
- **GoldenEye 007** (Rare, 1997) used constant-level lighting for most environments rather than lightmaps, as the developers determined lightmaps were "an abhorrent waste of space" given the cartridge constraints.
- Most N64 games relied on vertex-colored Gouraud shading for lighting, or pre-baked lighting into the diffuse textures themselves.

The pico-gs project, with 32 MiB of SDRAM for textures, does not face the same storage constraints as N64 cartridges, making lightmapping far more practical.

---

## 3. Lightmap UV Coordinates

### 3.1 Dual UV Support

Lightmapping requires two independent UV coordinate sets per vertex:
- **UV0**: Tiling diffuse texture coordinates (may repeat across the surface)
- **UV1**: Unique lightmap coordinates (non-overlapping, each surface maps to a unique lightmap region)

The pico-gs register map provides this directly via the `UV0_UV1` register at address `0x01` (`/workspaces/pico-gs/registers/rdl/gpu_regs.rdl`, lines 99-107):

```
[63:48]   UV1_VQ = V1/W   (lightmap V, S3.12 fixed-point)
[47:32]   UV1_UQ = U1/W   (lightmap U, S3.12 fixed-point)
[31:16]   UV0_VQ = V0/W   (diffuse V, S3.12 fixed-point)
[15:0]    UV0_UQ = U0/W   (diffuse U, S3.12 fixed-point)
```

Both UV sets are packed into a single 64-bit register write, meaning a lightmapped triangle submission costs the same SPI bandwidth as any dual-textured triangle -- no extra register writes needed.

### 3.2 UV Precision Analysis

The UV coordinates use S3.12 signed fixed-point format:

- **Range:** -8.0 to approximately +7.9998
- **Resolution:** 1/4096 per texel coordinate

For a lightmap texture of 256x256, the UV resolution of 1/4096 gives approximately 16 sub-texel positions per lightmap texel, which provides adequate precision for bilinear filtering.
For a 64x64 lightmap, precision improves to approximately 64 sub-texel positions per texel.

For diffuse textures using tiling/repeating UVs, the +/-8.0 range allows up to 8 repetitions of the texture across a surface, which is generally sufficient for architectural surfaces.

### 3.3 Perspective Correction

Both UV0 and UV1 are stored as `U/W` and `V/W` (pre-divided by the homogeneous W coordinate), with the reciprocal `1/W` (Q) stored in the VERTEX register.
The GPU reconstructs perspective-correct UVs per pixel: `U = (U/W) / (1/W)`.
This ensures the lightmap does not exhibit the characteristic affine-warping artifacts seen on PS1-era hardware.

---

## 4. Lightmap Memory and Quality Considerations

### 4.1 Memory Budget

Total SDRAM: 32 MiB = 33,554,432 bytes.
Used by framebuffers + Z-buffer: approximately 3,686,400 bytes (3.5 MiB).
Available for textures: approximately 29.5 MiB.

**Lightmap memory estimates** for a game level:

| Lightmap Size | Format | Bytes per Lightmap | 100 Surfaces | 500 Surfaces |
|---------------|--------|-------------------|--------------|--------------|
| 32x32 | RGB565 | 2,048 | 200 KB | 1,000 KB |
| 32x32 | BC1 | 512 | 50 KB | 250 KB |
| 64x64 | RGB565 | 8,192 | 800 KB | 4,000 KB |
| 64x64 | BC1 | 2,048 | 200 KB | 1,000 KB |
| 128x128 | RGB565 | 32,768 | 3.2 MB | 16 MB |

For a Quake-style level with ~200-500 lightmapped surfaces at 64x64 resolution per surface in BC1 format, the lightmap atlas would consume approximately 0.2-1.0 MB -- well within the 29.5 MB budget.

In practice, lightmaps are packed into atlases (e.g., several 256x256 or 512x512 atlas pages), and many small surfaces share a single atlas texture.
A reasonable allocation might be 2-4 MB for lightmap atlases, leaving 25+ MB for diffuse textures, character models, and other assets.

### 4.2 Lightmap Texture Format

The pico-gs supports these relevant formats (`/workspaces/pico-gs/registers/rdl/gpu_regs.rdl`, lines 42-50):

| Format | Bits/pixel | Suitability for Lightmaps |
|--------|-----------|--------------------------|
| **BC1** | 4 bpp | Good. 4:1 compression, RGB color, minimal quality loss for low-frequency lighting data. Lossy but lightmaps are smooth gradients that compress well. |
| **BC4** | 4 bpp | Grayscale only. Suitable for monochrome lightmaps (like original Quake). Single-channel with better quality than BC1 for grayscale. |
| **RGB565** | 16 bpp | Best quality for colored lightmaps. No compression artifacts. 4x memory cost vs BC1. |
| **R8** | 8 bpp | Grayscale lightmaps. 8-bit precision per lumel. 2x memory cost vs BC1, but no block artifacts. |
| **RGBA8888** | 32 bpp | Overkill for lightmaps (alpha channel unused). 8x memory cost vs BC1. |

**Recommendation:** Use **BC1** for colored lightmaps as the default.
Lightmaps contain smooth, low-frequency data that compresses extremely well in block compression formats.
For scenes requiring higher precision (e.g., subtle color gradients from colored lights), **RGB565** provides a good quality-to-memory tradeoff.
For monochrome lightmaps, **BC4** is the most memory-efficient choice.

### 4.3 Bilinear Filtering

Bilinear filtering on lightmaps is essential for smooth lighting transitions.
The pico-gs TEX1_CFG register provides a FILTER field (bits [3:2]) supporting NEAREST, BILINEAR, and TRILINEAR modes.
Setting TEX1's filter to BILINEAR ensures the lightmap is smoothly interpolated between lumels:

```
TEX1_CFG.FILTER = 0x1  (BILINEAR)
```

This is critical because lightmaps are inherently low-resolution.
Without bilinear filtering, lighting would appear blocky with visible lumel boundaries.
With filtering, the hardware smoothly interpolates between lumel values, producing visually convincing results even at aggressive compression ratios.

For lightmaps, TRILINEAR (mipmap blending) is generally unnecessary since lightmaps do not tile and are viewed at roughly a constant texel-to-pixel ratio.
Mipmapping could be used if lightmap LOD is desired for very distant surfaces, but BILINEAR is sufficient for most cases.

---

## 5. Advanced Lightmapping Techniques

### 5.1 Radiosity Normal Mapping (Half-Life 2 Style)

Half-Life 2's Radiosity Normal Mapping stores lighting pre-computed along three directional basis vectors.
Per pixel, the renderer samples three lightmaps and blends them based on the surface normal from a normal map:

```
lightmapColor = lightmap0 * dot(basis[0], normal)
              + lightmap1 * dot(basis[1], normal)
              + lightmap2 * dot(basis[2], normal)
```

This requires **three lightmap texture samples per pixel** plus dot products and additions.
With only two texture units, the pico-gs cannot perform this in a single pass.
It would require at minimum two passes (sample two lightmaps in pass 1, accumulate the third in pass 2), plus the normal map would need a third pass.
This technique is **not practical** on pico-gs without significant multi-pass overhead and is better left to shader-based GPUs.

### 5.2 Colored Lightmaps

Colored lightmaps (as used in Quake II, Quake III, and Half-Life) are straightforward.
The lightmap texture stores full RGB color data, and the `TEX0 * TEX1` modulation applies per-channel:

```
R_out = R_diffuse * R_lightmap
G_out = G_diffuse * G_lightmap
B_out = B_diffuse * B_lightmap
```

All pico-gs texture formats that store RGB data (BC1, RGB565, RGBA8888) support this directly.
No special combiner configuration is needed beyond the basic `TEX0 * TEX1` setup.

### 5.3 Dynamic Light Overlays

A common extension is adding dynamic light contributions (explosions, muzzle flashes, etc.) on top of the lightmapped result.
The combiner equation supports this:

```
A = TEX_COLOR0     (diffuse)
B = ZERO
C = TEX_COLOR1     (lightmap)
D = VER_COLOR0     (dynamic light contribution, computed per-vertex on host)

result = TEX_COLOR0 * TEX_COLOR1 + VER_COLOR0
       = (diffuse * lightmap) + dynamic_light
```

This gives `diffuse * lightmap + dynamic_vertex_color` in a single pass with no additional cost.

Note: the vertex color addition happens *after* the lightmap modulation, which is physically more correct for additive dynamic lights (the dynamic light is independent of the baked static lighting).

### 5.4 Lightmap + Environment Map

Environment mapping (for reflective surfaces) combined with lightmapping would require a third texture sample.
With two texture units, this requires multi-pass rendering:

1. **Pass 1:** Render `diffuse * lightmap` (TEX0=diffuse, TEX1=lightmap, CC: A=TEX0, B=0, C=TEX1, D=0)
2. **Pass 2:** Additive-blend environment map on top (TEX0=envmap, ALPHA_BLEND=ADD, CC: A=TEX0, B=0, C=MAT_COLOR0, D=0 where MAT_COLOR0 controls reflectivity)

This is a valid approach and was common on late-1990s hardware with similar constraints.

### 5.5 Fog + Lightmapping

Combining fog with lightmapping is a natural use case.
The combiner cannot express both `TEX0 * TEX1` and fog blending in a single equation evaluation.
However, there are options:

**Option A -- Two-pass:**
1. Pass 1: `diffuse * lightmap` written to framebuffer
2. Pass 2: Fog pass using framebuffer read-modify-write (alpha blend)

**Option B -- Use alpha channel for fog factor:**
Encode fog as vertex alpha, use alpha blending to blend toward fog color after the lightmap pass.
This is the most practical approach:
1. Render `diffuse * lightmap` as normal
2. Use ALPHA_BLEND mode with the fragment's vertex alpha to blend toward FOG_COLOR

This approach is how many fixed-function-era engines handled fog with lightmaps.

**Option C -- Use 2-cycle mode:**
With the proposed 2-cycle combiner:
1. Cycle 0: `TEX0 * TEX1` (diffuse * lightmap -> COMBINED)
2. Cycle 1: `(COMBINED - FOG_COLOR) * SHADE_ALPHA + FOG_COLOR` (fog blend)

This handles fog + lightmap in a single rendering pass with zero extra bandwidth, at no throughput penalty with pipelined 2-cycle mode.

---

## 6. Comparison with Gouraud Vertex Lighting

| Aspect | Gouraud Vertex Lighting | Lightmapping |
|--------|------------------------|--------------|
| **Spatial resolution** | One light sample per vertex; varies with mesh density. Low-poly meshes get blocky lighting. | One lumel per 16x16 (or finer) world units, independent of mesh complexity. Much higher detail. |
| **Global illumination** | No inter-surface bounces. Direct lighting only. | Pre-computed radiosity captures color bleeding, ambient occlusion, indirect illumination. |
| **Dynamic response** | Fully dynamic. Lights can move, appear, disappear in real time. | Static only. Cannot respond to moving lights or objects without re-baking. |
| **Host CPU cost** | Per-vertex lighting computation (N*dot products per vertex per light). With 4 lights and 5000 vertices: 20,000 dot products per frame. | Zero runtime cost for static lighting. Only UV coordinate transformation needed. |
| **Memory cost** | Zero additional memory (vertex colors are part of vertex data). | Additional texture memory for lightmap atlases (0.2-4 MB typical). |
| **SPI bandwidth** | Vertex color already in COLOR register; no extra writes. | Both UV sets packed in UV0_UV1; no extra writes either. |
| **Visual quality** | Smooth gradients but limited by vertex density. No shadow edges sharper than the mesh. | High-frequency shadows, soft penumbras, color bleeding, ambient occlusion -- all at lightmap resolution. |

**Hybrid approach (recommended):** Use lightmaps for static geometry (walls, floors, ceilings) to capture global illumination, and use Gouraud vertex lighting for dynamic/moving objects (characters, items, projectiles).
Per-vertex dynamic light contributions can be added to lightmapped surfaces via the `VER_COLOR0` input in the combiner's D slot:

```
result = TEX0 * TEX1 + VER_COLOR0
       = (diffuse * static_lightmap) + dynamic_fill_light
```

This gives the best of both worlds: rich static GI from lightmaps, plus dynamic light responsiveness from vertex colors, all in a single rendering pass.

---

## 7. Conclusion

### Is the N64-style combiner well-suited for lightmapping?

**Yes.** The `(A-B)*C+D` equation with the pico-gs input source selection is well-suited for lightmapping.
The basic lightmap operation `TEX0 * TEX1` maps trivially to `A=TEX0, B=ZERO, C=TEX1, D=ZERO`.
The addition of dynamic light contributions via `D=VER_COLOR0` provides a practical hybrid approach in a single pass.

### Key advantages of the pico-gs implementation over the original N64:

1. **No 2-cycle penalty.** The N64 requires 2-cycle mode (halving pixel throughput) for dual-texture operations.
   Pico-gs samples both textures in a single pipeline pass.
2. **Generous memory.** 32 MiB SDRAM vs. typical N64 cartridge constraints (8-64 MB shared with code and audio).
   Several megabytes can be comfortably allocated to lightmap atlases.
3. **Multiple texture formats.** BC1 and BC4 compressed formats make lightmaps very memory-efficient (512 bytes for a 32x32 colored lightmap in BC1), while RGB565 and R8 offer uncompressed alternatives.
4. **Bilinear filtering.** Per-texture-unit FILTER configuration ensures smooth lightmap interpolation.
5. **10.8 fixed-point precision.** The internal 18-bit per-channel arithmetic prevents banding artifacts in the multiply operation, which is important since lightmap values often span a wide range from deep shadow to bright light.

### Limitations and workarounds:

| Limitation | Impact | Workaround |
|-----------|--------|------------|
| Single combiner equation | Cannot express `(TEX0 + VER0) * TEX1` directly | Use `TEX0 * TEX1 + VER0` (add dynamic light after lightmap modulation) or multi-pass |
| Two texture units | Cannot do lightmap + envmap + diffuse in one pass | Multi-pass rendering for reflective lightmapped surfaces |
| No fog + lightmap in single equation (1-cycle) | Cannot combine `TEX0 * TEX1` with fog blend in one combiner eval | Use 2-cycle mode, or vertex alpha + alpha blending for fog |
| Radiosity Normal Mapping infeasible | Requires 3 lightmap samples + normal map | Stick with traditional flat lightmaps; accept that normal maps won't interact with lightmap lighting |
| Power-of-2 texture dimensions | Lightmap atlases must be power-of-2 (64, 128, 256, 512) | Pack lightmap charts into power-of-2 atlas pages with some wasted space |
| UV range +/-8.0 | Limits lightmap atlas UV range | Not a real issue -- lightmap UVs are typically in [0,1] range per surface |

---

## Sources

- [N64 Programming Manual Chapter 12.6: Color Combiner](http://n64devkit.square7.ch/pro-man/pro12/12-06.htm)
- [N64 Tutorial: Advanced Texture Mapping](https://ultra64.ca/files/documentation/online-manuals/man-v5-1/tutorial/graphics/9/9_3.htm)
- [The RDP as I understand it (Paris Oplopoios)](https://offtkp.github.io/RDP/)
- [What is Texel1 in combine mode? (EmuTalk)](https://www.emutalk.net/threads/what-is-texel1-in-combine-mode.5080/)
- [Quake (Nintendo 64 version) - Quake Wiki](https://quake.fandom.com/wiki/Quake_(Nintendo_64_version))
- [Quake Lightmaps - project log](https://jbush001.github.io/2015/06/11/quake-lightmaps.html)
- [Quake's Lighting Model: Surface Caching (Michael Abrash)](https://www.bluesnews.com/abrash/chap68.shtml)
- [Lightmap - Wikipedia](https://en.wikipedia.org/wiki/Lightmap)
- [Half-Life 2 / Valve Source Shading (GDC 2004)](https://cdn.fastly.steamstatic.com/apps/valve/2004/GDC2004_Half-Life2_Shading.pdf)
- [Radiosity Normal Map - Polycount Wiki](http://wiki.polycount.com/wiki/Radiosity_normal_map)
- [How was lighting handled in early 3D games? (GameDev.net)](https://www.gamedev.net/forums/topic/695748-how-was-lighting-handled-in-early-3d-games/)
- [Quake3World - Lightmap luxel density](https://www.quake3world.com/forum/viewtopic.php?f=10&t=51469)
- [N64 Developers News 1.1 - Multi-texture combine modes](https://ultra64.ca/files/documentation/online-manuals/man/developerNews/news-01.html)
- [Palette lighting tricks on the Nintendo 64](https://30fps.net/pages/palette-lighting-tricks-n64/)
