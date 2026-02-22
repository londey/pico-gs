//! Demo texture data stored in flash as const arrays.

use crate::render::commands::{TextureInfo, TextureSource};

/// 64x64 checkerboard texture (RGBA8888, 4096 pixels = 4096 u32 words).
/// Alternating 8x8 blocks of white and dark gray.
pub const CHECKERBOARD_64: Texture = Texture {
    width: 64,
    height: 64,
    width_log2: 6,
    height_log2: 6,
    data: &CHECKERBOARD_64_DATA,
};

/// Texture metadata.
pub struct Texture {
    pub width: u16,
    pub height: u16,
    pub width_log2: u8,
    pub height_log2: u8,
    pub data: &'static [u64],
}

/// Global texture table for cross-core texture ID lookup.
pub const TEXTURE_TABLE: &[&Texture] = &[&CHECKERBOARD_64];

/// Texture ID constants.
pub const TEX_ID_CHECKERBOARD: u8 = 0;

/// Adapter implementing the TextureSource trait using the static texture table.
pub struct StaticTextureSource;

impl TextureSource for StaticTextureSource {
    fn get_texture(&self, id: u8) -> Option<TextureInfo<'_>> {
        let tex_id = id as usize;
        if tex_id >= TEXTURE_TABLE.len() {
            return None;
        }
        let tex = TEXTURE_TABLE[tex_id];
        Some(TextureInfo {
            data: tex.data,
            width: tex.width,
            height: tex.height,
            width_log2: tex.width_log2,
            height_log2: tex.height_log2,
        })
    }
}

/// Generate the 64x64 checkerboard at compile time.
/// Two adjacent RGBA8888 pixels are packed per 64-bit dword (low pixel in [31:0]).
const CHECKERBOARD_64_DATA: [u64; 64 * 64 / 2] = {
    let mut data = [0u64; 64 * 64 / 2];
    let mut y = 0usize;
    while y < 64 {
        let mut x = 0usize;
        while x < 64 {
            // 8x8 block checkerboard pattern.
            let block_x0 = x / 8;
            let block_x1 = (x + 1) / 8;
            let block_y = y / 8;
            let c0: u32 = if (block_x0 + block_y) % 2 == 0 {
                0xFF_FF_FF_FF // White, opaque (RGBA8888)
            } else {
                0xFF_40_40_40 // Dark gray, opaque
            };
            let c1: u32 = if (block_x1 + block_y) % 2 == 0 {
                0xFF_FF_FF_FF
            } else {
                0xFF_40_40_40
            };
            data[(y * 64 + x) / 2] = (c0 as u64) | ((c1 as u64) << 32);
            x += 2;
        }
        y += 1;
    }
    data
};
