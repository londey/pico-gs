# FTDI 245 FIFO Mode vs SPI Variants for GPU Register Commands

## Technical Report: Interface Throughput and Implementation Feasibility

---

## Project Context

The pico-gs project is a hobby 3D GPU where a host controller sends register write commands to a Lattice ECP5-25K FPGA (ICEpi Zero v1.3 board).
Each command consists of a 72-bit transaction: 1 bit R/W + 7 bits address + 64 bits data = 72 bits (9 bytes).
The current FPGA implementation (`/workspaces/pico-gs/spi_gpu/src/spi/spi_slave.sv`) is a standard SPI Mode 0 slave that shifts in 72 bits serially.

Two host controllers must be supported:
- **RP2350** (Raspberry Pi Pico 2): dual Cortex-M33 at 150 MHz, production target
- **FT232H** (PC via USB): debug/development path

The ICEpi Zero v1.3 GPIO header provides 28 GPIOs (gpio[0]--gpio[27]) at LVCMOS33 3.3V levels, as defined in `/workspaces/pico-gs/external/icepi-zero/firmware/v1.3/icepi-zero-v1_3.lpf`.

---

## 1. FTDI FT232H Synchronous 245 FIFO Mode

### 1.1 How It Works

The FT232H synchronous 245 FIFO mode provides a parallel byte-wide interface between a USB 2.0 High-Speed host (PC) and an FPGA.
The FT232H generates a 60 MHz clock (CLKOUT) that the FPGA uses to synchronize all data transfers.
Data is transferred one byte at a time on rising edges of CLKOUT.

**Write (PC to FPGA):** The FPGA checks that TXE# is low (meaning the FT232H TX buffer has space), then asserts WR# low while driving data on D[7:0].
On the next rising edge of CLKOUT, the byte is captured by the FT232H and forwarded to the FPGA-side read buffer.

**Read (FPGA to PC):** The FPGA checks that RXF# is low (meaning data is available), asserts OE# low for one clock cycle to enable the FT232H data bus drivers, then asserts RD# low.
Data appears on D[7:0] on the next CLKOUT rising edge.

### 1.2 Pin Requirements

| Signal   | Direction (FPGA perspective) | Function                                    |
|----------|------------------------------|---------------------------------------------|
| D[7:0]   | Bidirectional                | 8-bit parallel data bus                     |
| CLKOUT   | Input (from FT232H)         | 60 MHz clock                                |
| RXF#     | Input (from FT232H)         | Low = data available to read                |
| TXE#     | Input (from FT232H)         | Low = space available to write              |
| RD#      | Output (from FPGA)          | Assert low to read data                     |
| WR#      | Output (from FPGA)          | Assert low to write data                    |
| OE#      | Output (from FPGA)          | Assert low to enable data bus (read path)   |
| SIWU#    | Output (from FPGA)          | Send Immediate / Wake Up (can tie high)     |

