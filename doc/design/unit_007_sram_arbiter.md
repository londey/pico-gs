# UNIT-007: Memory Arbiter

## Purpose

Arbitrates SDRAM access between display and render

## Implements Requirements

- REQ-005.01 (Framebuffer Management)
- REQ-002.01 (Flat Shaded Triangle)
- REQ-005.02 (Depth Tested Triangle)
- REQ-005.04 (Enhanced Z-Buffer)
- REQ-001.02 (Memory Upload Interface)
- REQ-005.06 (Framebuffer Format)
- REQ-005.07 (Z-Buffer Operations)

## Interfaces

### Provides

None

### Consumes

- INT-011 (SDRAM Memory Layout)

### Internal Interfaces

- Port 0 (highest priority): UNIT-008 (Display Controller) display read
- Port 1: UNIT-006 (Pixel Pipeline) framebuffer write
- Port 2: UNIT-006 (Pixel Pipeline) Z-buffer read/write
- Port 3 (lowest priority): UNIT-006 (Pixel Pipeline) texture read (up to 2 samplers)
- Downstream: connects to SDRAM controller via req/ack handshake

## Design Description

### Inputs

**Per Port (0-3):**

| Signal | Width | Description |
|--------|-------|-------------|
| `portN_req` | 1 | Memory access request |
| `portN_we` | 1 | Write enable (0=read, 1=write) |
| `portN_addr` | 24 | SDRAM byte address |
| `portN_wdata` | 32 | Write data |
| `portN_burst_len` | 8 | Burst length in 16-bit words (0=single-word access, 1-255=burst) |

**SDRAM Controller Interface:**

| Signal | Width | Description |
|--------|-------|-------------|
| `mem_rdata` | 16 | Read data from SDRAM (16-bit during sequential access, zero-extended to 32 in single mode) |
| `mem_rdata_32` | 32 | Assembled 32-bit read data from SDRAM (single-word mode only) |
| `mem_ack` | 1 | SDRAM access complete (end of single-word or sequential transfer) |
| `mem_ready` | 1 | SDRAM controller ready for new request (not in refresh or initialization) |
| `mem_burst_data_valid` | 1 | Valid 16-bit word available during sequential read (pulsed each cycle after CAS latency) |
| `mem_burst_wdata_req` | 1 | SDRAM controller requests next 16-bit write word during sequential write |
| `mem_burst_done` | 1 | Sequential transfer complete (coincides with mem_ack for sequential transfers) |

**Global:**

| Signal | Width | Description |
|--------|-------|-------------|
| `clk` | 1 | Unified 100 MHz system clock (`clk_core`) |
| `rst_n` | 1 | Active-low reset |

### Outputs

**Per Port (0-3):**

| Signal | Width | Description |
|--------|-------|-------------|
| `portN_rdata` | 32 | Read data routed from SDRAM (registered on ack, single-word mode) |
| `portN_burst_rdata` | 16 | Sequential read data routed from SDRAM (valid when portN_burst_data_valid=1) |
| `portN_burst_data_valid` | 1 | Burst read word available for this port |
| `portN_burst_wdata_req` | 1 | Request for next burst write word from this port |
| `portN_ack` | 1 | Access complete for this port (single-word or burst) |
| `portN_ready` | 1 | Port may issue a request (combinational) |

**SDRAM Controller Interface:**

| Signal | Width | Description |
|--------|-------|-------------|
| `mem_req` | 1 | Request to SDRAM controller |
| `mem_we` | 1 | Write enable to SDRAM |
| `mem_addr` | 24 | Address to SDRAM (byte address, controller decomposes into bank/row/column) |
| `mem_wdata` | 32 | Write data to SDRAM (single-word) |
| `mem_burst_wdata` | 16 | Write data to SDRAM (sequential mode, 16-bit) |
| `mem_burst_len` | 8 | Burst length to SDRAM controller (0=single, 1-255=sequential) |
| `mem_burst_cancel` | 1 | Preempt/cancel active sequential access (arbiter to SDRAM controller) |

### Internal State

