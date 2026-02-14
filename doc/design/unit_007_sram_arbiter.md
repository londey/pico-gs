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
| `portN_burst_len` | 8 | Burst length in 16-bit words (0=single-word access, 1-255=burst) |

**SRAM Controller Interface:**

| Signal | Width | Description |
|--------|-------|-------------|
| `sram_rdata` | 16 | Read data from SRAM (16-bit during burst, zero-extended to 32 in single mode) |
| `sram_rdata_32` | 32 | Assembled 32-bit read data from SRAM (single-word mode only) |
| `sram_ack` | 1 | SRAM access complete (end of single-word or burst transfer) |
| `sram_ready` | 1 | SRAM controller ready for new request |
| `sram_burst_data_valid` | 1 | Valid 16-bit word available during burst read (pulsed each cycle) |
| `sram_burst_wdata_req` | 1 | SRAM controller requests next 16-bit write word during burst |
| `sram_burst_done` | 1 | Burst transfer complete (coincides with sram_ack for burst transfers) |

**Global:**

| Signal | Width | Description |
|--------|-------|-------------|
| `clk` | 1 | Unified 100 MHz system clock (`clk_core`) |
| `rst_n` | 1 | Active-low reset |

### Outputs

**Per Port (0-3):**

| Signal | Width | Description |
|--------|-------|-------------|
| `portN_rdata` | 32 | Read data routed from SRAM (registered on ack, single-word mode) |
| `portN_burst_rdata` | 16 | Burst read data routed from SRAM (valid when portN_burst_data_valid=1) |
| `portN_burst_data_valid` | 1 | Burst read word available for this port |
| `portN_burst_wdata_req` | 1 | Request for next burst write word from this port |
| `portN_ack` | 1 | Access complete for this port (single-word or burst) |
| `portN_ready` | 1 | Port may issue a request (combinational) |

**SRAM Controller Interface:**

| Signal | Width | Description |
|--------|-------|-------------|
| `sram_req` | 1 | Request to SRAM controller |
| `sram_we` | 1 | Write enable to SRAM |
| `sram_addr` | 24 | Address to SRAM |
| `sram_wdata` | 32 | Write data to SRAM (single-word) |
| `sram_burst_wdata` | 16 | Write data to SRAM (burst mode, 16-bit) |
| `sram_burst_len` | 8 | Burst length to SRAM controller (0=single, 1-255=burst) |
| `sram_burst_cancel` | 1 | Preempt/cancel active burst (arbiter to SRAM controller) |

### Internal State

- **granted_port** [1:0]: Index of the currently granted port (0-3)
- **grant_active** [1:0]: A grant is in progress, waiting for sram_ack
- **burst_active** [0]: A burst transfer is in progress
- **burst_remaining** [7:0]: Number of 16-bit words remaining in the current burst
- **burst_preempt_pending** [0]: A higher-priority port has requested access during an active burst

### Algorithm / Behavior

**Single Clock Domain:**
The arbiter, all requestor ports (display controller, pixel pipeline framebuffer, pixel pipeline Z-buffer, pixel pipeline texture), and the SRAM controller all operate in the unified 100 MHz `clk_core` domain.
No clock domain crossing (CDC) logic is required between the GPU core and SRAM.
The only asynchronous CDC boundary in the system is between the SPI slave interface and the GPU core (handled by UNIT-002).
This single-domain design eliminates synchronizer latency on request/acknowledge paths, enabling back-to-back grants on consecutive clock cycles.

**Fixed-Priority Arbitration:**
Priority order: Port 0 (display) > Port 1 (framebuffer) > Port 2 (Z-buffer) > Port 3 (texture).
This ensures display refresh never stalls.

**Temporal Access Pattern Note:**
With early Z-test support (UNIT-006), a Z-prepass can be performed where only Z-buffer writes occur (color_write disabled).
During the Z-prepass, Port 1 (framebuffer) sees no traffic, effectively giving Port 2 (Z-buffer) higher throughput since it only competes with Port 0 (display).
During the subsequent color pass, Port 2 traffic is reduced (fewer Z writes due to early rejection), improving Port 1 framebuffer write throughput.
This temporal separation improves overall SRAM utilization without requiring changes to the arbiter logic.

**Grant State Machine (3 states):**

1. **Idle** (!grant_active && !burst_active): Combinational priority encoder selects the highest-priority port with req asserted.
   If a valid requestor exists and sram_ready is high:
   - Latch granted_port, set grant_active
   - Multiplex selected port's addr, wdata, we, burst_len onto SRAM bus
   - Assert sram_req
   - If burst_len > 0: set burst_active, load burst_remaining from burst_len

