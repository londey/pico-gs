---
name: claude-skill-verilog-contracts
description: Component boundaries, interfaces, bound SVA properties, and conformance-harness discipline for SystemVerilog projects
---

# SystemVerilog Component Boundaries and Contracts

Apply when a project has adopted the component-contracts layout: a shared types package, per-component interface files, bound property modules, and conformance testbenches. If the project has none of these, this skill does not apply — follow only the base style skill and do not invent the missing infrastructure.

Before using this skill, verify the project actually has:

* A types package (typically `pkg/<project>_types_pkg.sv` or similar) imported by implementations.
* A contracts or interfaces directory (typically `contracts/` or `interfaces/`) with `*_if.sv` files.
* A properties directory or convention (typically `*_properties.sv` alongside each interface).
* A conformance testbench per contract (typically under `tb/` or `tb/cocotb/`).
* A single script or build target that runs lint + properties + conformance for a named component.

If any of these are absent, stop and ask before proceeding — do not create the structure speculatively.

## The three-file component boundary

Every component boundary consists of three artifacts, authored in this order:

1. **Types** — added to the shared types package. All signals crossing module boundaries use named packed struct types. Never introduce a raw `logic [N:0]` port without first checking whether an appropriate type exists; if it doesn't, add one to the types package before writing the interface.

2. **Interface** — one `<name>_if.sv` file per component boundary. Declares ports and modports for one boundary only. Parameterized by widths, never by behavior. Kept shallow: no nested interfaces inside synthesis paths.

3. **Properties** — one `<name>_properties.sv` file per interface. A separate module containing bound SVA for protocol legality, handshake rules, and latency bounds. Attached to implementations via `bind` in testbenches, never instantiated inside the implementation itself.

The interface is the *shape* contract. The properties file is the *behavioral* contract. Neither alone is sufficient; both are required.

## What belongs in properties vs. the conformance testbench

Properties files contain protocol hygiene: handshake legality, no-X on valid cycles, response-after-request ordering, bounded latency, mutual exclusion between signals. Things that can be stated as SVA properties and that hold across all valid inputs.

The conformance testbench contains functional correctness: bit-accurate comparison against a reference model (digital twin, golden trace, or algorithmic spec). Things that require specific stimulus and observation of outputs over time.

Do not assert functional correctness in SVA. Do not assert protocol properties only in the testbench. Keeping these separate prevents properties files from sprawling into speculative half-working behavioral specs.

## Types package conventions

Every named type has a comment stating its purpose and, where applicable, its Q-format annotation:

```systemverilog
package example_types_pkg;
    // Request from client to cache
    typedef struct packed {
        logic [31:0] addr;     // Byte address
        logic [7:0]  len;      // Burst length minus 1
        logic [3:0]  id;       // Transaction ID
    } cache_req_t;

    // Fixed-point gain, Q4.12
    typedef logic signed [15:0] gain_q4_12_t;
endpackage
```

Never define the same concept as a raw vector in one place and a packed struct in another. If the types package has `cache_req_t`, the interface uses it; ports do not accept a flattened equivalent.

## Interface conventions

```systemverilog
interface cache_if
    import example_types_pkg::*;
(
    input logic clk,
    input logic rst_n
);
    cache_req_t  req;
    logic        req_valid;
    logic        req_ready;
    cache_resp_t resp;
    logic        resp_valid;

    modport client (
        output req, req_valid,
        input  req_ready,
        input  resp, resp_valid
    );

    modport server (
        input  req, req_valid,
        output req_ready,
        output resp, resp_valid
    );

    modport monitor (
        input req, req_valid, req_ready,
        input resp, resp_valid
    );
endinterface
```

* Always provide `client`, `server`, and `monitor` modports. The `monitor` modport is required for property binding.
* Interface parameters cover widths and depths only. Never parameterize by behavior or protocol variant — variants get their own interface file.
* Do not nest interfaces inside other interfaces for signals that cross a synthesis boundary.

## Properties file conventions

Properties are authored as a module taking the interface's `monitor` modport:

