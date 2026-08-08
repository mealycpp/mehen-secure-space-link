#ifndef TRNG_CORE_HPP
#define TRNG_CORE_HPP

#include <ap_int.h>
#include <stdint.h>

typedef ap_uint<8>  u8;
typedef ap_uint<32> u32;

#define TRNG_MODE_RAW         0
#define TRNG_MODE_XOR_FOLD    1

#define TRNG_STATUS_VALID     0x00000001
#define TRNG_STATUS_REP_FAIL  0x00000002
#define TRNG_STATUS_BIAS_FAIL 0x00000004

void trng_core(
    const u8 *raw_samples,
    uint32_t n_bits,
    uint32_t mode,
    uint32_t &rand_word,
    uint32_t &status
);

#endif
