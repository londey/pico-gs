//! Parser for GPU test script `.hex` files.
//!
//! Parses register-write commands from annotated hex files shared between
//! the Verilator harness and the digital twin.
//!
//! # Format
//!
//! - `#` to end-of-line is a comment
//! - `_` within hex values is ignored (visual grouping)
//! - Data lines: `<2-hex addr> <16-hex data>`
//! - `## PHASE: <name>` delimits named phases
//! - `## FRAMEBUFFER: <width> <height>` declares output dimensions
//! - `## TEXTURE: <type> base=<hex> format=<fmt> width_log2=<n>`

use crate::reg::RegWrite;

/// A texture pre-load directive parsed from a `## TEXTURE:` line.
#[derive(Debug, Clone)]
pub struct TextureDirective {
    /// Texture type, e.g. `"checker_wb"`, `"checker_wg"`.
    pub tex_type: String,
    /// SDRAM word address for texture data.
    pub base_word: u32,
    /// Texture format, e.g. `"RGB565"`.
    pub format: String,
    /// Log2 of texture width (e.g. 4 for 16px).
    pub width_log2: u8,
}

/// A named phase containing a sequence of register writes.
#[derive(Debug, Clone)]
pub struct HexPhase {
    /// Phase name (default: `"main"`).
    pub name: String,
    /// Register write commands in this phase.
    pub commands: Vec<RegWrite>,
}

/// Complete parsed hex script.
#[derive(Debug, Clone)]
pub struct HexScript {
    /// Framebuffer width from `## FRAMEBUFFER:` directive.
    pub fb_width: u32,
    /// Framebuffer height from `## FRAMEBUFFER:` directive.
    pub fb_height: u32,
    /// Ordered list of phases.
    pub phases: Vec<HexPhase>,
    /// Texture pre-load directives.
    pub textures: Vec<TextureDirective>,
}

impl HexScript {
    /// Get all commands across all phases, flattened.
    pub fn all_commands(&self) -> Vec<RegWrite> {
        self.phases
            .iter()
            .flat_map(|p| p.commands.iter().cloned())
            .collect()
    }

    /// Get commands for a specific phase by name.
    pub fn phase_commands(&self, name: &str) -> Option<&[RegWrite]> {
        self.phases
            .iter()
            .find(|p| p.name == name)
            .map(|p| p.commands.as_slice())
    }
}

/// Strip `_` characters from a hex string.
fn strip_underscores(s: &str) -> String {
    s.chars().filter(|&c| c != '_').collect()
}

/// Parse a `## TEXTURE:` directive line.
fn parse_texture_directive(line: &str) -> Option<TextureDirective> {
    let content = line.strip_prefix("## TEXTURE:")?;
    let tokens: Vec<&str> = content.split_whitespace().collect();
    if tokens.is_empty() {
        return None;
    }

    let tex_type = tokens[0].to_string();
    let mut base_word: u32 = 0;
    let mut format = String::new();
    let mut width_log2: u8 = 0;

    for &token in &tokens[1..] {
        if let Some(val) = token.strip_prefix("base=") {
            let hex_str = val
                .strip_prefix("0x")
                .or_else(|| val.strip_prefix("0X"))
                .unwrap_or(val);
            base_word = u32::from_str_radix(&strip_underscores(hex_str), 16).unwrap_or(0);
        } else if let Some(val) = token.strip_prefix("format=") {
            format = val.to_string();
        } else if let Some(val) = token.strip_prefix("width_log2=") {
            width_log2 = val.parse().unwrap_or(0);
        }
    }

    Some(TextureDirective {
        tex_type,
        base_word,
        format,
        width_log2,
    })
}

/// Handle a `##` directive line, updating script/phase state.
fn handle_directive(
    line: &str,
    script: &mut HexScript,
    current_phase: &mut HexPhase,
    has_explicit_phase: &mut bool,
) {
    if let Some(name) = line.strip_prefix("## PHASE:") {
        if !current_phase.commands.is_empty() || *has_explicit_phase {
            let prev = std::mem::replace(
                current_phase,
                HexPhase {
                    name: String::new(),
                    commands: Vec::new(),
                },
            );
            script.phases.push(prev);
        }
        current_phase.name = name.trim().to_string();
        *has_explicit_phase = true;
    } else if let Some((w, h)) = parse_framebuffer_directive(line) {
        script.fb_width = w;
        script.fb_height = h;
    } else if let Some(td) = parse_texture_directive(line) {
        script.textures.push(td);
    }
}

