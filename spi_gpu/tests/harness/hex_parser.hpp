// Header-only parser for GPU test script .hex files.
//
// Parses register-write commands from annotated hex files shared between
// the Verilator harness and the digital twin.
//
// Format:
//   - '#' to end-of-line is a comment
//   - '_' within hex values is ignored (visual grouping)
//   - Data lines: '<2-hex addr> <16-hex data>'
//   - '## PHASE: <name>' delimits named phases
//   - '## FRAMEBUFFER: <width> <height>' declares output dimensions
//   - '## TEXTURE: <type> base=<hex> format=<fmt> width_log2=<n>'
//   - '## INCLUDE: <relative-path>' includes another hex file

#ifndef HEX_PARSER_HPP
#define HEX_PARSER_HPP

#include <algorithm>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

/// A single register write: 7-bit address + 64-bit data.
/// Same layout as the existing RegWrite struct in harness.cpp.
struct HexRegWrite {
    uint8_t addr;
    uint64_t data;
};

/// A texture pre-load directive parsed from a '## TEXTURE:' line.
struct TextureDirective {
    std::string type;       // e.g. "checker_wb", "checker_wg"
    uint32_t base_word;     // SDRAM word address for fill_texture
    std::string format;     // e.g. "RGB565"
    uint8_t width_log2;     // log2 of texture width (e.g. 4 for 16px)
};

/// A named phase containing a sequence of register writes.
struct HexPhase {
    std::string name;
    std::vector<HexRegWrite> commands;
};

/// Complete parsed hex script.
struct HexScript {
    int fb_width = 0;
    int fb_height = 0;
    std::vector<HexPhase> phases;
    std::vector<TextureDirective> textures;

    /// Convenience: get all commands across all phases, flattened.
    [[nodiscard]] std::vector<HexRegWrite> all_commands() const {
        std::vector<HexRegWrite> result;
        for (const auto& phase : phases) {
            result.insert(result.end(), phase.commands.begin(), phase.commands.end());
        }
        return result;
    }
};

namespace hex_parser_detail {

/// Strip '_' characters from a string (hex visual separator).
inline std::string strip_underscores(const std::string& s) {
    std::string result;
    result.reserve(s.size());
    for (char c : s) {
        if (c != '_') {
            result += c;
        }
    }
    return result;
}

/// Parse a hex string to uint64_t.
inline uint64_t parse_hex64(const std::string& s) {
    return std::stoull(strip_underscores(s), nullptr, 16);
}

/// Parse a hex string to uint32_t.
inline uint32_t parse_hex32(const std::string& s) {
    return static_cast<uint32_t>(std::stoul(strip_underscores(s), nullptr, 16));
}

/// Parse '## TEXTURE: <type> base=0x<hex> format=<fmt> width_log2=<n>'
inline TextureDirective parse_texture_directive(const std::string& line) {
    TextureDirective td{};

    // Find the content after "## TEXTURE: "
    auto pos = line.find("## TEXTURE:");
    if (pos == std::string::npos) {
        throw std::runtime_error("Not a TEXTURE directive: " + line);
    }
    std::string content = line.substr(pos + 11);

    std::istringstream iss(content);
    iss >> td.type; // e.g. "checker_wb"

    std::string token;
    while (iss >> token) {
        if (token.substr(0, 5) == "base=") {
            std::string val = token.substr(5);
            // Strip optional 0x prefix
            if (val.size() > 2 && val[0] == '0' && (val[1] == 'x' || val[1] == 'X')) {
                val = val.substr(2);
            }
            td.base_word = parse_hex32(val);
        } else if (token.substr(0, 7) == "format=") {
            td.format = token.substr(7);
        } else if (token.substr(0, 10) == "width_log2=") {
            td.width_log2 = static_cast<uint8_t>(std::stoi(token.substr(10)));
        }
    }

    return td;
}

} // namespace hex_parser_detail

// Forward declaration for parse_hex_string_with_base
inline HexScript parse_hex_string_with_base(
    const std::string& content,
    const std::string& base_dir);

/// Parse a hex script from a string (no ## INCLUDE: support).
inline HexScript parse_hex_string(const std::string& content) {
    return parse_hex_string_with_base(content, "");
}

