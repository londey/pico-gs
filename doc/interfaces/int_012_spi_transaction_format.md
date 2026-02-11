# INT-012: SPI Transaction Format

## Type

Internal

## Parties

- **Provider:** External
- **Consumer:** UNIT-001 (SPI Slave Controller)
- **Consumer:** UNIT-022 (GPU Driver Layer)

## Referenced By

- REQ-001 (Basic Host Communication)
- REQ-020 (SPI Electrical Interface)
- REQ-121 (Async SPI Transmission)
- REQ-105 (GPU Communication Protocol)
- REQ-021 (Command Buffer FIFO)

## Specification


**Version**: 1.0  
**Date**: January 2026

---

## Electrical Interface

| Parameter | Value |
|-----------|-------|
| SPI Mode | 0 (CPOL=0, CPHA=0) |
| Chip Select | Active low |
| Bit Order | MSB first |
| Maximum Clock | 40 MHz |
| Voltage Levels | 3.3V LVCMOS |

**Signal Descriptions**:

| Signal | Direction | Description |
|--------|-----------|-------------|
| SCK | Host → GPU | Serial clock |
| MOSI | Host → GPU | Master Out, Slave In (data to GPU) |
| MISO | GPU → Host | Master In, Slave Out (data from GPU) |
| CS̄ | Host → GPU | Chip select, active low |

---

## Transaction Format

All transactions are exactly **72 bits** (9 bytes).

```
Bit:    71  70-64    63-0
       ┌───┬───────┬─────────────────────────────────────┐
       │R/W│ ADDR  │              DATA                   │
       └───┴───────┴─────────────────────────────────────┘
         1    7                    64 bits
```

| Field | Bits | Description |
|-------|------|-------------|
| R/W̄ | 71 | 1 = Read, 0 = Write |
| ADDR | 70:64 | 7-bit register address (0x00 - 0x7F) |
| DATA | 63:0 | 64-bit register value |

---

## Timing Diagram

### Write Transaction

```
CS̄     ────┐                                              ┌────
           └──────────────────────────────────────────────┘
           
SCK    ────────┐  ┐  ┐  ┐  ┐  ┐  ┐  ┐     ┐  ┐  ┐  ┐  ────
               └──┘  └──┘  └──┘  └──┘ ... └──┘  └──┘  └──
               
MOSI   ────────╳──╳──╳──╳──╳──╳──╳──╳     ╳──╳──╳──╳──────
           W  │A6│A5│A4│A3│A2│A1│A0│ ... │D1│D0│
           
MISO   ────────────────────────────── ... ─────────────────
           (ignored during write)
           
            │←──────── 72 SCK cycles ────────→│
```

**Sequence**:
1. Host asserts CS̄ low
2. Host clocks out 72 bits on MOSI (MSB first)
   - Bit 71: 0 (write)
   - Bits 70-64: Register address
   - Bits 63-0: Data value
3. Host deasserts CS̄ high
4. GPU latches command on CS̄ rising edge

### Read Transaction

```
CS̄     ────┐                                              ┌────
           └──────────────────────────────────────────────┘
           
SCK    ────────┐  ┐  ┐  ┐  ┐  ┐  ┐  ┐     ┐  ┐  ┐  ┐  ────
               └──┘  └──┘  └──┘  └──┘ ... └──┘  └──┘  └──
               
MOSI   ────────╳──╳──╳──╳──╳──╳──╳──╳─────────────────────
           R  │A6│A5│A4│A3│A2│A1│A0│ (don't care)
           
MISO   ────────────────────────────╳──╳  ╳──╳──╳──╳──────
                                  │D63│...│D1│D0│
           
            │← 8 bits →│←──── 64 bits data ────→│
```

**Sequence**:
1. Host asserts CS̄ low
2. Host clocks out 8 bits (R/W + address)
   - Bit 71: 1 (read)
   - Bits 70-64: Register address
3. GPU drives MISO with register data starting at bit 63
4. Host clocks in 64 bits of data
5. Host deasserts CS̄ high

**Note**: During read, host may clock out any value on MOSI for the data bits (typically 0x00).

---

## GPIO Signals

Three auxiliary GPIO signals provide asynchronous status from GPU to host.