/// Parse a `## FRAMEBUFFER:` directive, returning (width, height).
fn parse_framebuffer_directive(line: &str) -> Option<(u32, u32)> {
    let dims = line.strip_prefix("## FRAMEBUFFER:")?;
    let parts: Vec<&str> = dims.split_whitespace().collect();
    if parts.len() >= 2 {
        let w = parts[0].parse().unwrap_or(0);
        let h = parts[1].parse().unwrap_or(0);
        Some((w, h))
    } else {
        None
    }
}

/// Parse a single data line: `<addr_hex> <data_hex>`.
fn parse_data_line(line: &str, line_no: usize) -> Result<RegWrite, String> {
    let parts: Vec<&str> = line.split_whitespace().collect();
    if parts.len() < 2 {
        return Err(format!(
            "Line {}: expected '<addr> <data>', got '{}'",
            line_no + 1,
            line
        ));
    }
    let addr = u8::from_str_radix(&strip_underscores(parts[0]), 16)
        .map_err(|e| format!("Line {}: bad address '{}': {}", line_no + 1, parts[0], e))?;
    let data = u64::from_str_radix(&strip_underscores(parts[1]), 16)
        .map_err(|e| format!("Line {}: bad data '{}': {}", line_no + 1, parts[1], e))?;
    Ok(RegWrite {
        addr: addr & 0x7F,
        data,
    })
}

/// Parse a hex script from a string.
pub fn parse_hex_str(content: &str) -> Result<HexScript, String> {
    let mut script = HexScript {
        fb_width: 0,
        fb_height: 0,
        phases: Vec::new(),
        textures: Vec::new(),
    };

    let mut current_phase = HexPhase {
        name: "main".to_string(),
        commands: Vec::new(),
    };
    let mut has_explicit_phase = false;

    for (line_no, raw_line) in content.lines().enumerate() {
        let line = raw_line.trim_end();

        // Check for directives (## lines) before stripping comments
        if line.starts_with("##") {
            handle_directive(
                line,
                &mut script,
                &mut current_phase,
                &mut has_explicit_phase,
            );
            continue;
        }

        // Strip comments (# to end of line)
        let line = match line.find('#') {
            Some(pos) => &line[..pos],
            None => line,
        };

        let line = line.trim();
        if line.is_empty() {
            continue;
        }

        current_phase.commands.push(parse_data_line(line, line_no)?);
    }

    // Push final phase
    if !current_phase.commands.is_empty() || has_explicit_phase {
        script.phases.push(current_phase);
    }

    Ok(script)
}

/// Parse a hex script from a file path.
pub fn parse_hex_file(path: &std::path::Path) -> Result<HexScript, String> {
    let content = std::fs::read_to_string(path)
        .map_err(|e| format!("Cannot open {}: {}", path.display(), e))?;
    parse_hex_str(&content)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_simple() {
        let hex = "\
# Test
## FRAMEBUFFER: 512 480
## PHASE: main
40 0000_0099_0000_0000  # FB_CONFIG
30 0000_0000_0000_0011  # RENDER_MODE
";
        let script = parse_hex_str(hex).unwrap();
        assert_eq!(script.fb_width, 512);
        assert_eq!(script.fb_height, 480);
        assert_eq!(script.phases.len(), 1);
        assert_eq!(script.phases[0].name, "main");
        assert_eq!(script.phases[0].commands.len(), 2);
        assert_eq!(script.phases[0].commands[0].addr, 0x40);
        assert_eq!(script.phases[0].commands[0].data, 0x0000_0099_0000_0000);
        assert_eq!(script.phases[0].commands[1].addr, 0x30);
        assert_eq!(script.phases[0].commands[1].data, 0x11);
    }

    #[test]
    fn test_parse_multi_phase() {
        let hex = "\
## FRAMEBUFFER: 512 480
## PHASE: zclear
40 0000_0099_0000_0000
## PHASE: draw
30 0000_0000_0000_0011
";
        let script = parse_hex_str(hex).unwrap();
        assert_eq!(script.phases.len(), 2);
        assert_eq!(script.phases[0].name, "zclear");
        assert_eq!(script.phases[0].commands.len(), 1);
        assert_eq!(script.phases[1].name, "draw");
        assert_eq!(script.phases[1].commands.len(), 1);
    }

    #[test]
    fn test_parse_texture_directive() {
        let hex = "\
## TEXTURE: checker_wb base=0x80000 format=RGB565 width_log2=4
## PHASE: main
40 0000000000000000
";
        let script = parse_hex_str(hex).unwrap();
        assert_eq!(script.textures.len(), 1);
        assert_eq!(script.textures[0].tex_type, "checker_wb");
        assert_eq!(script.textures[0].base_word, 0x80000);
        assert_eq!(script.textures[0].format, "RGB565");
        assert_eq!(script.textures[0].width_log2, 4);
    }
}
