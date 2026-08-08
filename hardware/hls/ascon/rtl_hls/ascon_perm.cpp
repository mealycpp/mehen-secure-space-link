#include "ascon_perm.hpp"

static inline u64 rotr64(const u64 x, const int n) {
#pragma HLS INLINE
    return (x >> n) | (x << (64 - n));
}

static const u8 ASCON_RC[12] = {
    0xF0, 0xE1, 0xD2, 0xC3,
    0xB4, 0xA5, 0x96, 0x87,
    0x78, 0x69, 0x5A, 0x4B
};

u64 load64_le(const u8 b[8]) {
#pragma HLS INLINE
    u64 x = 0;
    for (int i = 7; i >= 0; i--) {
#pragma HLS UNROLL
        x = (x << 8) | (u64)b[i];
    }
    return x;
}

void store64_le(u8 b[8], u64 x) {
#pragma HLS INLINE
    for (int i = 0; i < 8; i++) {
#pragma HLS UNROLL
        b[i] = (u8)(x & 0xFF);
        x >>= 8;
    }
}

void ascon_permute(ascon_state_t &s, int rounds) {
#pragma HLS INLINE off

    if (rounds < 1) return;
    if (rounds > 12) rounds = 12;

    const int start = 12 - rounds;

    for (int r = start; r < 12; r++) {
#pragma HLS PIPELINE II=1
        s.x2 ^= (u64)ASCON_RC[r];

        s.x0 ^= s.x4;
        s.x4 ^= s.x3;
        s.x2 ^= s.x1;

        u64 t0 = s.x0;
        u64 t1 = s.x1;
        u64 t2 = s.x2;
        u64 t3 = s.x3;
        u64 t4 = s.x4;

        s.x0 = t0 ^ ((~t1) & t2);
        s.x1 = t1 ^ ((~t2) & t3);
        s.x2 = t2 ^ ((~t3) & t4);
        s.x3 = t3 ^ ((~t4) & t0);
        s.x4 = t4 ^ ((~t0) & t1);

        s.x1 ^= s.x0;
        s.x0 ^= s.x4;
        s.x3 ^= s.x2;
        s.x2 = ~s.x2;

        s.x0 ^= rotr64(s.x0, 19) ^ rotr64(s.x0, 28);
        s.x1 ^= rotr64(s.x1, 61) ^ rotr64(s.x1, 39);
        s.x2 ^= rotr64(s.x2,  1) ^ rotr64(s.x2,  6);
        s.x3 ^= rotr64(s.x3, 10) ^ rotr64(s.x3, 17);
        s.x4 ^= rotr64(s.x4,  7) ^ rotr64(s.x4, 41);
    }
}