| Signal | Active | Description |
|--------|--------|-------------|
| CMD_FULL | High | Command FIFO almost full (≤2 slots free) |
| CMD_EMPTY | High | Command FIFO empty |
| VSYNC | Pulse | Vertical sync (one clk_50 cycle at frame start) |

### CMD_FULL Timing

```
                    FIFO fills
                        │
CMD_FULL  ──────────────┘ ┌──────────────────────┐
                          │  HOST SHOULD PAUSE   │
                          └──────────────────────┘
                                                  │
                                              FIFO drains
```

**Behavior**:
- Asserts when FIFO has ≤2 free slots
- 2-slot slack allows host to complete in-flight SPI transaction
- Host should poll this before starting new write
- Deasserts when FIFO depth drops below threshold

### CMD_EMPTY Timing

```
                    Last command completes
                              │
CMD_EMPTY ────────────────────┘ ┌────────────────
                                │  SAFE TO READ  
                                └────────────────
                                │
                            New write arrives
                                │
CMD_EMPTY ──────────────────────┘
```

**Behavior**:
- Asserts when FIFO is completely empty AND no command executing
- Safe to read STATUS or other registers when asserted
- Reading during GPU activity may return stale/inconsistent data

### VSYNC Timing

```
                Frame N              Frame N+1
            ─────────────────────┬─────────────────────
                                 │
VSYNC      ─────────────────────┐│┌─────────────────────
                                 └┘
                                 │
                          ~20 clk_50 cycles
```

**Behavior**:
- Pulses high for ~20 clk_50 cycles (~400 ns)
- Rising edge aligned with start of vertical blanking
- Use for double-buffer swap synchronization
- 60 Hz rate (every 16.67 ms)

---

## Command Queueing

Write transactions are queued in an internal FIFO for asynchronous execution.

### FIFO Behavior

| Parameter | Value |
|-----------|-------|
| Depth | 16 commands |
| Width | 71 bits (addr + data, R/W not stored) |
| Almost Full | Depth ≥ 14 |

**Write Flow**:
```
SPI Transaction → CDC Sync → FIFO Write → Command Execute
    (spi_sck)    (async)    (clk_50)      (clk_50)
```

**Overflow Protection**:
- If host writes when FIFO is full, command is dropped
- GPU does not NAK or signal error (SPI is unidirectional for writes)
- Host must monitor CMD_FULL to prevent overflow

### Execution Order

Commands execute in strict FIFO order:

```
Write COLOR (queued)
Write UV (queued)
Write VERTEX (queued, triggers triangle when processed)
```

Triangle rasterization begins when VERTEX command with vertex_count=2 is processed.

---

## Clock Domain Crossing

The SPI interface operates in a separate clock domain from the GPU core.

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────┐
│   SPI Slave     │     │   Async FIFO     │     │  GPU Core   │
│   (spi_sck)     │────▶│  (gray-coded)    │────▶│  (clk_50)   │
└─────────────────┘     └──────────────────┘     └─────────────┘
```

**Synchronization**:
- Write pointer synchronized to clk_50 with 2-FF synchronizer
- Read pointer synchronized to spi_sck domain (for full detection)
- Metastability resolved within 2 clock cycles

**Latency**:
- SPI transaction end (CS̄ rising) to command visible: ~4 clk_50 cycles
- Total latency from start of SPI to command execution: ~100 clk_50 cycles max

---

## Read Timing Constraints

**When to Read**:
- STATUS register may be read any time (but data may be in flux)
- For consistent STATUS read, wait for CMD_EMPTY
- ID register is constant, can be read any time

**Read During Write**:
- If host initiates read while write FIFO is being processed, data is from register file at that instant
- Reading vertex state (COLOR, UV) returns last latched value, may not be meaningful

**Recommended Pattern**:
```c
// Wait for GPU idle before reading status
while (!(GPIO_IN & GPIO_CMD_EMPTY));
uint64_t status = gpu_read(REG_STATUS);
```

---

## Error Handling

The GPU has minimal error reporting. Host is responsible for correct usage.

| Condition | GPU Behavior |
|-----------|--------------|
| Write to read-only register | Ignored |
| Read from write-only register | Returns 0 |
| Write when FIFO full | Command dropped |
| Invalid register address | Ignored (write), returns 0 (read) |
| Malformed SPI (wrong bit count) | Undefined, likely ignored |

**Robustness Recommendations**:
1. Always check CMD_FULL before write burst
2. Check ID register on init to confirm GPU presence
3. Use VSYNC for frame timing, not polling STATUS
4. Reset GPU (via separate GPIO or power cycle) if in unknown state

---

## Host Implementation Notes

### RP2350 SPI Configuration

```c
// Initialize SPI at 25 MHz
spi_init(spi0, 25 * 1000 * 1000);
spi_set_format(spi0, 8, SPI_CPOL_0, SPI_CPHA_0, SPI_MSB_FIRST);

