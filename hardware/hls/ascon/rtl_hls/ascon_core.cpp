#include "ascon_core.hpp"
#include "ascon_perm.hpp"
#include "ascon_aead.hpp"

static const u64 ASCON_HASH256_IV[5] = {
    0x9b1e5494e934d681ULL,
    0x4bc3a01e333751d2ULL,
    0xae65396c6b34b81aULL,
    0x3c7fd4a4d56a4db3ULL,
    0x1a5c464906c5976dULL
};

static const u64 ASCON_XOF128_IV[5] = {
    0xda82ce768d9447ebULL,
    0xcc7ce6c75f1ef969ULL,
    0xe7508fd780085631ULL,
    0x0ee0ea53416b58ccULL,
    0xe0547524db6f0bdeULL
};

static inline void ascon_state_init(ascon_state_t &s, const u64 iv[5]) {
#pragma HLS INLINE
    s.x0 = iv[0];
    s.x1 = iv[1];
    s.x2 = iv[2];
    s.x3 = iv[3];
    s.x4 = iv[4];
}

static void ascon_absorb_rate8(
    ascon_state_t &s,
    const u8 in_data[64],
    uint32_t in_len
) {
#pragma HLS INLINE off

    const uint32_t RATE = 8;
    uint32_t offset = 0;

    while (in_len >= RATE) {
#pragma HLS LOOP_TRIPCOUNT min=0 max=8
        u8 block[8];
#pragma HLS ARRAY_PARTITION variable=block complete dim=1

        for (int i = 0; i < 8; i++) {
#pragma HLS UNROLL
            block[i] = in_data[offset + i];
        }

        s.x0 ^= load64_le(block);
        ascon_permute(s, 12);

        offset += RATE;
        in_len -= RATE;
    }

    {
        u8 last[8];
#pragma HLS ARRAY_PARTITION variable=last complete dim=1

        for (int i = 0; i < 8; i++) {
#pragma HLS UNROLL
            last[i] = 0;
        }

        for (uint32_t i = 0; i < in_len; i++) {
#pragma HLS LOOP_TRIPCOUNT min=0 max=7
            last[i] = in_data[offset + i];
        }

        last[in_len] = 0x01;
        s.x0 ^= load64_le(last);
    }
}

static void ascon_squeeze_rate8(
    ascon_state_t &s,
    u8 out_data[80],
    uint32_t out_len
) {
#pragma HLS INLINE off

    const uint32_t RATE = 8;
    uint32_t produced = 0;

    ascon_permute(s, 12);

    while (out_len > RATE) {
#pragma HLS LOOP_TRIPCOUNT min=0 max=10
        u8 block[8];
#pragma HLS ARRAY_PARTITION variable=block complete dim=1

        store64_le(block, s.x0);

        for (int i = 0; i < 8; i++) {
#pragma HLS UNROLL
            out_data[produced + i] = block[i];
        }

        produced += RATE;
        out_len -= RATE;

        ascon_permute(s, 12);
    }

    {
        u8 block[8];
#pragma HLS ARRAY_PARTITION variable=block complete dim=1

        store64_le(block, s.x0);

        for (uint32_t i = 0; i < out_len; i++) {
#pragma HLS LOOP_TRIPCOUNT min=0 max=7
            out_data[produced + i] = block[i];
        }
    }
}

static void ascon_hash256(
    const u8 in_data[64],
    u8 out_data[80],
    uint32_t in_len
) {
#pragma HLS INLINE off
    ascon_state_t s;
    ascon_state_init(s, ASCON_HASH256_IV);
    ascon_absorb_rate8(s, in_data, in_len);
    ascon_squeeze_rate8(s, out_data, 32);
}

static void ascon_xof128(
    const u8 in_data[64],
    u8 out_data[80],
    uint32_t in_len,
    uint32_t out_len
) {
#pragma HLS INLINE off
    ascon_state_t s;
    ascon_state_init(s, ASCON_XOF128_IV);
    ascon_absorb_rate8(s, in_data, in_len);
    ascon_squeeze_rate8(s, out_data, out_len);
}

static void stream_read_bytes(
    hls::stream<axis64_t> &in_stream,
    u8 *dst,
    uint32_t nbytes
) {
#pragma HLS INLINE off

    uint32_t nwords = (nbytes + 7U) >> 3;

    for (uint32_t w = 0; w < nwords; w++) {
#pragma HLS LOOP_TRIPCOUNT min=0 max=24
        axis64_t v = in_stream.read();
        ap_uint<64> d = v.data;

        for (int b = 0; b < 8; b++) {
#pragma HLS UNROLL
            uint32_t idx = (w << 3) + b;
            if (idx < nbytes) {
                dst[idx] = (u8)((d >> (8 * b)) & 0xFF);
            }
        }
    }
}

static void stream_write_bytes(
    hls::stream<axis64_t> &out_stream,
    const u8 *src,
    uint32_t nbytes
) {
#pragma HLS INLINE off

    uint32_t nwords = (nbytes + 7U) >> 3;

    for (uint32_t w = 0; w < nwords; w++) {
#pragma HLS LOOP_TRIPCOUNT min=0 max=12
        axis64_t v;
        ap_uint<64> d = 0;
        ap_uint<8>  k = 0;

        for (int b = 0; b < 8; b++) {
#pragma HLS UNROLL
            uint32_t idx = (w << 3) + b;
            if (idx < nbytes) {
                d |= ((ap_uint<64>)src[idx]) << (8 * b);
                k[b] = 1;
            }
        }

        v.data = d;
        v.keep = k;
        v.strb = k;
        v.last = (w == (nwords - 1));
        out_stream.write(v);
    }
}

