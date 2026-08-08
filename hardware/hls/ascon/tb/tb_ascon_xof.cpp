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

struct XofKat {
    int count = -1;
    std::vector<u8> msg;
    std::vector<u8> out;
};

static std::vector<XofKat> load_xof_kats(const std::string &path) {
    std::ifstream f(path.c_str());
    if (!f) {
        throw std::runtime_error("cannot open KAT file: " + path);
    }

    std::vector<XofKat> kats;
    XofKat cur;
    std::string line;

    while (std::getline(f, line)) {
        line = trim(line);

        if (line.empty()) {
            if (cur.count >= 0) {
                kats.push_back(cur);
                cur = XofKat{};
            }
            continue;
        }

        if (line.rfind("Count = ", 0) == 0) {
            cur.count = std::stoi(line.substr(8));
        } else if (line.rfind("Msg = ", 0) == 0) {
            cur.msg = hex_to_bytes(line.substr(6));
        } else if (line.rfind("Output = ", 0) == 0) {
            cur.out = hex_to_bytes(line.substr(9));
        } else if (line.rfind("Squeezed = ", 0) == 0) {
            cur.out = hex_to_bytes(line.substr(11));
        } else if (line.rfind("MD = ", 0) == 0) {
            cur.out = hex_to_bytes(line.substr(5));
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
        "C:/HLS/ascon/ascon/third_party/ascon-c/crypto_hash/asconxof128/LWC_XOF_KAT_128_512.txt";

    std::cout << "Using XOF KAT file: " << kat_path << std::endl;

    std::vector<XofKat> kats;
    try {
        kats = load_xof_kats(kat_path);
    } catch (const std::exception &e) {
        std::cout << "KAT load error: " << e.what() << std::endl;
        return 1;
    }

    std::cout << "Loaded XOF KAT count = " << kats.size() << std::endl;

    if (kats.empty()) {
        std::cout << "No XOF KATs loaded" << std::endl;
        return 1;
    }

    int tested = 0;
    int skipped = 0;

    for (size_t k = 0; k < kats.size(); k++) {
        if (kats[k].count < 0) {
            std::cout << "Malformed XOF KAT entry" << std::endl;
            return 1;
        }

        if (kats[k].msg.size() > 64) {
            skipped++;
            continue;
        }

        if (kats[k].out.size() != 64) {
            std::cout << "Unexpected XOF output size at Count = " << kats[k].count
                      << ", got " << kats[k].out.size() << " bytes" << std::endl;
            return 1;
        }

        u8 in_data[64];
        u8 out_data[80];
        uint32_t status = 0xFFFFFFFF;

        std::memset(in_data, 0, sizeof(in_data));
        std::memset(out_data, 0, sizeof(out_data));

        for (size_t i = 0; i < kats[k].msg.size(); i++) {
            in_data[i] = kats[k].msg[i];
        }

        hls::stream<axis64_t> in_stream;
        hls::stream<axis64_t> out_stream;

        push_bytes_to_stream(in_stream, in_data, (uint32_t)kats[k].msg.size());

        std::cout << "Testing Count = " << kats[k].count
                  << ", MsgBytes = " << kats[k].msg.size() << std::endl;

        ascon_core(
            in_stream,
            out_stream,
            (uint32_t)kats[k].msg.size(),
            0,
            64,
            MODE_XOF,
            status
        );

        if (status != 0) {
            std::cout << "XOF status FAIL at Count = " << kats[k].count
                      << ", status = " << status << std::endl;
            return 1;
        }

        pop_bytes_from_stream(out_stream, out_data, 64);

        bool ok = true;
        for (size_t i = 0; i < 64; i++) {
            if (out_data[i] != kats[k].out[i]) {
                ok = false;
                break;
            }
        }

        if (!ok) {
            std::cout << "XOF KAT FAIL at Count = " << kats[k].count << std::endl;
            std::cout << "Expected: " << bytes_to_hex(kats[k].out.data(), 64) << std::endl;
            std::cout << "Got     : " << bytes_to_hex(out_data, 64) << std::endl;
            return 1;
        }

        tested++;
    }

    std::cout << "XOF KAT PASS, tested " << tested
              << " cases, skipped " << skipped
              << " cases (>64-byte messages)" << std::endl;

    return 0;
}
