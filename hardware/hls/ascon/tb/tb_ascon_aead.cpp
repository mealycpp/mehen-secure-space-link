#include "../rtl_hls/ascon_core.hpp"
#include <iostream>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <iomanip>
#include <cstring>
#include <stdexcept>

static std::string trim(const std::string &s) {
    size_t start = 0;
    while (start < s.size() &&
           (s[start] == ' ' || s[start] == '\t' || s[start] == '\r' || s[start] == '\n')) {
        start++;
    }

    size_t end = s.size();
    while (end > start &&
           (s[end - 1] == ' ' || s[end - 1] == '\t' || s[end - 1] == '\r' || s[end - 1] == '\n')) {
        end--;
    }

    return s.substr(start, end - start);
}

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return 10 + (c - 'a');
    if (c >= 'A' && c <= 'F') return 10 + (c - 'A');
    return -1;
}

static std::vector<u8> hex_to_bytes(const std::string &hex_in) {
    std::string hex = trim(hex_in);
    std::vector<u8> out;

    if (hex.empty()) return out;

    if (hex.size() % 2 != 0) {
        throw std::runtime_error("hex string has odd length");
    }

    out.reserve(hex.size() / 2);

    for (size_t i = 0; i < hex.size(); i += 2) {
        int hi = hexval(hex[i]);
        int lo = hexval(hex[i + 1]);
        if (hi < 0 || lo < 0) {
            throw std::runtime_error("bad hex");
        }
        out.push_back((u8)((hi << 4) | lo));
    }

    return out;
}

static std::string bytes_to_hex(const u8 *data, size_t len) {
    std::ostringstream oss;
    for (size_t i = 0; i < len; i++) {
        oss << std::hex << std::setw(2) << std::setfill('0')
            << (unsigned)data[i];
    }
    return oss.str();
}

struct AeadKat {
    int count = -1;
    std::vector<u8> key;
    std::vector<u8> nonce;
    std::vector<u8> ad;
    std::vector<u8> pt;
    std::vector<u8> ct;
};

static std::vector<AeadKat> load_aead_kats(const std::string &path) {
    std::ifstream f(path.c_str());
    if (!f) {
        throw std::runtime_error("cannot open KAT file: " + path);
    }

    std::vector<AeadKat> kats;
    AeadKat cur;
    std::string line;

    while (std::getline(f, line)) {
        line = trim(line);

        if (line.empty()) {
            if (cur.count >= 0) {
                kats.push_back(cur);
                cur = AeadKat{};
            }
            continue;
        }

        if (line.rfind("Count = ", 0) == 0) {
            cur.count = std::stoi(line.substr(8));
        } else if (line.rfind("Key = ", 0) == 0) {
            cur.key = hex_to_bytes(line.substr(6));
        } else if (line.rfind("Nonce = ", 0) == 0) {
            cur.nonce = hex_to_bytes(line.substr(8));
        } else if (line.rfind("AD = ", 0) == 0) {
            cur.ad = hex_to_bytes(line.substr(5));
        } else if (line.rfind("PT = ", 0) == 0) {
            cur.pt = hex_to_bytes(line.substr(5));
        } else if (line.rfind("CT = ", 0) == 0) {
            cur.ct = hex_to_bytes(line.substr(5));
        }
    }

    if (cur.count >= 0) {
        kats.push_back(cur);
    }

    return kats;
}

static void push_bytes_to_stream(
    hls::stream<axis64_t> &s,
    const u8 *src,
    uint32_t nbytes
) {
    uint32_t nwords = (nbytes + 7U) >> 3;

    for (uint32_t w = 0; w < nwords; w++) {
        axis64_t v;
        v.data = 0;
        v.keep = 0;
        v.strb = 0;
        v.last = (w == (nwords - 1));

        ap_uint<64> d = 0;
        ap_uint<8>  k = 0;

        for (int b = 0; b < 8; b++) {
            uint32_t idx = (w << 3) + b;
            if (idx < nbytes) {
                d |= ((ap_uint<64>)src[idx]) << (8 * b);
                k[b] = 1;
            }
        }

        v.data = d;
        v.keep = k;
        v.strb = k;
        s.write(v);
    }
}

static void pop_bytes_from_stream(
    hls::stream<axis64_t> &s,
    u8 *dst,
    uint32_t nbytes
) {
    uint32_t nwords = (nbytes + 7U) >> 3;

    for (uint32_t w = 0; w < nwords; w++) {
        axis64_t v = s.read();
        ap_uint<64> d = v.data;

        for (int b = 0; b < 8; b++) {
            uint32_t idx = (w << 3) + b;
            if (idx < nbytes) {
                dst[idx] = (u8)((d >> (8 * b)) & 0xFF);
            }
        }
    }
}