// Configure pins
gpio_set_function(PIN_SCK, GPIO_FUNC_SPI);
gpio_set_function(PIN_MOSI, GPIO_FUNC_SPI);
gpio_set_function(PIN_MISO, GPIO_FUNC_SPI);
gpio_init(PIN_CS);
gpio_set_dir(PIN_CS, GPIO_OUT);
gpio_put(PIN_CS, 1);  // Deassert

// GPIO inputs for status
gpio_init(PIN_CMD_FULL);
gpio_set_dir(PIN_CMD_FULL, GPIO_IN);
gpio_init(PIN_CMD_EMPTY);
gpio_set_dir(PIN_CMD_EMPTY, GPIO_IN);
gpio_init(PIN_VSYNC);
gpio_set_dir(PIN_VSYNC, GPIO_IN);
```

### Write Function

```c
void gpu_write(uint8_t addr, uint64_t data) {
    uint8_t buf[9];
    
    // Pack: R/W=0 (write), 7-bit addr, 64-bit data
    buf[0] = (addr & 0x7F);  // Bit 7 = 0 for write
    buf[1] = (data >> 56) & 0xFF;
    buf[2] = (data >> 48) & 0xFF;
    buf[3] = (data >> 40) & 0xFF;
    buf[4] = (data >> 32) & 0xFF;
    buf[5] = (data >> 24) & 0xFF;
    buf[6] = (data >> 16) & 0xFF;
    buf[7] = (data >> 8) & 0xFF;
    buf[8] = data & 0xFF;
    
    gpio_put(PIN_CS, 0);
    spi_write_blocking(spi0, buf, 9);
    gpio_put(PIN_CS, 1);
}
```

### Read Function

```c
uint64_t gpu_read(uint8_t addr) {
    uint8_t tx[9] = {0};
    uint8_t rx[9] = {0};
    
    tx[0] = 0x80 | (addr & 0x7F);  // Bit 7 = 1 for read
    
    gpio_put(PIN_CS, 0);
    spi_write_read_blocking(spi0, tx, rx, 9);
    gpio_put(PIN_CS, 1);
    
    // Data is in rx[1..8]
    uint64_t data = 0;
    for (int i = 1; i < 9; i++) {
        data = (data << 8) | rx[i];
    }
    return data;
}
```

### Burst Write with Flow Control

```c
void gpu_write_burst(gpu_cmd_t *cmds, int count) {
    for (int i = 0; i < count; i++) {
        // Check for FIFO space
        while (gpio_get(PIN_CMD_FULL)) {
            tight_loop_contents();  // Spin wait
        }
        gpu_write(cmds[i].addr, cmds[i].data);
    }
}
```

---

## Electrical Timing

### SPI Timing (at 25 MHz)

| Parameter | Min | Typ | Max | Unit |
|-----------|-----|-----|-----|------|
| SCK period | 40 | - | - | ns |
| CS̄ setup to SCK | 10 | - | - | ns |
| CS̄ hold after SCK | 10 | - | - | ns |
| MOSI setup to SCK↑ | 5 | - | - | ns |
| MOSI hold after SCK↑ | 5 | - | - | ns |
| SCK↑ to MISO valid | - | - | 15 | ns |

### GPIO Timing

| Parameter | Value | Unit |
|-----------|-------|------|
| CMD_FULL/EMPTY update latency | ≤100 | ns |
| VSYNC pulse width | ~400 | ns |
| VSYNC period | 16.67 | ms |


## Constraints

See specification details above.

## Notes

Migrated from speckit contract: specs/001-spi-gpu/contracts/spi-protocol.md
