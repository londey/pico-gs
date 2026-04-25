# UNIT-011.05: L2 Compressed Cache

Status: Deleted.

This design unit has been removed as part of the INDEXED8_2X2 texture architecture (see UNIT-011).
The two-level (L1 decoded + L2 compressed) cache hierarchy has been replaced by a single-level half-resolution index cache (UNIT-011.03) backed directly by SDRAM.
Per-sampler SDRAM burst fills now go straight from SDRAM to the index cache with no intermediate compressed block store.
