//! W9825G6KH-6 timing constants at 100 MHz.

/// Row activation latency (tRCD) in clock cycles.
pub const T_RCD: i32 = 2;

/// CAS latency (CL) in clock cycles.
pub const CAS_LATENCY: i32 = 3;

/// PRECHARGE delay (tRP) in clock cycles.
pub const T_PRECHARGE: i32 = 2;

/// Minimum row active time (tRAS) in clock cycles.
pub const T_RAS: i32 = 5;

/// Row cycle time (tRC) in clock cycles.
pub const T_RC: i32 = 6;

/// Write recovery time (tWR) in clock cycles.
pub const T_WR: i32 = 2;

/// Mode register set delay (tMRD) in clock cycles.
pub const T_MRD: i32 = 2;

/// Auto-refresh interval in clock cycles.
/// 8192 refreshes per 64 ms at 100 MHz = 781.25 cycles per refresh.
pub const REFRESH_INTERVAL: i32 = 781;

/// Auto-refresh duration in clock cycles.
pub const REFRESH_DURATION: i32 = 6;

/// Total number of 16-bit words in 32 MB SDRAM.
pub const TOTAL_WORDS: u32 = 32 * 1024 * 1024 / 2;
