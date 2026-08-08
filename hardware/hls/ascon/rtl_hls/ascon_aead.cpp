#include "ascon_aead.hpp"
#include "ascon_perm.hpp"

// Ascon-AEAD128 standardized init value.
static const u64 ASCON_AEAD128_IV = 0x00001000808c0001ULL;

static inline u64 load_partial_le(const u8 *b, uint32_t len) {
#pragma HLS INLINE
    u64 x = 0;
    for (int i = 0; i < 8; i++) {
#pragma HLS UNROLL
        if ((uint32_t)i < len) {
            x |= ((u64)b[i]) << (8 * i);
        }
    }
    return x;
}

static inline void store_partial_le(u8 *b, u64 x, uint32_t len) {
#pragma HLS INLINE
    for (int i = 0; i < 8; i++) {
#pragma HLS UNROLL
        if ((uint32_t)i < len) {
            b[i] = (u8)((x >> (8 * i)) & 0xFF);
        }
    }
}

static inline u64 pad_le(uint32_t len) {
#pragma HLS INLINE
    return ((u64)0x01) << (8 * len);
}

static inline u64 mask_low_bytes(uint32_t len) {
#pragma HLS INLINE
    u64 m = 0;
    for (int i = 0; i < 8; i++) {
#pragma HLS UNROLL
        if ((uint32_t)i < len) {
            m |= ((u64)0xFF) << (8 * i);
        }
    }
    return m;
}

static inline void ascon_aead_init(
    ascon_state_t &s,
    const u8 key[16],
    const u8 nonce[16]
) {
#pragma HLS INLINE
    u8 k0b[8], k1b[8], n0b[8], n1b[8];
#pragma HLS ARRAY_PARTITION variable=k0b complete dim=1
#pragma HLS ARRAY_PARTITION variable=k1b complete dim=1
#pragma HLS ARRAY_PARTITION variable=n0b complete dim=1
#pragma HLS ARRAY_PARTITION variable=n1b complete dim=1

    for (int i = 0; i < 8; i++) {
#pragma HLS UNROLL
        k0b[i] = key[i];
        k1b[i] = key[i + 8];
        n0b[i] = nonce[i];
        n1b[i] = nonce[i + 8];
    }

    u64 k0 = load64_le(k0b);
    u64 k1 = load64_le(k1b);

    s.x0 = ASCON_AEAD128_IV;
    s.x1 = k0;
    s.x2 = k1;
    s.x3 = load64_le(n0b);
    s.x4 = load64_le(n1b);

    ascon_permute(s, 12);

    s.x3 ^= k0;
    s.x4 ^= k1;
}

static void ascon_absorb_ad(
    ascon_state_t &s,
    const u8 ad[64],
    uint32_t ad_len
) {
#pragma HLS INLINE off

    const uint32_t RATE = 16;
    uint32_t offset = 0;

    if (ad_len != 0) {
        while (ad_len >= RATE) {
#pragma HLS LOOP_TRIPCOUNT min=0 max=4
            u8 b0[8], b1[8];
#pragma HLS ARRAY_PARTITION variable=b0 complete dim=1
#pragma HLS ARRAY_PARTITION variable=b1 complete dim=1

            for (int i = 0; i < 8; i++) {
#pragma HLS UNROLL
                b0[i] = ad[offset + i];
                b1[i] = ad[offset + 8 + i];
            }

            s.x0 ^= load64_le(b0);
            s.x1 ^= load64_le(b1);
            ascon_permute(s, 8);

            offset += RATE;
            ad_len -= RATE;
        }

        if (ad_len >= 8) {
            u8 b0[8];
#pragma HLS ARRAY_PARTITION variable=b0 complete dim=1
            for (int i = 0; i < 8; i++) {
#pragma HLS UNROLL
                b0[i] = ad[offset + i];
            }
            s.x0 ^= load64_le(b0);
            offset += 8;
            ad_len -= 8;

            s.x1 ^= pad_le(ad_len);
            if (ad_len) {
                s.x1 ^= load_partial_le(&ad[offset], ad_len);
            }
        } else {
            s.x0 ^= pad_le(ad_len);
            if (ad_len) {
                s.x0 ^= load_partial_le(&ad[offset], ad_len);
            }
        }

        ascon_permute(s, 8);
    }

    // domain separation
    s.x4 ^= 0x8000000000000000ULL;
}