- **granted_port** [1:0]: Index of the currently granted port (0-3)
- **grant_active** [1:0]: A grant is in progress, waiting for sram_ack
- **burst_active** [0]: A burst transfer is in progress
- **burst_remaining** [7:0]: Number of 16-bit words remaining in the current burst
- **burst_preempt_pending** [0]: A higher-priority port has requested access during an active burst

### Algorithm / Behavior

**Single Clock Domain:**
The arbiter, all requestor ports (display controller, pixel pipeline framebuffer, pixel pipeline Z-buffer, pixel pipeline texture), and the SDRAM controller all operate in the unified 100 MHz `clk_core` domain.
No clock domain crossing (CDC) logic is required between the GPU core and SDRAM controller.
The only asynchronous CDC boundary in the system is between the SPI slave interface and the GPU core (handled by UNIT-002).
This single-domain design eliminates synchronizer latency on request/acknowledge paths, enabling back-to-back grants on consecutive clock cycles.

**Fixed-Priority Arbitration:**
Priority order: Port 0 (display) > Port 1 (framebuffer) > Port 2 (Z-buffer) > Port 3 (texture).
This ensures display refresh never stalls.

**Temporal Access Pattern Note:**
With early Z-test support (UNIT-006), a Z-prepass can be performed where only Z-buffer writes occur (color_write disabled).
During the Z-prepass, Port 1 (framebuffer) sees no traffic, effectively giving Port 2 (Z-buffer) higher throughput since it only competes with Port 0 (display).
During the subsequent color pass, Port 2 traffic is reduced (fewer Z writes due to early rejection), improving Port 1 framebuffer write throughput.
This temporal separation improves overall SDRAM utilization without requiring changes to the arbiter logic.

**Grant State Machine (3 states):**

1. **Idle** (!grant_active && !burst_active): Combinational priority encoder selects the highest-priority port with req asserted.
   If a valid requestor exists and mem_ready is high (SDRAM controller not in refresh or initialization):
   - Latch granted_port, set grant_active
   - Multiplex selected port's addr, wdata, we, burst_len onto SDRAM controller bus
   - Assert mem_req
   - If burst_len > 0: set burst_active, load burst_remaining from burst_len

2. **Active (Single-Word)** (grant_active && !burst_active): Wait for mem_ack:
   - On mem_ack: deassert mem_req, clear grant_active, route mem_rdata_32 to granted port's rdata register
   - Note: single-word SDRAM read takes ~12 cycles (ACTIVATE + tRCD + READ + CL + data + PRECHARGE), longer than async SRAM's ~3 cycles

3. **Active (Sequential)** (grant_active && burst_active): Sequential transfer in progress:
   - Route sequential read data (mem_burst_data_valid) or sequential write requests (mem_burst_wdata_req) to/from the granted port
   - Decrement burst_remaining on each mem_burst_data_valid or mem_burst_wdata_req
   - Note: first read data arrives after CAS latency (CL=3); subsequent words arrive at 1 per cycle
   - **Preemption check** (every cycle): If a higher-priority port than granted_port asserts req, set burst_preempt_pending
   - **Preemption execution**: When burst_preempt_pending is set, assert mem_burst_cancel to the SDRAM controller.
     The SDRAM controller completes the current 16-bit transfer, issues a PRECHARGE to close the active row, then signals completion.
     On mem_ack (sequential complete or preempted): clear grant_active, clear burst_active, clear burst_preempt_pending.
     The preempted port receives portN_ack with the actual words transferred.
     The preempted port is responsible for re-requesting the remaining words (which will incur a new ACTIVATE + tRCD overhead).
   - On mem_burst_done (natural completion): clear grant_active, clear burst_active, assert portN_ack

**Auto-Refresh Handling:**
The SDRAM controller independently manages auto-refresh timing.
When a refresh is due, mem_ready deasserts, preventing the arbiter from issuing new requests.
If a sequential transfer is in progress when refresh becomes urgent, the SDRAM controller completes the current word, precharges, executes the refresh, then signals the arbiter to resume.
The arbiter treats refresh preemption identically to priority preemption: the affected port receives a partial completion and must re-request the remainder.

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
- For single-word mode: on mem_ack, mem_rdata_32 is registered into the granted port's rdata output register.
  All other port rdata outputs hold their previous values.