void ascon_core(
    hls::stream<axis64_t> &in_stream,
    hls::stream<axis64_t> &out_stream,
    uint32_t in_len,
    uint32_t ad_len,
    uint32_t out_len,
    uint32_t mode,
    uint32_t &status
) {
#pragma HLS INTERFACE axis port=in_stream
#pragma HLS INTERFACE axis port=out_stream

#pragma HLS INTERFACE s_axilite port=return  bundle=CTRL
#pragma HLS INTERFACE s_axilite port=in_len  bundle=CTRL
#pragma HLS INTERFACE s_axilite port=ad_len  bundle=CTRL
#pragma HLS INTERFACE s_axilite port=out_len bundle=CTRL
#pragma HLS INTERFACE s_axilite port=mode    bundle=CTRL
#pragma HLS INTERFACE s_axilite port=status  bundle=CTRL

    u8 in_local[64];
    u8 key_local[16];
    u8 nonce_local[16];
    u8 ad_local[64];
    u8 out_local[80];
    u8 ct_local[80];
    u8 tx_local[176];

#pragma HLS ARRAY_PARTITION variable=key_local complete dim=1
#pragma HLS ARRAY_PARTITION variable=nonce_local complete dim=1

    status = 0;

    for (int i = 0; i < 64; i++) {
#pragma HLS PIPELINE II=1
        in_local[i] = 0;
        ad_local[i] = 0;
    }

    for (int i = 0; i < 16; i++) {
#pragma HLS UNROLL
        key_local[i] = 0;
        nonce_local[i] = 0;
    }

    for (int i = 0; i < 80; i++) {
#pragma HLS PIPELINE II=1
        out_local[i] = 0;
        ct_local[i] = 0;
    }

    for (int i = 0; i < 176; i++) {
#pragma HLS PIPELINE II=1
        tx_local[i] = 0;
    }

    if (ad_len > 64) ad_len = 64;
    if (out_len > 80) out_len = 80;

    switch (mode) {
        case MODE_HASH: {
            if (in_len > 64) in_len = 64;
            stream_read_bytes(in_stream, in_local, in_len);
            ascon_hash256(in_local, out_local, in_len);
            stream_write_bytes(out_stream, out_local, 32);
            status = 0;
            break;
        }

        case MODE_XOF: {
            if (in_len > 64) in_len = 64;
            stream_read_bytes(in_stream, in_local, in_len);
            ascon_xof128(in_local, out_local, in_len, out_len);
            stream_write_bytes(out_stream, out_local, out_len);
            status = 0;
            break;
        }

        case MODE_AEAD_ENC: {
            if (in_len > 64) in_len = 64;

            uint32_t total_in = 32 + ad_len + in_len;
            if (total_in > 176) total_in = 176;

            // KEY || NONCE || AD || PT
            stream_read_bytes(in_stream, tx_local, total_in);

            for (int i = 0; i < 16; i++) {
#pragma HLS UNROLL
                key_local[i]   = tx_local[i];
                nonce_local[i] = tx_local[16 + i];
            }

            for (uint32_t i = 0; i < ad_len; i++) {
#pragma HLS LOOP_TRIPCOUNT min=0 max=64
                ad_local[i] = tx_local[32 + i];
            }

            for (uint32_t i = 0; i < in_len; i++) {
#pragma HLS LOOP_TRIPCOUNT min=0 max=64
                in_local[i] = tx_local[32 + ad_len + i];
            }

            ascon_aead128_encrypt(
                key_local,
                nonce_local,
                ad_local,
                in_local,
                out_local,
                ad_len,
                in_len
            );

            {
                uint32_t ct_len = in_len + 16;
                if (ct_len > 80) ct_len = 80;
                stream_write_bytes(out_stream, out_local, ct_len);
            }

            status = 0;
            break;
        }

        case MODE_AEAD_DEC: {
            // in_len here is CT||TAG length
            if (in_len < 16) {
                status = 2;
                break;
            }
            if (in_len > 80) in_len = 80;

            uint32_t total_in = 32 + ad_len + in_len;
            if (total_in > 176) total_in = 176;

            // KEY || NONCE || AD || CT||TAG
            stream_read_bytes(in_stream, tx_local, total_in);

            for (int i = 0; i < 16; i++) {
#pragma HLS UNROLL
                key_local[i]   = tx_local[i];
                nonce_local[i] = tx_local[16 + i];
            }

            for (uint32_t i = 0; i < ad_len; i++) {
#pragma HLS LOOP_TRIPCOUNT min=0 max=64
                ad_local[i] = tx_local[32 + i];
            }

            for (uint32_t i = 0; i < in_len; i++) {
#pragma HLS LOOP_TRIPCOUNT min=0 max=80
                ct_local[i] = tx_local[32 + ad_len + i];
            }

            uint32_t pt_len = in_len - 16;
            if (pt_len > 64) pt_len = 64;

            bool ok = ascon_aead128_decrypt(
                key_local,
                nonce_local,
                ad_local,
                ct_local,
                out_local,
                ad_len,
                in_len
            );

            stream_write_bytes(out_stream, out_local, pt_len);
            status = ok ? 0 : 1;
            break;
        }

        default:
            status = 2;
            break;
    }
}
