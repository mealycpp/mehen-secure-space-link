#include "trng_core.hpp"

static uint32_t repetition_count_fail(const u8 bits[256], uint32_t n_bits, uint32_t max_run) {
#pragma HLS INLINE
    if (n_bits == 0) return 1;

    uint32_t run = 1;
    u8 prev = bits[0] & 1;

    for (uint32_t i = 1; i < n_bits; i++) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=255
        u8 cur = bits[i] & 1;
        if (cur == prev) {
            run++;
            if (run > max_run) return 1;
        } else {
            run = 1;
            prev = cur;
        }
    }
    return 0;
}

static uint32_t bias_fail(const u8 bits[256], uint32_t n_bits, uint32_t min_ones, uint32_t max_ones) {
#pragma HLS INLINE
    uint32_t ones = 0;

    for (uint32_t i = 0; i < n_bits; i++) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=256
        ones += (bits[i] & 1);
    }

    if (ones < min_ones || ones > max_ones) return 1;
    return 0;
}

void trng_core(
    const u8 *raw_samples,
    uint32_t n_bits,
    uint32_t mode,
    uint32_t &rand_word,
    uint32_t &status
) {
#pragma HLS INTERFACE s_axilite port=return    bundle=CTRL
#pragma HLS INTERFACE s_axilite port=n_bits    bundle=CTRL
#pragma HLS INTERFACE s_axilite port=mode      bundle=CTRL
#pragma HLS INTERFACE s_axilite port=rand_word bundle=CTRL
#pragma HLS INTERFACE s_axilite port=status    bundle=CTRL
#pragma HLS INTERFACE m_axi port=raw_samples offset=slave bundle=GMEM depth=256

    u8 bits[256];
#pragma HLS ARRAY_PARTITION variable=bits cyclic factor=8 dim=1

    if (n_bits > 256) n_bits = 256;

    for (uint32_t i = 0; i < n_bits; i++) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=256
        bits[i] = raw_samples[i] & 1;
    }

    for (uint32_t i = n_bits; i < 256; i++) {
#pragma HLS LOOP_TRIPCOUNT min=0 max=256
        bits[i] = 0;
    }

    uint32_t rep_fail = repetition_count_fail(bits, n_bits, 16);
    uint32_t bias_fail_flag = bias_fail(bits, n_bits, n_bits / 4, (3 * n_bits) / 4);

    uint32_t word = 0;

    if (mode == TRNG_MODE_RAW) {
        for (uint32_t i = 0; i < 32 && i < n_bits; i++) {
#pragma HLS UNROLL
            word |= ((uint32_t)(bits[i] & 1)) << i;
        }
    } else {
        for (uint32_t i = 0; i < n_bits; i++) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=256
            word ^= ((uint32_t)(bits[i] & 1)) << (i & 31);
        }
    }

    rand_word = word;
    status = 0;

    if (!rep_fail && !bias_fail_flag) status |= TRNG_STATUS_VALID;
    if (rep_fail) status |= TRNG_STATUS_REP_FAIL;
    if (bias_fail_flag) status |= TRNG_STATUS_BIAS_FAIL;
}
