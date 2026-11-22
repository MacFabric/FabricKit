#include "include/ccrc32c.h"

#include <string.h>

/*
 * The digest covers every byte on the wire in both directions, so this sits
 * in the throughput path. Apple silicon and SSE4.2 x86-64 have a CRC32C
 * instruction; the table fallback remains for other hardware and is checked
 * by the same golden vectors.
 */

#if defined(__aarch64__)
#define ISCSI_CRC32C_HW 1
#if defined(__ARM_FEATURE_AES)
/* Carry-less multiply (PMULL) is there too: three streams at once, below. */
#define ISCSI_CRC32C_FOLD 1
#include <arm_neon.h>
#endif
#elif defined(__x86_64__) && defined(__SSE4_2__)
#define ISCSI_CRC32C_HW 1
#include <nmmintrin.h>
#else
#define ISCSI_CRC32C_HW 0
#endif

#if !ISCSI_CRC32C_HW
/* Slice-by-8 tables, built once on first use. Still far better than
 * byte-at-a-time, and only reached on hardware without the instruction. */
static uint32_t g_table[8][256];
static int g_table_ready = 0;

static void build_table(void) {
    for (unsigned i = 0; i < 256; i++) {
        uint32_t crc = i;
        for (int k = 0; k < 8; k++)
            crc = (crc & 1) ? (crc >> 1) ^ 0x82F63B78u : (crc >> 1);
        g_table[0][i] = crc;
    }
    for (unsigned i = 0; i < 256; i++) {
        uint32_t crc = g_table[0][i];
        for (int j = 1; j < 8; j++) {
            crc = g_table[0][crc & 0xFF] ^ (crc >> 8);
            g_table[j][i] = crc;
        }
    }
    g_table_ready = 1;
}
#endif

#if defined(ISCSI_CRC32C_FOLD)
/*
 * Three streams at once.
 *
 * The CRC32C instruction has a three-cycle latency and the next one needs its
 * result, so a single chain runs at a third of what the core can issue. Three
 * independent chains over three adjacent blocks of N bytes fill that gap: A
 * continues the running CRC, B and C start from zero. They are then joined.
 *
 * Joining: a CRC state is a polynomial mod P, and running it over n more
 * bytes of zeros multiplies it by x^(8n). So the state after A, B, C is
 *
 *     A * x^(16N)  +  B * x^(8N)  +  C        (mod P)
 *
 * A carry-less multiply of two 32-bit values in this bit order yields their
 * product times x, and reducing those 64 bits with the CRC32C instruction
 * (from a zero state) multiplies by another x^32. So multiplying a state by
 * x^k takes one PMULL by the constant x^(k-33) mod P and one CRC32C
 * instruction; the two products are XORed first and reduced together.
 *
 * The constants are x^(16N-33) and x^(8N-33) mod P for each block size, in
 * the instruction's reflected bit order (bit 31 is x^0). CRC32CTests derives
 * them again and checks every block size against a bit-at-a-time reference.
 */
static inline uint64_t clmul32(uint32_t a, uint32_t k) {
    return vgetq_lane_u64(vreinterpretq_u64_p128(vmull_p64(a, k)), 0);
}

#define ISCSI_CRC32C_3WAY(N, K_FAR, K_NEAR)                                   \
    while (len >= 3 * (N)) {                                                   \
        uint32_t b = 0, c = 0;                                                 \
        for (size_t i = 0; i < (N); i += 8) {                                  \
            uint64_t wa, wb, wc;                                               \
            memcpy(&wa, p + i, 8);                                             \
            memcpy(&wb, p + (N) + i, 8);                                       \
            memcpy(&wc, p + 2 * (N) + i, 8);                                   \
            crc = __builtin_arm_crc32cd(crc, wa);                              \
            b = __builtin_arm_crc32cd(b, wb);                                  \
            c = __builtin_arm_crc32cd(c, wc);                                  \
        }                                                                      \
        crc = __builtin_arm_crc32cd(0, clmul32(crc, (K_FAR)) ^ clmul32(b, (K_NEAR))) ^ c; \
        p += 3 * (N);                                                          \
        len -= 3 * (N);                                                        \
    }
#endif

uint32_t iscsi_crc32c(uint32_t crc, const void *data, size_t len) {
    const uint8_t *p = (const uint8_t *)data;

#if defined(ISCSI_CRC32C_FOLD)
    /* Largest blocks first; what is left after the smallest (under 192
     * bytes) goes down the single chain below. */
    ISCSI_CRC32C_3WAY(4096, 0x54A86326u, 0x82F89C77u)
    ISCSI_CRC32C_3WAY(512, 0x170076FAu, 0xDD7E3B0Cu)
    ISCSI_CRC32C_3WAY(64, 0x0D3B6092u, 0x9E4ADDF8u)
#endif

#if ISCSI_CRC32C_HW
    /* One chain: 8 bytes per instruction, then the tail a byte at a time.
     * memcpy rather than a cast: the callers hand us arbitrary slices of
     * network buffers, which are not guaranteed to be 8-byte aligned, and a
     * misaligned 64-bit load is undefined behaviour even where it happens to
     * work. The compiler turns this into a single load. */
    while (len >= 8) {
        uint64_t chunk;
        memcpy(&chunk, p, 8);
#if defined(__aarch64__)
        crc = __builtin_arm_crc32cd(crc, chunk);
#else
        crc = (uint32_t)_mm_crc32_u64(crc, chunk);
#endif
        p += 8;
        len -= 8;
    }
    while (len--) {
#if defined(__aarch64__)
        crc = __builtin_arm_crc32cb(crc, *p++);
#else
        crc = (uint32_t)_mm_crc32_u8(crc, *p++);
#endif
    }
#else
    if (!g_table_ready) build_table();
    while (len >= 8) {
        uint32_t lo;
        uint32_t hi;
        memcpy(&lo, p, 4);
        memcpy(&hi, p + 4, 4);
        lo ^= crc;
        crc = g_table[7][lo & 0xFF] ^ g_table[6][(lo >> 8) & 0xFF] ^
              g_table[5][(lo >> 16) & 0xFF] ^ g_table[4][(lo >> 24) & 0xFF] ^
              g_table[3][hi & 0xFF] ^ g_table[2][(hi >> 8) & 0xFF] ^
              g_table[1][(hi >> 16) & 0xFF] ^ g_table[0][(hi >> 24) & 0xFF];
        p += 8;
        len -= 8;
    }
    while (len--) crc = g_table[0][(crc ^ *p++) & 0xFF] ^ (crc >> 8);
#endif

    return crc;
}
