# UNIT-007: SRAM Arbiter

## Purpose

Arbitrates SRAM access between display and render

## Implements Requirements

- REQ-002 (Framebuffer Management)
- REQ-003 (Flat Shaded Triangle)
- REQ-005 (Depth Tested Triangle)
- REQ-014 (Enhanced Z-Buffer)
- REQ-015 (Memory Upload Interface)
- REQ-025 (Framebuffer Format)
- REQ-027 (Z-Buffer Operations)
- REQ-029 (Memory Upload Interface)

## Interfaces

### Provides

None

### Consumes

- INT-011 (SRAM Memory Layout)

### Internal Interfaces

- Port 0 (highest priority): UNIT-008 (Display Controller) display read
- Port 1: UNIT-006 (Pixel Pipeline) framebuffer write
- Port 2: UNIT-006 (Pixel Pipeline) Z-buffer read/write
- Port 3 (lowest priority): UNIT-006 (Pixel Pipeline) texture read
- Downstream: connects to external SRAM controller via req/ack handshake

## Design Description

### Inputs

**Per Port (0-3):**

| Signal | Width | Description |
|--------|-------|-------------|
| `portN_req` | 1 | Memory access request |
| `portN_we` | 1 | Write enable (0=read, 1=write) |
| `portN_addr` | 24 | SRAM byte address |
| `portN_wdata` | 32 | Write data |

**SRAM Controller Interface:**

| Signal | Width | Description |
|--------|-------|-------------|
| `sram_rdata` | 32 | Read data from SRAM |
| `sram_ack` | 1 | SRAM access complete |
| `sram_ready` | 1 | SRAM controller ready for new request |

**Global:**

| Signal | Width | Description |
|--------|-------|-------------|
| `clk` | 1 | System clock |
| `rst_n` | 1 | Active-low reset |

### Outputs

**Per Port (0-3):**

| Signal | Width | Description |
|--------|-------|-------------|
| `portN_rdata` | 32 | Read data routed from SRAM (registered on ack) |
| `portN_ack` | 1 | Access complete for this port |
| `portN_ready` | 1 | Port may issue a request (combinational) |

**SRAM Controller Interface:**

| Signal | Width | Description |
|--------|-------|-------------|
| `sram_req` | 1 | Request to SRAM controller |
| `sram_we` | 1 | Write enable to SRAM |
| `sram_addr` | 24 | Address to SRAM |
| `sram_wdata` | 32 | Write data to SRAM |

### Internal State

- **granted_port** [1:0]: Index of the currently granted port (0-3)
- **grant_active** [1:0]: A grant is in progress, waiting for sram_ack

### Algorithm / Behavior

**Fixed-Priority Arbitration:**
Priority order: Port 0 (display) > Port 1 (framebuffer) > Port 2 (Z-buffer) > Port 3 (texture). This ensures display refresh never stalls.

**Temporal Access Pattern Note:**
With early Z-test support (UNIT-006), a Z-prepass can be performed where only Z-buffer writes occur (color_write disabled).
During the Z-prepass, Port 1 (framebuffer) sees no traffic, effectively giving Port 2 (Z-buffer) higher throughput since it only competes with Port 0 (display).
During the subsequent color pass, Port 2 traffic is reduced (fewer Z writes due to early rejection), improving Port 1 framebuffer write throughput.
This temporal separation improves overall SRAM utilization without requiring changes to the arbiter logic.

**Grant State Machine (2 states):**

1. **Idle** (!grant_active): Combinational priority encoder selects the highest-priority port with req asserted. If a valid requestor exists and sram_ready is high:
   - Latch granted_port, set grant_active
   - Multiplex selected port's addr, wdata, we onto SRAM bus
   - Assert sram_req

2. **Active** (grant_active): Wait for sram_ack:
   - On sram_ack: deassert sram_req, clear grant_active, route sram_rdata to granted port's rdata register

**Read Data Distribution:**
- On sram_ack, sram_rdata is registered into the granted port's rdata output register
- All other port rdata outputs hold their previous values

**Acknowledge Signals (combinational):**
- portN_ack = (granted_port == N) && sram_ack

**Ready Signals (combinational):**
- port0_ready = !grant_active && sram_ready
- port1_ready = !grant_active && sram_ready && !port0_req
- port2_ready = !grant_active && sram_ready && !port0_req && !port1_req
- port3_ready = !grant_active && sram_ready && !port0_req && !port1_req && !port2_req

Each lower-priority port is only ready when no higher-priority port is requesting.

## Implementation

- `spi_gpu/src/memory/sram_arbiter.sv`: Main implementation

## Verification

- Verify single-port access: each port independently performs read and write, confirm correct data routing
- Verify priority: simultaneous requests from all 4 ports, confirm port 0 is always served first
- Verify starvation: port 0 continuous requests starve port 3; port 3 served when port 0 idle
- Verify ack routing: sram_ack is delivered only to the granted port
- Verify rdata routing: read data appears only on the granted port's rdata output
- Verify ready signals: port1_ready deasserts when port0_req is high
- Verify back-to-back grants: after sram_ack, a new grant can be issued in the next cycle
- Verify reset: grant_active cleared, sram_req deasserted

## Design Notes

Migrated from speckit module specification.