int main() {
    const std::string kat_path =
        "C:/HLS/ascon/ascon/third_party/ascon-c/crypto_aead/asconaead128/LWC_AEAD_KAT_128_128.txt";

    std::cout << "Using AEAD KAT file: " << kat_path << std::endl;

    std::vector<AeadKat> kats;
    try {
        kats = load_aead_kats(kat_path);
    } catch (const std::exception &e) {
        std::cout << "KAT load error: " << e.what() << std::endl;
        return 1;
    }

    std::cout << "Loaded AEAD KAT count = " << kats.size() << std::endl;

    if (kats.empty()) {
        std::cout << "No AEAD KATs loaded" << std::endl;
        return 1;
    }

    int tested = 0;
    int skipped = 0;

    for (size_t k = 0; k < kats.size(); k++) {
        if (kats[k].count < 0) {
            std::cout << "Malformed AEAD KAT entry" << std::endl;
            return 1;
        }

        if (kats[k].key.size() != 16) {
            std::cout << "Bad key size at Count = " << kats[k].count << std::endl;
            return 1;
        }

        if (kats[k].nonce.size() != 16) {
            std::cout << "Bad nonce size at Count = " << kats[k].count << std::endl;
            return 1;
        }

        if (kats[k].ad.size() > 64 || kats[k].pt.size() > 64) {
            skipped++;
            continue;
        }

        if (kats[k].ct.size() != kats[k].pt.size() + 16) {
            std::cout << "Bad ciphertext/tag size at Count = " << kats[k].count
                      << ", expected " << (kats[k].pt.size() + 16)
                      << ", got " << kats[k].ct.size() << std::endl;
            return 1;
        }

        u8 out_data[80];
        u8 tx_data[176];
        uint32_t status = 0xFFFFFFFF;

        std::memset(out_data, 0, sizeof(out_data));
        std::memset(tx_data, 0, sizeof(tx_data));

        uint32_t ad_len = (uint32_t)kats[k].ad.size();
        uint32_t pt_len = (uint32_t)kats[k].pt.size();
        uint32_t tx_len = 16 + 16 + ad_len + pt_len;

        // Flatten packet:
        // KEY || NONCE || AD || PT
        for (int i = 0; i < 16; i++) {
            tx_data[i] = kats[k].key[i];
            tx_data[16 + i] = kats[k].nonce[i];
        }

        for (uint32_t i = 0; i < ad_len; i++) {
            tx_data[32 + i] = kats[k].ad[i];
        }

        for (uint32_t i = 0; i < pt_len; i++) {
            tx_data[32 + ad_len + i] = kats[k].pt[i];
        }

        hls::stream<axis64_t> in_stream;
        hls::stream<axis64_t> out_stream;

        push_bytes_to_stream(in_stream, tx_data, tx_len);

        std::cout << "Testing Count = " << kats[k].count
                  << ", ADBytes = " << ad_len
                  << ", PTBytes = " << pt_len << std::endl;

        ascon_core(
            in_stream,
            out_stream,
            pt_len,
            ad_len,
            (uint32_t)(pt_len + 16),
            MODE_AEAD_ENC,
            status
        );

        if (status != 0) {
            std::cout << "AEAD status FAIL at Count = " << kats[k].count
                      << ", status = " << status << std::endl;
            return 1;
        }

        pop_bytes_from_stream(out_stream, out_data, (uint32_t)kats[k].ct.size());

        bool ok = true;
        for (size_t i = 0; i < kats[k].ct.size(); i++) {
            if (out_data[i] != kats[k].ct[i]) {
                ok = false;
                break;
            }
        }

        if (!ok) {
            std::cout << "AEAD KAT FAIL at Count = " << kats[k].count << std::endl;
            std::cout << "Expected: " << bytes_to_hex(kats[k].ct.data(), kats[k].ct.size()) << std::endl;
            std::cout << "Got     : " << bytes_to_hex(out_data, kats[k].ct.size()) << std::endl;
            return 1;
        }

        tested++;
    }

    std::cout << "AEAD KAT PASS, tested " << tested
              << " cases, skipped " << skipped
              << " cases (>64-byte AD/PT)" << std::endl;

    return 0;
}