- For sequential mode: on each mem_burst_data_valid, mem_rdata (16-bit) is routed to the granted port's burst_rdata output.
  The granted port's burst_data_valid is asserted for one cycle.
  Note: the first mem_burst_data_valid arrives CL=3 cycles after the first READ command; subsequent words arrive at 1 per cycle.

**Acknowledge Signals (combinational):**
- portN_ack = (granted_port == N) && mem_ack

**Ready Signals (combinational):**
- port0_ready = !grant_active && mem_ready
- port1_ready = !grant_active && mem_ready && !port0_req
- port2_ready = !grant_active && mem_ready && !port0_req && !port1_req
- port3_ready = !grant_active && mem_ready && !port0_req && !port1_req && !port2_req

Each lower-priority port is only ready when no higher-priority port is requesting.

## Implementation

- `spi_gpu/src/memory/sram_arbiter.sv`: Main implementation (filename retained for compatibility; arbitrates SDRAM controller)

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
- Verify sequential grant: port issues burst_len=8, confirm 8 sequential 16-bit words transferred before ack (with CAS latency on reads)
- Verify sequential read data routing: burst_data_valid and burst_rdata appear only on the granted port
- Verify sequential write data requests: burst_wdata_req routed only to the granted port
- Verify sequential preemption: during port 3 sequential access, assert port 0 req; confirm access is cancelled (with PRECHARGE) and port 0 is served
- Verify preemption data integrity: preempted sequential access completes current 16-bit word and issues PRECHARGE before stopping
- Verify sequential completion: access completes naturally when no higher-priority port interrupts
- Verify burst_len=0 selects single-word mode (backward compatibility)
- Verify sequential + single-word interleaving: port 0 issues single-word requests while port 3 has a sequential access; confirm port 0 preempts
- Verify max burst preemption limits per port (16 words for port 1/3, 8 words for port 2)
- Verify auto-refresh preemption: mem_ready deasserts during refresh, arbiter blocks new grants until refresh completes
- Verify CAS latency: first read data arrives 3 cycles after READ command in sequential mode

## Design Notes

Migrated from speckit module specification.

**v2.0 unified clock update:** With the GPU core clock unified to 100 MHz (matching the SDRAM controller clock), the arbiter operates in a single clock domain.
Previously, if the GPU core ran at a different frequency than the memory, CDC synchronizers would have been required on the request/acknowledge handshake paths between requestors and the memory controller.
The unified 100 MHz clock eliminates this requirement entirely, reducing latency and simplifying timing analysis.
All four requestor ports (UNIT-008 display read, UNIT-006 framebuffer write, UNIT-006 Z-buffer read/write, UNIT-006 texture read for up to 2 samplers) are now synchronous to the same `clk_core` that drives the SDRAM controller.

**v3.0 SDRAM update:** The downstream interface connects to an SDRAM controller (W9825G6KH) instead of an async SRAM controller.
Key behavioral differences:
- SDRAM reads have higher latency (CAS latency CL=3 + row activation tRCD=2) compared to async SRAM (~2 cycles)
- Sequential access within an active row is efficient (1 word/cycle after CL), but row changes incur ~5 cycle overhead (PRECHARGE + ACTIVATE + tRCD)
- Auto-refresh interrupts normal access at a rate of ~1 per 781 cycles; the arbiter must tolerate mem_ready deassertion during refresh
- The arbiter interface (req/we/addr/wdata/rdata/ack/ready/burst) is preserved; the SDRAM controller internally manages row activation, CAS latency, precharge, and refresh

**v10.0 dual-texture + color combiner update:** Port 3 texture traffic now comes from at most 2 texture samplers (reduced from 4).
With 16K texels per sampler cache (4× larger than before), cache miss rates are substantially lower, reducing Port 3 bandwidth demands.
The arbiter architecture, priority scheme, and burst preemption logic are unchanged.
The max burst length for Port 3 (16 words) remains appropriate since individual cache fills are still 4-word (BC1) or 16-word (RGBA4444) bursts.