/// Parse a hex script from a string, resolving ## INCLUDE: directives
/// relative to base_dir.  If base_dir is empty, includes are silently
/// ignored.
inline HexScript parse_hex_string_with_base(
    const std::string& content,
    const std::string& base_dir)
{
    HexScript script;
    HexPhase current_phase;
    current_phase.name = "main"; // default phase name
    bool has_explicit_phase = false;

    std::istringstream stream(content);
    std::string line;

    while (std::getline(stream, line)) {
        // Strip trailing whitespace
        while (!line.empty() && (line.back() == ' ' || line.back() == '\t' ||
                                  line.back() == '\r' || line.back() == '\n')) {
            line.pop_back();
        }

        // Check for directives (## lines) before stripping comments
        if (line.size() >= 2 && line[0] == '#' && line[1] == '#') {
            if (line.find("## PHASE:") == 0) {
                // Save current phase if it has commands
                if (!current_phase.commands.empty() || has_explicit_phase) {
                    script.phases.push_back(std::move(current_phase));
                    current_phase = HexPhase{};
                }
                current_phase.name = line.substr(9);
                // Trim leading whitespace from phase name
                auto start = current_phase.name.find_first_not_of(" \t");
                if (start != std::string::npos) {
                    current_phase.name = current_phase.name.substr(start);
                }
                has_explicit_phase = true;
                continue;
            }
            if (line.find("## FRAMEBUFFER:") == 0) {
                std::string dims = line.substr(15);
                std::istringstream diss(dims);
                diss >> script.fb_width >> script.fb_height;
                continue;
            }
            if (line.find("## TEXTURE:") == 0) {
                script.textures.push_back(
                    hex_parser_detail::parse_texture_directive(line));
                continue;
            }
            if (line.find("## INCLUDE:") == 0) {
                if (!base_dir.empty()) {
                    std::string rel_path = line.substr(11);
                    // Trim leading whitespace
                    auto start = rel_path.find_first_not_of(" \t");
                    if (start != std::string::npos) {
                        rel_path = rel_path.substr(start);
                    }
                    auto full_path =
                        std::filesystem::path(base_dir) / rel_path;
                    std::ifstream inc_file(full_path);
                    if (!inc_file.is_open()) {
                        throw std::runtime_error(
                            "Cannot include: " + full_path.string());
                    }
                    std::string inc_content(
                        (std::istreambuf_iterator<char>(inc_file)),
                        std::istreambuf_iterator<char>());
                    // Parse included file (non-recursive)
                    auto inc_script = parse_hex_string(inc_content);
                    // Splice included commands into current phase
                    for (const auto& phase : inc_script.phases) {
                        current_phase.commands.insert(
                            current_phase.commands.end(),
                            phase.commands.begin(),
                            phase.commands.end());
                    }
                    // Merge textures and framebuffer directives
                    script.textures.insert(
                        script.textures.end(),
                        inc_script.textures.begin(),
                        inc_script.textures.end());
                    if (inc_script.fb_width > 0) {
                        script.fb_width = inc_script.fb_width;
                    }
                    if (inc_script.fb_height > 0) {
                        script.fb_height = inc_script.fb_height;
                    }
                }
                continue;
            }
            // Other ## directives: ignore
            continue;
        }

        // Strip comments (# to end of line)
        auto comment_pos = line.find('#');
        if (comment_pos != std::string::npos) {
            line = line.substr(0, comment_pos);
        }

        // Strip whitespace
        while (!line.empty() && (line.front() == ' ' || line.front() == '\t')) {
            line.erase(line.begin());
        }
        while (!line.empty() && (line.back() == ' ' || line.back() == '\t')) {
            line.pop_back();
        }

        // Skip empty lines
        if (line.empty()) {
            continue;
        }

        // Parse data line: <addr_hex> <data_hex>
        std::istringstream liss(line);
        std::string addr_str;
        std::string data_str;
        liss >> addr_str >> data_str;

        if (addr_str.empty() || data_str.empty()) {
            continue; // Malformed line, skip
        }

        HexRegWrite rw{};
        rw.addr = static_cast<uint8_t>(
            hex_parser_detail::parse_hex64(addr_str) & 0x7F);
        rw.data = hex_parser_detail::parse_hex64(data_str);
        current_phase.commands.push_back(rw);
    }

    // Push final phase
    if (!current_phase.commands.empty() || has_explicit_phase) {
        script.phases.push_back(std::move(current_phase));
    }

    return script;
}

/// Parse a hex script from a file path.
/// Supports ## INCLUDE: directives resolved relative to the file's directory.
inline HexScript parse_hex_file(const std::string& filepath) {
    std::ifstream file(filepath);
    if (!file.is_open()) {
        throw std::runtime_error("Cannot open hex script: " + filepath);
    }
    std::string content(
        (std::istreambuf_iterator<char>(file)),
        std::istreambuf_iterator<char>());
    auto base_dir = std::filesystem::path(filepath).parent_path().string();
    return parse_hex_string_with_base(content, base_dir);
}

#endif // HEX_PARSER_HPP
