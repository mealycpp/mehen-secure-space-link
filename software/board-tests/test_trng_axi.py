#!/usr/bin/env python3
from pynq import Overlay, MMIO
import time
import sys

BIT = "/home/xilinx/spaccomputing/ascon_zu3_system_wrapper.bit"
IP_NAME = "trng_axi_0"

REG_CTRL       = 0x00   # bit0 = enable
REG_MODE       = 0x04   # bits[1:0]
REG_SAMPLE_DIV = 0x08   # bits[7:0]
REG_STATUS     = 0x0C   # bit0 valid, bit1 health_fail
REG_RAND_WORD  = 0x10   # [31:0]

MODE_LOW       = 0
MODE_BALANCED  = 1
MODE_HIGH      = 2

def main() -> int:
    ol = Overlay(BIT, download=False)

    if IP_NAME not in ol.ip_dict:
        print(f"ERROR: {IP_NAME} not found")
        print("Available IPs:", list(ol.ip_dict.keys()))
        return 1

    meta = ol.ip_dict[IP_NAME]
    base = meta["phys_addr"]
    span = meta["addr_range"]

    print(f"Using {IP_NAME} @ 0x{base:08X}, span=0x{span:X}")

    mmio = MMIO(base, span)

    # Clean start
    mmio.write(REG_CTRL, 0x0)
    mmio.write(REG_MODE, MODE_HIGH)
    mmio.write(REG_SAMPLE_DIV, 255)
    time.sleep(0.05)

    # Enable
    mmio.write(REG_CTRL, 0x1)
    time.sleep(0.50)

    words = []
    health_fail_seen = False
    valid_seen = False

    for i in range(64):
        status = mmio.read(REG_STATUS)
        word   = mmio.read(REG_RAND_WORD)

        valid = (status >> 0) & 0x1
        health_fail = (status >> 1) & 0x1

        if valid:
            valid_seen = True
        if health_fail:
            health_fail_seen = True

        words.append(word)
        print(f"{i:02d}: status=0x{status:08X} rand=0x{word:08X}")
        time.sleep(0.05)

    mmio.write(REG_CTRL, 0x0)

    unique_words = len(set(words))
    first = words[0]
    all_same = all(w == first for w in words)

    print()
    print(f"unique_words   = {unique_words}")
    print(f"valid_seen     = {valid_seen}")
    print(f"health_fail    = {health_fail_seen}")

    if all_same:
        print("FAIL: RAND_WORD appears stuck")
        return 1

    if unique_words < 8:
        print("FAIL: too few unique words")
        return 1

    if health_fail_seen:
        print("FAIL: health_fail asserted")
        return 1

    print("PASS: TRNG AXI smoke test looks alive")
    return 0

if __name__ == "__main__":
    sys.exit(main())
