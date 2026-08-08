#ifndef ASCON_CORE_HPP
#define ASCON_CORE_HPP

#include <ap_int.h>
#include <ap_axi_sdata.h>
#include <hls_stream.h>
#include <stdint.h>

#define MODE_HASH      0
#define MODE_XOF       1
#define MODE_AEAD_ENC  2
#define MODE_AEAD_DEC  3

// keep old name alive for existing encrypt scripts
#define MODE_AEAD MODE_AEAD_ENC

typedef ap_uint<64> u64;
typedef ap_uint<8>  u8;
typedef ap_axiu<64, 0, 0, 0> axis64_t;

struct ascon_state_t {
    u64 x0;
    u64 x1;
    u64 x2;
    u64 x3;
    u64 x4;
};

void ascon_core(
    hls::stream<axis64_t> &in_stream,
    hls::stream<axis64_t> &out_stream,
    uint32_t in_len,
    uint32_t ad_len,
    uint32_t out_len,
    uint32_t mode,
    uint32_t &status
);

#endif