static void ascon_encrypt_pt(
    ascon_state_t &s,
    const u8 pt[64],
    u8 ct[80],
    uint32_t pt_len
) {
#pragma HLS INLINE off

    const uint32_t RATE = 16;
    uint32_t in_off = 0;
    uint32_t out_off = 0;

    while (pt_len >= RATE) {
#pragma HLS LOOP_TRIPCOUNT min=0 max=4
        u8 b0[8], b1[8], o0[8], o1[8];
#pragma HLS ARRAY_PARTITION variable=b0 complete dim=1
#pragma HLS ARRAY_PARTITION variable=b1 complete dim=1
#pragma HLS ARRAY_PARTITION variable=o0 complete dim=1
#pragma HLS ARRAY_PARTITION variable=o1 complete dim=1

        for (int i = 0; i < 8; i++) {
#pragma HLS UNROLL
            b0[i] = pt[in_off + i];
            b1[i] = pt[in_off + 8 + i];
        }

        s.x0 ^= load64_le(b0);
        s.x1 ^= load64_le(b1);

        store64_le(o0, s.x0);
        store64_le(o1, s.x1);

        for (int i = 0; i < 8; i++) {
#pragma HLS UNROLL
            ct[out_off + i] = o0[i];
            ct[out_off + 8 + i] = o1[i];
        }

        ascon_permute(s, 8);

        in_off += RATE;
        out_off += RATE;
        pt_len -= RATE;
    }

    if (pt_len >= 8) {
        u8 b0[8], o0[8];
#pragma HLS ARRAY_PARTITION variable=b0 complete dim=1
#pragma HLS ARRAY_PARTITION variable=o0 complete dim=1

        for (int i = 0; i < 8; i++) {
#pragma HLS UNROLL
            b0[i] = pt[in_off + i];
        }

        s.x0 ^= load64_le(b0);
        store64_le(o0, s.x0);

        for (int i = 0; i < 8; i++) {
#pragma HLS UNROLL
            ct[out_off + i] = o0[i];
        }

        in_off += 8;
        out_off += 8;
        pt_len -= 8;

        s.x1 ^= pad_le(pt_len);
        if (pt_len) {
            s.x1 ^= load_partial_le(&pt[in_off], pt_len);
            store_partial_le(&ct[out_off], s.x1, pt_len);
        }
    } else {
        s.x0 ^= pad_le(pt_len);
        if (pt_len) {
            s.x0 ^= load_partial_le(&pt[in_off], pt_len);
            store_partial_le(&ct[out_off], s.x0, pt_len);
        }
    }
}

static void ascon_decrypt_ct(
    ascon_state_t &s,
    const u8 ct[80],
    u8 pt[80],
    uint32_t pt_len
) {
#pragma HLS INLINE off

    const uint32_t RATE = 16;
    uint32_t in_off = 0;
    uint32_t out_off = 0;

    while (pt_len >= RATE) {
#pragma HLS LOOP_TRIPCOUNT min=0 max=4
        u8 c0[8], c1[8], p0[8], p1[8];
#pragma HLS ARRAY_PARTITION variable=c0 complete dim=1
#pragma HLS ARRAY_PARTITION variable=c1 complete dim=1
#pragma HLS ARRAY_PARTITION variable=p0 complete dim=1
#pragma HLS ARRAY_PARTITION variable=p1 complete dim=1

        for (int i = 0; i < 8; i++) {
#pragma HLS UNROLL
            c0[i] = ct[in_off + i];
            c1[i] = ct[in_off + 8 + i];
        }

        u64 c0w = load64_le(c0);
        u64 c1w = load64_le(c1);
        u64 p0w = s.x0 ^ c0w;
        u64 p1w = s.x1 ^ c1w;

        store64_le(p0, p0w);
        store64_le(p1, p1w);

        for (int i = 0; i < 8; i++) {
#pragma HLS UNROLL
            pt[out_off + i] = p0[i];
            pt[out_off + 8 + i] = p1[i];
        }

        s.x0 = c0w;
        s.x1 = c1w;
        ascon_permute(s, 8);

        in_off += RATE;
        out_off += RATE;
        pt_len -= RATE;
    }

    if (pt_len >= 8) {
        u8 c0[8], p0[8];
#pragma HLS ARRAY_PARTITION variable=c0 complete dim=1
#pragma HLS ARRAY_PARTITION variable=p0 complete dim=1

        for (int i = 0; i < 8; i++) {
#pragma HLS UNROLL
            c0[i] = ct[in_off + i];
        }

        u64 c0w = load64_le(c0);
        u64 p0w = s.x0 ^ c0w;

        store64_le(p0, p0w);

        for (int i = 0; i < 8; i++) {
#pragma HLS UNROLL
            pt[out_off + i] = p0[i];
        }

        s.x0 = c0w;

        in_off += 8;
        out_off += 8;
        pt_len -= 8;

        if (pt_len) {
            u64 c1part = load_partial_le(&ct[in_off], pt_len);
            u64 p1part = s.x1 ^ c1part;
            u64 m1 = mask_low_bytes(pt_len);

            store_partial_le(&pt[out_off], p1part, pt_len);

            s.x1 = (s.x1 & ~m1) | c1part;
        }

        s.x1 ^= pad_le(pt_len);
    } else {
        if (pt_len) {
            u64 c0part = load_partial_le(&ct[in_off], pt_len);
            u64 p0part = s.x0 ^ c0part;
            u64 m0 = mask_low_bytes(pt_len);

            store_partial_le(&pt[out_off], p0part, pt_len);

            s.x0 = (s.x0 & ~m0) | c0part;
        }

        s.x0 ^= pad_le(pt_len);
    }
}

