#include "../rtl/trng_core.hpp"
#include <iostream>
#include <cstring>

int main() {
    u8 raw_samples[256];
    std::memset(raw_samples, 0, sizeof(raw_samples));

    // Deterministic nontrivial pattern for testing.
    // Good enough to avoid XOR-fold collapsing to 0.
    for (int i = 0; i < 256; i++) {
        raw_samples[i] = ((i * 13 + 7) ^ (i >> 1)) & 1;
    }

    uint32_t rand_word_raw = 0;
    uint32_t status_raw = 0;

    uint32_t rand_word_fold = 0;
    uint32_t status_fold = 0;

    trng_core(raw_samples, 256, TRNG_MODE_RAW, rand_word_raw, status_raw);
    trng_core(raw_samples, 256, TRNG_MODE_XOR_FOLD, rand_word_fold, status_fold);

    std::cout << "RAW  rand_word = 0x" << std::hex << rand_word_raw << std::dec << std::endl;
    std::cout << "RAW  status    = 0x" << std::hex << status_raw << std::dec << std::endl;

    std::cout << "FOLD rand_word = 0x" << std::hex << rand_word_fold << std::dec << std::endl;
    std::cout << "FOLD status    = 0x" << std::hex << status_fold << std::dec << std::endl;

    bool ok = true;

    if ((status_raw & TRNG_STATUS_VALID) == 0) {
        std::cout << "RAW mode invalid" << std::endl;
        ok = false;
    }

    if ((status_fold & TRNG_STATUS_VALID) == 0) {
        std::cout << "XOR_FOLD mode invalid" << std::endl;
        ok = false;
    }

    if (rand_word_raw == 0 && rand_word_fold == 0) {
        std::cout << "Both outputs are zero, suspicious test pattern" << std::endl;
        ok = false;
    }

    if (!ok) {
        std::cout << "TB FAIL" << std::endl;
        return 1;
    }

    std::cout << "TB PASS" << std::endl;
    return 0;
}
