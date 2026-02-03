# Project Constitution

**Version**: 2.0.0
**Ratified**: 2026-01-29
**Last Amended**: 2026-02-03

## Preamble

This document establishes the non-negotiable development practices and coding standards for the pico-gs project. These principles ensure code quality, reliability, and maintainability across all features and components.

**Scope**: This constitution defines *how* we build software, not *what* we build. Architectural decisions and design constraints are documented separately in [ARCHITECTURE.md](ARCHITECTURE.md).

---

## Article I: Test-First Development

**No code shall be integrated without test coverage.**

Required test progression:
1. **Unit tests**: Individual module functionality with isolated components
2. **Integration tests**: Module interactions and end-to-end workflows
3. **Reference tests**: Output validation against known-good references (where applicable)
4. **Hardware tests**: On-device validation after synthesis (for embedded code)

### Testing Standards

**For Rust code:**
- Write tests before implementation (TDD approach)
- All public API functions must have unit tests
- Integration tests in `tests/` directory for cross-module functionality
- Use fixtures for consistent test data
- Test coverage targets:
  - All public API paths
  - Error handling branches
  - Boundary conditions (empty inputs, maximum values, edge cases)

**For RTL code:**
- Every module must have a Verilator testbench
- Cocotb is the preferred test framework for complex scenarios
- Test coverage targets:
  - All register read/write paths
  - All state machine transitions
  - Boundary conditions (FIFO full/empty, counter wraparound, etc.)

**Rationale**: Tests are documentation, specification, and safety net. They enable confident refactoring and catch regressions early.

---

## Article II: Rust Code Standards

All Rust code (host firmware and tooling) **must** adhere to these standards.

### Module Organization
- Use modern `<module_name>.rs` style, not legacy `mod.rs` patterns
- One logical concept per module
- Re-export public items from `lib.rs` for clean API surface

### Error Handling
- Use `Result<T, E>` with `?` operator for all fallible operations
- **No** `.unwrap()` or `.expect()` in library code or production paths
- `.unwrap()` only acceptable in:
  - Test code where panic indicates test failure
  - Main entry points where failure should terminate the program
- Libraries: Use `thiserror` for custom error types with context
- Applications: Use `anyhow` for error propagation with added context

### Logging
- Use `log` crate with appropriate levels (`error!`, `warn!`, `info!`, `debug!`, `trace!`)
- **No** `println!`/`eprintln!` except in main entry points
- Log levels:
  - `error!`: Unrecoverable failures
  - `warn!`: Recoverable issues or unexpected conditions
  - `info!`: High-level progress and user-facing events
  - `debug!`: Detailed diagnostic information
  - `trace!`: Very verbose internal state

### Documentation
All public items **must** have rustdoc comments including:

**Functions:**
```rust
/// Brief one-line description.
///
/// Longer description if needed, explaining behavior and context.
///
/// # Arguments
/// * `param` - Description of parameter
///
/// # Returns
/// Description of return value
///
/// # Errors
/// When this function returns an error and why
///
/// # Panics
/// If this function can panic and under what conditions (should be rare!)
///
/// # Examples
/// ```
/// // Usage example
/// ```
```

**Modules, structs, enums, constants:**
- Purpose and usage context
- Invariants or constraints
- References to specifications where applicable

### Code Quality
- **Formatting**: Run `cargo fmt` before all commits
- **Linting**: Configure crate-level lints in `lib.rs`/`main.rs`:
  ```rust
  #![deny(unsafe_code)]
  #![warn(missing_docs)]
  #![warn(clippy::all)]
  ```
- Deny `unsafe_code` unless explicitly justified with safety documentation
- Use `#[must_use]` attribute on functions with important return values

### Dependencies
- Add with `default-features = false` and explicit feature selection
- Justify all dependencies (avoid bloat)
- Prefer `no_std` compatible crates for embedded code
- Pin major versions in Cargo.toml

### Build Verification
All code **must** pass before merge:
```bash
cargo fmt --check
cargo clippy -- -D warnings
cargo test
cargo build --release
cargo deny check          # License and advisory validation
cargo audit              # Security vulnerability scan
```

**Rationale**: Embedded systems and hardware tooling demand reliability. Panics are unacceptable in no_std firmware contexts. Strict error handling, minimal dependencies, and thorough validation prevent runtime failures.

---

## Article III: Verilog/SystemVerilog Code Standards

All RTL code (FPGA modules and testbenches) **must** adhere to these standards.

### File Structure
- Start files with `` `default_nettype none ``
- One module per file, filename matches module name
- Module ports on separate lines with inline comments

### Documentation
- All modules must have header comments explaining purpose
- All ports must have inline comments describing function
- Complex logic blocks must have explanatory comments
- State machines must document states and transitions

### Naming Conventions
- Active-low signals use `_n` suffix (e.g., `rst_n`, `cs_n`)
- Descriptive names over abbreviations (e.g., `pixel_counter` not `px_cnt`)
- Clock signals named `clk` or with domain suffix (e.g., `clk_pixel`)
- Reset signals named `rst` or `rst_n` (active-low)

### Declarations
- One declaration per line
- Explicit bit widths on all literals: `8'h0F` not `'h0F`
- Group related signals together
- Initialize registers in declaration when possible

### Sequential Logic (`always_ff`)
- **Simple assignments only** (exceptions: memory inference, async reset synchronizers)
- Use non-blocking assignments (`<=`)
- All computational logic belongs in `always_comb`, not `always_ff`
- Consistent reset style across module (prefer synchronous reset unless justified)

**Good:**
```systemverilog
always_ff @(posedge clk) begin
    if (rst) begin
        counter <= 8'd0;
    end else begin
        counter <= next_counter;  // Simple assignment
    end
