# INT-010: GPU Register Map

**Moved to `registers/doc/int_010_gpu_register_map.md`** — managed outside syskit as part of the register interface.

## External Consumer

The host-side implementation of this interface (SPI register writes, texture upload sequencing, framebuffer flip) is provided by the pico-racer application repository (https://github.com/londey/pico-racer).
The Verilator C++ test harnesses in this repo drive register writes directly per this interface for GPU RTL verification.

## Referenced By

Full cross-references are maintained in `registers/doc/int_010_gpu_register_map.md`.
Key GPU requirement areas that depend on this interface:

- REQ-001.01 (Basic Host Communication) — Area 1: GPU SPI Controller
- REQ-001.02 (Memory Upload Interface) — Area 1: GPU SPI Controller
- REQ-001.04 (Command Buffer FIFO) — Area 1: GPU SPI Controller
- REQ-001.05 (Vertex Submission Protocol) — Area 1: GPU SPI Controller
- REQ-002.01 (Flat Shaded Triangle) — Area 2: Rasterizer
- REQ-002.02 (Gouraud Shaded Triangle) — Area 2: Rasterizer
- REQ-002.03 (Rasterization Algorithm) — Area 2: Rasterizer
- REQ-003.01 (Textured Triangle) — Area 3: Texture Samplers
- REQ-003.02 (Multi-Texture Rendering) — Area 3: Texture Samplers
- REQ-003.03 (Compressed Textures) — Area 3: Texture Samplers
- REQ-003.04 (Swizzle Patterns) — Area 3: Texture Samplers
- REQ-003.05 (UV Wrapping Modes) — Area 3: Texture Samplers
- REQ-003.06 (Texture Sampling) — Area 3: Texture Samplers
- REQ-003.07 (Texture Mipmapping) — Area 3: Texture Samplers
- REQ-003.08 (Texture Cache) — Area 3: Texture Samplers
- REQ-004.01 (Texture Blend Modes) — Area 4: Fragment Processor/Color Combiner
- REQ-004.02 (Extended Precision Fragment Processing) — Area 4: Fragment Processor/Color Combiner
- REQ-005.01 (Framebuffer Management) — Area 5: Blend/Frame Buffer Store
- REQ-005.02 (Depth Tested Triangle) — Area 5: Blend/Frame Buffer Store
- REQ-005.03 (Alpha Blending) — Area 5: Blend/Frame Buffer Store
- REQ-005.04 (Enhanced Z-Buffer) — Area 5: Blend/Frame Buffer Store
- REQ-005.05 (Triangle-Based Clearing) — Area 5: Blend/Frame Buffer Store
- REQ-005.06 (Framebuffer Format) — Area 5: Blend/Frame Buffer Store
- REQ-005.07 (Z-Buffer Operations) — Area 5: Blend/Frame Buffer Store
- REQ-005.08 (Clear Framebuffer) — Area 5: Blend/Frame Buffer Store
- REQ-005.09 (Double-Buffered Rendering) — Area 5: Blend/Frame Buffer Store
- REQ-005.10 (Ordered Dithering) — Area 5: Blend/Frame Buffer Store
- REQ-005 (Blend / Frame Buffer Store)
- REQ-006.01 (Display Output) — Area 6: Screen Scan Out
- REQ-006.02 (Display Output Timing) — Area 6: Screen Scan Out
- REQ-006.03 (Color Grading LUT) — Area 6: Screen Scan Out
- REQ-006 (Screen Scan Out)
- REQ-001 (GPU SPI Hardware)
- REQ-002 (Rasterizer)
- REQ-003 (Texture Samplers)
- REQ-011.01 (Performance Targets)
- REQ-011.02 (Resource Constraints)
- REQ-011.03 (Reliability Requirements)