**Total: 14 pins minimum** (8 data + CLKOUT + RXF# + TXE# + RD# + WR# + OE#).
SIWU# can be tied high if not needed, bringing it to 13 active pins.

### 1.3 Throughput Calculations

- **Raw bus throughput:** 60 MHz x 1 byte = **60 MB/s** (bus-side theoretical)
- **USB 2.0 bottleneck:** The FT232H datasheet specifies up to **40 MB/s** sustained throughput; real-world measurements typically achieve **35--40 MB/s** due to USB protocol overhead, microframe scheduling, and buffer management.
- **Register writes/second (bus-limited):** 9 bytes per transaction: 60,000,000 / 9 = **6.67 million register writes/sec** (bus theoretical)
- **Register writes/second (USB-limited):** 40,000,000 / 9 = **4.44 million register writes/sec** (practical peak)
- **Register writes/second (realistic):** 35,000,000 / 9 = **3.89 million register writes/sec**

### 1.4 ECP5 Implementation

On the FPGA side, this is one of the simplest interfaces to implement: a clocked parallel read/write with handshake signals.
The FPGA simply uses CLKOUT as a clock, samples TXE#/RXF#, and drives WR#/RD#/OE# plus the data bus.
This requires minimal logic -- essentially a small state machine (4--6 states) and a byte counter.
Estimated cost: ~50--100 LUTs.

### 1.5 Key Limitation

The FT232H in 245 FIFO mode requires **14 GPIO pins** on the ICEpi Zero header.
This is half of the 28 available GPIOs.
Furthermore, 245 FIFO mode is mutually exclusive with MPSSE/SPI mode on the FT232H -- you cannot use the same FT232H chip for both SPI and FIFO simultaneously.

---

## 2. SPI Variants Throughput Comparison

### 2.1 Standard SPI (1-bit, single data line)

**Transaction size:** 72 bits per register write (72 clock cycles per transaction).

| Clock Source     | SPI Clock  | Throughput (MB/s) | Reg Writes/sec |
|-----------------|------------|-------------------|----------------|
| RP2350 HW SPI   | 62.5 MHz   | 7.81              | 868,055        |
| RP2350 HW SPI   | 50 MHz     | 6.25              | 694,444        |
| RP2350 PIO SPI  | 25 MHz     | 3.13              | 347,222        |
| FT232H MPSSE    | 30 MHz     | 3.75              | 416,666        |

**Notes:**
- The RP2350 hardware SPI peripheral (ARM PL022 SSP) can theoretically run at clk_peri / 2 = 75 MHz, but practical board-level constraints (wire length, GPIO slew, FPGA input setup time at LVCMOS33) limit this.
  A conservative estimate is 50--62.5 MHz for reliable operation.
- PIO-based SPI on the RP2350 is limited to approximately 25 MHz maximum due to the 2-flipflop input synchronizer on GPIO inputs adding ~13 ns of latency.
- FT232H MPSSE mode SPI tops out at 30 MHz.

### 2.2 Dual SPI (2-bit)

Two data lines (MOSI + MISO used as bidirectional data).
72 bits / 2 bits per clock = **36 clock cycles per transaction**.

| Clock Source    | SPI Clock | Throughput (MB/s) | Reg Writes/sec |
|----------------|-----------|-------------------|----------------|
| RP2350 PIO     | 25 MHz    | 6.25              | 694,444        |
| RP2350 PIO     | 37.5 MHz  | 9.38              | 1,041,666      |

**Pins needed:** 4 (CLK + CS + D0 + D1) + 1 flow control = 5.

**Note:** Dual SPI is not natively supported by the FT232H MPSSE.
It would require the FPGA to treat MOSI and MISO as two write-direction data lines (not standard SPI), making it a custom protocol.
The MISO line direction changes between write and read phases.

### 2.3 Quad SPI (4-bit)

Four data lines.
72 bits / 4 bits per clock = **18 clock cycles per transaction**.

| Clock Source    | SPI Clock | Throughput (MB/s) | Reg Writes/sec |
|----------------|-----------|-------------------|----------------|
| RP2350 PIO     | 25 MHz    | 12.5              | 1,388,888      |
| RP2350 PIO     | 37.5 MHz  | 18.75             | 2,083,333      |

**Pins needed:** 7 (CLK + CS + D0 + D1 + D2 + D3 + flow control IRQ).

### 2.4 Octal SPI / 8-bit Parallel (8-bit)

Eight data lines.
72 bits / 8 bits per clock = **9 clock cycles per transaction**.

| Clock Source    | SPI Clock | Throughput (MB/s) | Reg Writes/sec |
|----------------|-----------|-------------------|----------------|
| RP2350 PIO     | 25 MHz    | 25.0              | 2,777,777      |
| RP2350 PIO     | 37.5 MHz  | 37.5              | 4,166,666      |
| RP2350 PIO     | 50 MHz    | 50.0              | 5,555,555      |

**Pins needed:** 11 (CLK + CS + D0--D7 + flow control IRQ).

---

## 3. RP2350 Implementation Feasibility

### 3.1 Standard SPI (Hardware Peripheral)

**Complexity: Trivial.**

The RP2350 has two hardware SPI peripherals (SPI0, SPI1) based on the ARM PL022.
These support master mode with DMA, 4--16 bit frame sizes, and clock rates up to clk_peri/2.
At the default 150 MHz system clock, the SPI peripheral clock is typically 150 MHz, yielding a maximum SPI clock of 75 MHz (divider = 2).
In practice, 50--62.5 MHz is achievable for reliable board-level signaling.

The PL022 supports 8-bit and 16-bit frame sizes, so a 9-byte transaction can be sent as nine 8-bit transfers or a mix of 16-bit and 8-bit.
DMA can be used to send the 9 bytes with zero CPU overhead.

This is the current design in `/workspaces/pico-gs/crates/pico-gs-hal/src/lib.rs` (the `SpiTransport` trait).

### 3.2 Quad SPI via PIO

**Complexity: Moderate (1--2 PIO state machines).**

The RP2350 has 12 PIO state machines across 3 PIO blocks (PIO0, PIO1, PIO2), each with 4 state machines.
A QSPI transmitter can be implemented in a single PIO state machine:

```
; PIO QSPI TX - output 4 bits per clock cycle
.side_set 1
.wrap_target
    out pins, 4  side 0   ; Output 4 data bits, CLK low
    nop          side 1   ; CLK high (data sampled by FPGA)
.wrap
```

This uses 2 instructions per nibble, running at system clock / 2 = 75 MHz PIO clock cycles.
With side-set generating the SPI clock, each nibble takes 2 PIO cycles, yielding an effective SPI clock of 37.5 MHz (at 150 MHz system clock).
Output-only mode avoids the input synchronizer penalty.

**DMA compatibility:** Excellent.
The PIO TX FIFO accepts 32-bit words from DMA.
A 72-bit transaction can be packed into three 32-bit DMA words (with 24 bits of padding), or two 32-bit words plus one partial.

**Pin assignment:** 4 contiguous GPIO pins for data (D0--D3), 1 side-set pin for CLK, plus CS managed by a second state machine or software.
Total: 6 GPIOs + 1 for flow control = 7.

### 3.3 Octal SPI / 8-bit Parallel via PIO

**Complexity: Moderate (1 PIO state machine).**

Very similar to QSPI but wider:

```
; PIO 8-bit parallel TX
.side_set 1
.wrap_target
    out pins, 8  side 0   ; Output 8 data bits, CLK low
    nop          side 1   ; CLK high (data sampled by FPGA)
.wrap
```

Same 2-instruction loop.
At 150 MHz system clock, effective parallel clock = 37.5 MHz.
Each clock transfers 1 byte, so 9 clocks per register write.

**DMA compatibility:** Excellent.
32-bit DMA words are autopulled into the OSR, then shifted out 8 bits at a time.

**Pin requirement:** 8 contiguous GPIOs for data + 1 side-set for CLK + CS + flow control = **11 pins**.

**Consideration:** The RP2350 requires that `out pins` targets a contiguous range of GPIOs.
The ICEpi Zero header has gpios spread across non-contiguous ball positions, but they are logically numbered gpio[0]--gpio[27], so selecting 8 contiguous logical GPIOs (e.g., gpio[0]--gpio[7]) is feasible.

### 3.4 FTDI 245-Style Parallel FIFO via PIO

**Complexity: High (2--3 PIO state machines).**

Implementing the FT232H synchronous 245 FIFO protocol on the RP2350 PIO is technically possible but significantly more complex:

- **State machine 1:** Data output -- drives 8-bit data bus and WR# signal, synchronized to an externally provided or self-generated clock.
- **State machine 2:** Handshake monitoring -- polls TXE# and gates writes when the FIFO is full.
- **State machine 3 (optional):** Read path with OE# and RD# sequencing.

The complication is that the 245 protocol is a *handshaked* bus, not a streaming protocol.
The PIO must check TXE# before each write and stall if the buffer is full.
PIO state machines can do conditional branching (`jmp pin`), but the logic becomes more intricate than simple SPI.
The 2-flipflop input synchronizer latency also applies to TXE# sensing.

**DMA compatibility:** Partial.
DMA can feed the TX FIFO, but the PIO must handle flow control stalls, which may cause the DMA to block unpredictably.

**Pin requirement:** 14 pins (same as the FT232H 245 interface).

**Verdict:** This is over-engineered for the RP2350 use case.
The RP2350 can achieve comparable or better throughput with 8-bit parallel SPI using fewer pins, simpler logic, and better DMA integration.

---

## 4. ECP5 Implementation Feasibility

### 4.1 Standard SPI Slave

**Complexity: Low--Moderate. LUT cost: ~100--150 LUTs.**

This is already implemented in the project at `/workspaces/pico-gs/spi_gpu/src/spi/spi_slave.sv`.
The module uses a 72-bit shift register, a 7-bit counter, and a 2FF CDC synchronizer.
The design handles:
- Bit-by-bit shifting on SPI clock rising edge
- 72-bit transaction framing via CS# assertion
- Clock domain crossing from SPI clock domain to 100 MHz system clock
- Read data output on SPI clock falling edge

### 4.2 Quad SPI Slave

**Complexity: Low--Moderate. LUT cost: ~120--180 LUTs.**

The changes from standard SPI are minimal:
- The shift register shifts 4 bits per clock instead of 1: `shift_reg <= {shift_reg[67:0], qspi_data[3:0]}`
- The bit counter increments by 4 instead of 1
- Transaction completion at bit_count == 18 (72/4) instead of 72
- 4 input pins instead of 1 MOSI

The CDC logic remains identical.
The only additional complexity is managing the bidirectional data pins if read support is needed (tristate control).

### 4.3 Octal SPI / 8-bit Parallel Slave

**Complexity: Low--Moderate. LUT cost: ~130--200 LUTs.**

Same structure as QSPI but 8 bits wide:
- `shift_reg <= {shift_reg[63:0], data_in[7:0]}`
- Transaction completion at bit_count == 9 (72/8)
- 8 input data pins

Slightly larger due to wider input muxing, but fundamentally the same design pattern.
The ECP5-25K has 24K LUTs, so even 200 LUTs is less than 1% of the device.

### 4.4 245 FIFO Slave (Parallel with Handshake)

**Complexity: Low. LUT cost: ~80--120 LUTs.**

Ironically simpler than SPI in some ways because there is no bit-level shifting -- data arrives byte-aligned:
- Small state machine: IDLE -> CHECK_TXE -> LATCH_BYTE -> (repeat 9 times) -> TRANSACTION_COMPLETE
- 9-byte accumulation register (72 bits)
- Byte counter (0--8)
- TXE#/RXF# generation based on internal FIFO fullness

However, the 60 MHz CLKOUT clock must be handled as a separate clock domain, requiring an async FIFO or CDC between the FIFO clock domain and the GPU core clock domain.
The existing `async_fifo` module at `/workspaces/pico-gs/spi_gpu/src/utils/async_fifo.sv` could be reused.

### 4.5 ECP5 LVCMOS33 Frequency Limits

Per the ECP5 Family Data Sheet (FPGA-DS-02012), the maximum I/O toggle rate for LVCMOS33 generic I/O is approximately **133 MHz** for outputs and the input setup/hold times support clock rates well above 60 MHz for properly constrained designs.
At 3.3V LVCMOS33, 60--75 MHz input clocking is well within specification.
The GPIO header traces on the ICEpi Zero may introduce additional routing delays, but for frequencies under 100 MHz this is generally not a concern with reasonable PCB layout.

---

## 5. Summary Comparison Table

| Interface          | Data Pins | Total Pins | Max Clock | Raw Throughput | Reg Writes/sec    | RP2350 Complexity | ECP5 Complexity | FT232H Support |
|--------------------|-----------|------------|-----------|----------------|-------------------|-------------------|-----------------|----------------|
| Standard SPI (1b)  | 1 (MOSI)  | 5          | 62.5 MHz  | 7.81 MB/s      | 868K              | Trivial (HW SPI)  | Low (existing)  | Yes (30 MHz)   |
| Dual SPI (2b)      | 2         | 5          | 37.5 MHz  | 9.38 MB/s      | 1.04M             | Low (PIO)          | Low             | No             |
| Quad SPI (4b)      | 4         | 7          | 37.5 MHz  | 18.75 MB/s     | 2.08M             | Moderate (PIO)     | Low--Moderate   | No             |
| Octal SPI (8b)     | 8         | 11         | 37.5 MHz  | 37.5 MB/s      | 4.17M             | Moderate (PIO)     | Low--Moderate   | No             |
| 245 FIFO (8b)      | 8         | 14         | 60 MHz    | 60 MB/s (bus)  | 4.44M (USB-ltd)   | High (PIO)         | Low             | Yes (native)   |
| FT232H MPSSE SPI   | 1 (MOSI)  | 5          | 30 MHz    | 3.75 MB/s      | 417K              | N/A (PC host)      | Low (existing)  | Yes (native)   |

**Notes on the table:**
- "Total Pins" includes CLK, CS, data lines, and 1 flow control/IRQ line.
- RP2350 PIO clock rates assume 150 MHz system clock with a 2-instruction output loop (effective SPI clock = sys_clk / 4 = 37.5 MHz).
  With optimized PIO programs or overclocking to 200 MHz, higher rates are achievable.
- 245 FIFO throughput is USB 2.0 limited to ~40 MB/s from the PC side; the bus itself runs at 60 MB/s.
- All ECP5 implementations are well within the LVCMOS33 frequency specifications of the device.

---

## 6. Recommendation

### Primary Recommendation: Standard SPI with upgrade path to Quad SPI

**Phase 1 (Current): Standard SPI -- keep the existing implementation.**

- Works today with both FT232H (MPSSE at 30 MHz) and RP2350 (hardware SPI at 50--62.5 MHz).
- Uses only 5 GPIO pins, leaving 23 for other purposes.
- At 62.5 MHz on RP2350, delivers ~868K register writes/sec, which for a hobby GPU rendering at 60 fps gives ~14,400 register writes per frame.
  For typical 3D scenes with hundreds of triangles and register updates, this is likely sufficient.
- Zero additional development effort -- the SPI slave already exists in `/workspaces/pico-gs/spi_gpu/src/spi/spi_slave.sv`.

**Phase 2 (If bandwidth becomes a bottleneck): Quad SPI via PIO.**

- Adds 2 more data pins (reusing MISO + 2 additional GPIOs), bringing total to 7 pins.
- Delivers ~2.08M register writes/sec (2.4x improvement over standard SPI), or ~34,700 writes per frame at 60 fps.
- Moderate PIO development effort: a single state machine with ~4 instructions.
- The ECP5 slave modification is straightforward: widen the shift register input from 1 to 4 bits.
- **Not compatible with FT232H MPSSE**, but the FT232H debug path can remain on standard SPI using the same physical pins (D0 as MOSI, D1 as MISO in SPI mode; D0--D3 as quad data in QSPI mode).
  The FPGA can auto-detect the mode based on a configuration register or CS protocol.

### Why NOT 245 FIFO Mode

- Consumes 14 of 28 GPIO pins -- too expensive for a board that also needs flow control, LEDs, and potentially other peripherals.
- The RP2350 cannot natively speak 245 FIFO protocol.
  Implementing it in PIO is significantly more complex than parallel SPI due to handshaking requirements.
- The throughput advantage over 8-bit parallel SPI is marginal (4.44M vs 4.17M reg writes/sec) and the USB 2.0 bottleneck means the FT232H path never actually reaches the bus-speed advantage.
- Locks the FT232H into FIFO mode, preventing use of MPSSE for other debug functions (I2C, JTAG, GPIO bit-bang).

### Why NOT Octal SPI

- Uses 11 pins -- feasible but significantly more than quad SPI.
- The throughput gain from quad to octal (2.08M -> 4.17M) is unlikely to be needed for a hobby GPU where the bottleneck is likely rasterization and memory bandwidth, not command delivery.
- Adds complexity on both sides for diminishing returns.

### Dual-Host Strategy

The recommended approach for supporting both FT232H and RP2350 on the same FPGA design:

1. **Standard SPI slave** remains the universal interface -- both hosts speak it natively.
2. **QSPI mode** is an optional enhancement activated by the RP2350 when higher throughput is needed.
   The FPGA can detect QSPI mode by observing activity on D2/D3 during a special configuration handshake, or the host can write a mode-select register via standard SPI first.
3. Both modes share the same physical pins: SCLK (gpio[11]), CS (gpio[8]), D0/MOSI (gpio[10]), D1/MISO (gpio[9]), plus D2 (gpio[24]) and D3 (gpio[23]) for QSPI.
   The flow control IRQ remains on gpio[25] (pi_nirq).

This approach uses at most 7 GPIOs, works with both hosts, scales throughput 2.4x when needed, and keeps the FPGA implementation simple.

---

## Sources

- [FT232H Datasheet (FTDI, September 2024)](https://ftdichip.com/wp-content/uploads/2024/09/DS_FT232H.pdf)
- [AN_130: FT2232H Used in FT245 Synchronous FIFO Mode](https://ftdichip.com/wp-content/uploads/2020/08/AN_130_FT2232H_Used_In_FT245-Synchronous-FIFO-Mode.pdf)
- [TN_167: FIFO Basics (USB 2.0)](https://ftdichip.com/Support/Documents/TechnicalNotes/TN_167_FIFO_Basics.pdf)
- [AN_135: FTDI MPSSE Basics](https://www.ftdichip.com/Documents/AppNotes/AN_135_MPSSE_Basics.pdf)
- [RP2350 Datasheet (Raspberry Pi)](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf)
- [RP2350 PIO SPI Speed Limitations (Raspberry Pi Forums)](https://forums.raspberrypi.com/viewtopic.php?t=377694)
- [RP2350 PIO DMA Performance (Raspberry Pi Forums)](https://forums.raspberrypi.com/viewtopic.php?t=375095)
- [What is the RP2350 HSTX Interface? (DigiKey)](https://www.digikey.com/en/maker/tutorials/2025/what-is-the-rp2350-high-speed-transmit-interface-hstx)
- [A Deep Dive Into PIO and DMA on the RP2350 (Hackaday)](https://hackaday.com/2025/11/30/a-deep-dive-into-using-pio-and-dma-on-the-rp2350/)
- [RP2350 HSTX Close-Up (CNX Software)](https://www.cnx-software.com/2024/08/15/raspberry-pi-rp2350-hstx-high-speed-serial-transmit-interface/)
- [ECP5/ECP5-5G Family Data Sheet FPGA-DS-02012 (Lattice Semiconductor)](https://static6.arrow.com/aropdfconversion/2beddaa15206c0bf1b59c250d0a95b9c979f950f/fpga-ds-02012-3-2-ecp5-ecp5g-family-data-sheet.pdf)
- [ECP5 sysIO Usage Guide TN-02032 (Lattice Semiconductor)](https://www.latticesemi.com/-/media/LatticeSemi/Documents/ApplicationNotes/EH/FPGA-TN-02032-1-4-ECP5-ECP5G-sysIO-Usage-Guide.ashx?document_id=50464)
- [Pyroteknix: Fast USB with FTDI FT232H](https://pyroteknix.com/?p=359)
- [FTDI Synchronous FIFO Interfacing with Numato FPGA Boards](https://numato.com/kb/ftdi-synchronous-fifo-interfacing-with-styx-2/)