```systemverilog
module cache_properties (cache_if.monitor bus);
    // Handshake: req_valid must not drop while ready is pending
    property p_req_stable_until_ready;
        @(posedge bus.clk) disable iff (!bus.rst_n)
        bus.req_valid && !bus.req_ready |=>
        bus.req_valid && $stable(bus.req);
    endproperty
    assert property (p_req_stable_until_ready)
        else $error("req dropped or changed before ready");

    // Bounded response latency
    localparam int MAX_LAT = 32;
    property p_resp_within_latency;
        @(posedge bus.clk) disable iff (!bus.rst_n)
        (bus.req_valid && bus.req_ready) |-> ##[1:MAX_LAT] bus.resp_valid;
    endproperty
    assert property (p_resp_within_latency)
        else $error("no response within MAX_LAT cycles");
endmodule
```

Attached in the testbench, not in the implementation:

```systemverilog
bind cache_bram cache_properties props (.bus(cache_bus));
```

Rules:

* One property per named block with a descriptive name prefixed `p_`.
* Every assert has an `else $error(...)` with a human-readable message.
* Properties use `disable iff (!rst_n)` uniformly.
* Do not put `initial` or `always` blocks in properties files. Properties only.

## Conformance testbench conventions

A conformance testbench proves that an implementation satisfies the contract. It must:

1. Instantiate the interface and connect the implementation to its `server` (or client) modport.
2. Bind the properties module to the implementation.
3. Drive stimulus through the `client` (or server) modport.
4. For designs with a reference model: capture both DUT and reference traces and binary-diff them. Diverge → fail.
5. Exit nonzero on any assertion failure or trace mismatch.

The testbench is the executable definition of "this implementation satisfies the contract." Passing lint is necessary but not sufficient. Passing properties is necessary but not sufficient. Passing the trace diff against the reference is also necessary. All three are required for acceptance.

## Directory conventions

A project using this skill typically has something like:

```
rtl/
├── pkg/
│   └── <project>_types_pkg.sv
├── contracts/
│   ├── <name>_if.sv
│   └── <name>_properties.sv
└── <component>/
    └── <component>.sv
tb/
└── <name>_conformance/
```

Do not move files between these directories without being asked. Do not create parallel organizational schemes.

## Order of operations when implementing a new component

When asked to implement a new component that has a contract:

1. Read the interface file. Do not proceed if it does not exist — ask whether to author one.
2. Read the properties file. Note the invariants that will be checked.
3. Read the conformance testbench and any reference model it uses.
4. Only then write the implementation.

When asked to add a new component that does not yet have a contract:

1. Propose type additions and wait for confirmation before editing the types package.
2. Author the interface file.
3. Author the properties file.
4. Author the conformance testbench (including reference-model stub if applicable).
5. Only then write the implementation.

Never write an implementation before the properties exist. The properties are the specification; writing the implementation first and the properties afterward produces properties that describe what the implementation happens to do rather than what it should do.

## Order of operations when modifying an existing component

If the component was authored under this discipline (has matching interface, properties, and conformance testbench): modify all four artifacts together, keeping them in sync. If the change is to the contract itself, expect the conformance harness to fail until implementations are updated — this is intended.

If the component predates this discipline: do not retrofit it unless explicitly asked. Work within its existing structure. Retrofitting in the course of unrelated work is how projects lose a weekend.

## Acceptance criteria

A component change is not complete until the single project-level check command (typically `scripts/check_contract.sh <component>` or a make target) reports success. That command must cover:

* Lint (Verilator `--lint-only -Wall -Wpedantic`, no suppressions).
* Synthesis elaboration on the target flow.
* Property assertions during simulation.
* Conformance trace diff against the reference model, where one exists.

"Lint passes" is not acceptance. "My testbench works" is not acceptance. The full check command passing is acceptance. Do not claim completion otherwise.

## Common failure modes to avoid

* **Fabricating directory structure.** If `contracts/` does not exist in the project, do not create it and scatter files into it. Ask.
* **Writing properties to match a buggy implementation.** Properties must come from the specification, not from observed behavior. If a property fails against a new implementation, the default presumption is that the implementation is wrong, not the property.
* **Over-propertizing.** Resist asserting full functional correctness via SVA. That is the conformance testbench's job. SVA covers protocol and timing.
* **Under-propertizing.** At minimum, every handshake has legality properties and every response has a bounded latency property. Interfaces without these are not contracted.
* **Retrofitting during unrelated changes.** If the task is "fix a bug in module X," do not also restructure X to fit this discipline. Propose the refactor as a separate task.
* **Instantiating properties inside the implementation.** Properties are bound from the testbench via `bind`. They never appear in synthesizable source.
* **Using raw vectors on contracted ports.** Once an interface exists for a boundary, all implementations of that boundary use the interface. No "quick" raw-signal versions.