2. **Active (Single-Word)** (grant_active && !burst_active): Wait for sram_ack:
   - On sram_ack: deassert sram_req, clear grant_active, route sram_rdata_32 to granted port's rdata register

3. **Active (Burst)** (grant_active && burst_active): Burst transfer in progress:
   - Route burst read data (sram_burst_data_valid) or burst write requests (sram_burst_wdata_req) to/from the granted port
   - Decrement burst_remaining on each sram_burst_data_valid or sram_burst_wdata_req
   - **Preemption check** (every cycle): If a higher-priority port than granted_port asserts req, set burst_preempt_pending
   - **Preemption execution**: When burst_preempt_pending is set, assert sram_burst_cancel to the SRAM controller.
     The SRAM controller completes the current 16-bit word, then transitions to DONE.
     On sram_ack (burst complete or preempted): clear grant_active, clear burst_active, clear burst_preempt_pending.
     The preempted port receives portN_ack with the actual words transferred.
     The preempted port is responsible for re-requesting the remaining words.
   - On sram_burst_done (natural completion): clear grant_active, clear burst_active, assert portN_ack

**Burst Preemption Policy:**

The arbiter enforces a maximum burst length before a mandatory preemption check.
This prevents lower-priority burst transfers from starving higher-priority ports.

| Granted Port | Max Burst Before Preemption Check | Rationale |
|--------------|-----------------------------------|-----------|
| Port 0 (display) | No limit (highest priority) | Display is never preempted |
| Port 1 (framebuffer) | 16 words | Limits worst-case display latency to 16 cycles |
| Port 2 (Z-buffer) | 8 words | Short bursts; Z accesses are interleaved with test logic |
| Port 3 (texture) | 16 words | Matches BC1/RGBA4444 cache line sizes |

When a burst reaches the maximum length without preemption, the arbiter allows it to complete naturally.
Preemption only occurs if a higher-priority port actually asserts req during the burst.

**Read Data Distribution:**
- For single-word mode: on sram_ack, sram_rdata_32 is registered into the granted port's rdata output register.
  All other port rdata outputs hold their previous values.
- For burst mode: on each sram_burst_data_valid, sram_rdata (16-bit) is routed to the granted port's burst_rdata output.
  The granted port's burst_data_valid is asserted for one cycle.

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

**Single-Word Mode (existing):**
- Verify single-port access: each port independently performs read and write, confirm correct data routing
- Verify priority: simultaneous requests from all 4 ports, confirm port 0 is always served first
- Verify starvation: port 0 continuous requests starve port 3; port 3 served when port 0 idle
- Verify ack routing: sram_ack is delivered only to the granted port
- Verify rdata routing: read data appears only on the granted port's rdata output
- Verify ready signals: port1_ready deasserts when port0_req is high
- Verify back-to-back grants: after sram_ack, a new grant can be issued in the next cycle
- Verify reset: grant_active cleared, sram_req deasserted

**Burst Mode:**
- Verify burst grant: port issues burst_len=8, confirm 8 sequential 16-bit words transferred before ack
- Verify burst read data routing: burst_data_valid and burst_rdata appear only on the granted port
- Verify burst write data requests: burst_wdata_req routed only to the granted port
- Verify burst preemption: during port 3 burst, assert port 0 req; confirm burst is cancelled and port 0 is served
- Verify burst preemption data integrity: preempted burst completes current 16-bit word before stopping
- Verify burst completion: burst completes naturally when no higher-priority port interrupts
- Verify burst_len=0 selects single-word mode (backward compatibility)
- Verify burst + single-word interleaving: port 0 issues single-word requests while port 3 has a burst; confirm port 0 preempts
- Verify max burst preemption limits per port (16 words for port 1/3, 8 words for port 2)

## Design Notes

Migrated from speckit module specification.

**v2.0 unified clock update:** With the GPU core clock unified to 100 MHz (matching the SRAM clock), the arbiter operates in a single clock domain.
Previously, if the GPU core ran at a different frequency than the SRAM, CDC synchronizers would have been required on the request/acknowledge handshake paths between requestors and the SRAM controller.
The unified 100 MHz clock eliminates this requirement entirely, reducing latency and simplifying timing analysis.
All four requestor ports (UNIT-008 display read, UNIT-006 framebuffer write, UNIT-006 Z-buffer read/write, UNIT-006 texture read) are now synchronous to the same `clk_core` that drives the SRAM controller.