static void ascon_final_tag(
    ascon_state_t &s,
    const u8 key[16],
    u8 tag[16]
) {
#pragma HLS INLINE off

    u8 k0b[8], k1b[8], t0[8], t1[8];
#pragma HLS ARRAY_PARTITION variable=k0b complete dim=1
#pragma HLS ARRAY_PARTITION variable=k1b complete dim=1
#pragma HLS ARRAY_PARTITION variable=t0 complete dim=1
#pragma HLS ARRAY_PARTITION variable=t1 complete dim=1

    for (int i = 0; i < 8; i++) {
#pragma HLS UNROLL
        k0b[i] = key[i];
        k1b[i] = key[i + 8];
    }

    u64 k0 = load64_le(k0b);
    u64 k1 = load64_le(k1b);

    s.x2 ^= k0;
    s.x3 ^= k1;
    ascon_permute(s, 12);
    s.x3 ^= k0;
    s.x4 ^= k1;

    store64_le(t0, s.x3);
    store64_le(t1, s.x4);

    for (int i = 0; i < 8; i++) {
#pragma HLS UNROLL
        tag[i] = t0[i];
        tag[i + 8] = t1[i];
    }
}

void ascon_aead128_encrypt(
    const u8 key[16],
    const u8 nonce[16],
    const u8 ad[64],
    const u8 pt[64],
    u8 ct[80],
    uint32_t ad_len,
    uint32_t pt_len
) {
#pragma HLS INLINE off

    ascon_state_t s;
    u8 tag[16];
#pragma HLS ARRAY_PARTITION variable=tag complete dim=1

    ascon_aead_init(s, key, nonce);
    ascon_absorb_ad(s, ad, ad_len);
    ascon_encrypt_pt(s, pt, ct, pt_len);
    ascon_final_tag(s, key, tag);

    for (int i = 0; i < 16; i++) {
#pragma HLS UNROLL
        ct[pt_len + i] = tag[i];
    }
}

bool ascon_aead128_decrypt(
    const u8 key[16],
    const u8 nonce[16],
    const u8 ad[64],
    const u8 ct_and_tag[80],
    u8 pt[80],
    uint32_t ad_len,
    uint32_t ct_len
) {
#pragma HLS INLINE off

    if (ct_len < 16) {
        for (int i = 0; i < 80; i++) {
#pragma HLS PIPELINE II=1
            pt[i] = 0;
        }
        return false;
    }

    uint32_t pt_len = ct_len - 16;

    ascon_state_t s;
    u8 tag[16];
#pragma HLS ARRAY_PARTITION variable=tag complete dim=1

    ascon_aead_init(s, key, nonce);
    ascon_absorb_ad(s, ad, ad_len);
    ascon_decrypt_ct(s, ct_and_tag, pt, pt_len);
    ascon_final_tag(s, key, tag);

    u8 diff = 0;
    for (int i = 0; i < 16; i++) {
#pragma HLS UNROLL
        diff |= (u8)(tag[i] ^ ct_and_tag[pt_len + i]);
    }

    if (diff != 0) {
        for (uint32_t i = 0; i < pt_len; i++) {
#pragma HLS LOOP_TRIPCOUNT min=0 max=64
            pt[i] = 0;
        }
        return false;
    }

    return true;
}
