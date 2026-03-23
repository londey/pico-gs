# INT-032: Texture Cache Architecture

## Status: Deprecated

This interface document is deprecated.
The texture cache architecture is now fully specified within UNIT-011 (Texture Sampler) and its subunits.

## Content Mapping

| Former INT-032 section | Authoritative location |
| ---------------------- | ---------------------- |
| L1 Decompressed Cache (PDPW16KD banks, UQ1.8 format, bilinear interleaving, XOR set indexing, pseudo-LRU replacement) | UNIT-011.03 |
| L2 Compressed Cache (DP16KD banks, format-aware packing, SDRAM burst fill) | UNIT-011.05 |
| Block Decompressor (BC1–BC5, RGB565, RGBA8888, R8 decoders; UQ1.8 conversion formulas; texel promotion UQ1.8→Q4.12) | UNIT-011.04 |
| Cache miss handling protocol, pipeline stall logic, cache invalidation on TEXn_CFG write | UNIT-011 |

## Parties

- **Provider:** UNIT-011 (Texture Sampler)
- **Consumer:** UNIT-006 (Pixel Pipeline — receives Q4.12 RGBA texel data from UNIT-011)
