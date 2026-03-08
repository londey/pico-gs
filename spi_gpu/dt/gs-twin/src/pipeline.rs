//! Graphics pipeline: integer-pixel rasterizer matching the RTL.
//!
//! The GPU accepts pre-transformed screen-space vertices via register
//! writes (Q12.4 coordinates, RGBA8888 colors).
//! The rasterizer converts these to fragments using edge functions on
//! integer pixel coordinates, matching the RTL's rasterizer.sv.

pub mod rasterize;