end
```

**Bad:**
```systemverilog
always_ff @(posedge clk) begin
    if (rst) begin
        counter <= 8'd0;
    end else begin
        counter <= counter + 8'd1;  // Computation in always_ff
    end
end
```

### Combinational Logic (`always_comb`)
- Default assignments at block start to prevent latches
- Use blocking assignments (`=`)
- Use `unique case` or `priority case` with explicit `default`
- Always use `begin`/`end` blocks for `if`/`else`/`case` items

**Example:**
```systemverilog
always_comb begin
    // Default assignments prevent latches
    next_state = state;
    output_valid = 1'b0;

    unique case (state)
        IDLE: begin
            if (start) begin
                next_state = ACTIVE;
            end
        end
        ACTIVE: begin
            output_valid = 1'b1;
            if (done) begin
                next_state = IDLE;
            end
        end
        default: begin
            next_state = IDLE;
        end
    endcase
end
```

### Module Instantiation
- **Named port connections only** (never positional)
- Align port names and connections for readability
- One port per line

**Good:**
```systemverilog
fifo #(
    .WIDTH(8),
    .DEPTH(16)
) tx_fifo (
    .clk        (clk),
    .rst        (rst),
    .wr_en      (fifo_wr),
    .wr_data    (tx_data),
    .rd_en      (fifo_rd),
    .rd_data    (rx_data),
    .full       (fifo_full),
    .empty      (fifo_empty)
);
```

### Testing and Verification
Every module **must** have verification:
- Verilator testbench for all modules
- Build command: `verilator --binary -Wall module_tb.sv module.sv`
- Lint command: `verilator --lint-only -Wall module.sv`
- **All warnings must be fixed** (no pragma suppression without justification)

### Simulation Flags
Use comprehensive verification flags:
```bash
verilator \
    --binary \
    --assert \
    --trace-fst \
    --x-assign unique \
    --x-initial unique \
    -Wall \
    module_tb.sv module.sv
```

Flags explained:
- `--assert`: Enable SystemVerilog assertions
- `--trace-fst`: Generate waveform dumps for debugging
- `--x-assign unique`: Expose uninitialized/unknown state bugs
- `--x-initial unique`: Detect reads of uninitialized registers
- `-Wall`: Enable all warnings

**Rationale**: FPGA synthesis behavior differs from simulation. Strict separation of combinational and sequential logic ensures Verilator simulations accurately predict synthesized hardware behavior. Comprehensive testing catches timing, initialization, and CDC issues before expensive FPGA compile cycles.

---

## Article IV: Documentation as Practice

Documentation is a first-class deliverable, not an afterthought.

### Requirements
- **Code comments**: Explain *why*, not *what* (code should be self-documenting for *what*)
- **API documentation**: All public interfaces documented with usage examples
- **Architecture docs**: High-level design decisions in separate documents
- **Change documentation**: Update docs when implementation changes

### Documentation Standards
- Use markdown for all text documentation
- Keep docs close to code (doc comments in source, design docs in `specs/`)
- Include diagrams for complex state machines, data flows, and interfaces
- Provide runnable examples in documentation where applicable

**Rationale**: Stale or missing documentation is a defect. Good documentation enables onboarding, debugging, and future maintenance.

---

## Article V: Incremental Delivery

Features **must** be delivered in testable, demonstrable increments.

### Principles
1. Each increment provides standalone value
2. Each increment is fully tested before proceeding
3. Integration happens continuously, not at the end
4. "It works in simulation" is necessary but not sufficient for hardware projects

### Practice
- Break large features into small, mergeable chunks
- Each PR should be reviewable (< 500 lines when possible)
- Prefer many small commits over monolithic changes
- Test at boundaries: unit → integration → system

**Rationale**: Small increments reduce risk, enable early feedback, and maintain a working system at all times.

---

## Article VI: Simplicity Principle

Prefer simple solutions over clever ones.

### Guidelines
- Solve today's problem, not tomorrow's hypothetical problem
- Three similar lines are better than a premature abstraction
- Avoid over-engineering: only add complexity when justified by real requirements
- Question every dependency and feature addition

### Code Review Questions
- Can this be simpler?
- Is this abstraction pulling its weight?
- Are we solving a real problem or an imagined one?
- What's the maintenance burden?

**Rationale**: Simple code is debuggable code. Complexity is the enemy of reliability, especially in embedded systems and hardware design.

---

## Governance

### Version Control

This constitution follows semantic versioning (MAJOR.MINOR.PATCH):

- **MAJOR**: Backward-incompatible changes to core principles
- **MINOR**: New articles added or material expansions to existing guidance
- **PATCH**: Clarifications, wording improvements, typo fixes

### Amendment Process

This constitution may be amended when development practices evolve or new consensus emerges.

**Amendment procedure:**

1. Propose change with rationale and impact assessment
2. Update constitution file with version increment
3. Update affected templates and documentation for consistency
4. Document in commit message: `docs: amend constitution to vX.Y.Z (brief description)`

### Compliance Review

All feature plans should reference applicable constitutional articles. Violations require explicit justification and risk documentation.

### Change History

- **2.0.0** (2026-02-03): Restructured to focus on development practices and coding standards; moved architectural decisions to ARCHITECTURE.md
- **1.1.0** (2026-02-01): Added Article X (Rust Code Standards), Article XI (Verilog/SystemVerilog Code Standards)
- **1.0.0** (2026-01-29): Initial constitution ratified
