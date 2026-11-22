#ifndef ISCSI_CCRC32C_H
#define ISCSI_CCRC32C_H

#include <stddef.h>
#include <stdint.h>

/// CRC-32C (Castagnoli, reflected, poly 0x82F63B78) over `len` bytes.
///
/// Takes and returns the *running* CRC with no initial or final XOR, so calls
/// chain: start from 0xFFFFFFFF and XOR the result with 0xFFFFFFFF at the end.
/// That is what lets a digest be computed across several buffers without
/// copying them into one.
///
/// Uses the CRC32C instruction on arm64 and x86-64 (SSE4.2), falling back to a
/// portable slice-by-8 table elsewhere. On arm64 with PMULL, buffers of 192
/// bytes and more run three instruction chains at once and fold them
/// together. All of these produce identical values; the RFC 7143 golden
/// vectors and the reference comparison in CRC32CTests cover this.
uint32_t iscsi_crc32c(uint32_t crc, const void *data, size_t len);

#endif /* ISCSI_CCRC32C_H */
