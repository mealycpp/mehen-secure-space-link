#!/usr/bin/env python3
from pynq import Overlay, MMIO, allocate
import numpy as np
import os
import sys
import time

BIT = "/home/xilinx/spaccomputing/ascon_zu3_system_wrapper.bit"
KAT_DIR = "/home/xilinx/spaccomputing/KAT"

ASCON_IP = "ascon_core_0"
DMA_IP   = "axi_dma_0"

MODE_HASH      = 0
MODE_XOF       = 1
MODE_AEAD_ENC  = 2
MODE_AEAD_DEC  = 3

REG_AP_CTRL = 0x00
REG_IN_LEN  = 0x10
REG_AD_LEN  = 0x18
REG_OUT_LEN = 0x20
REG_MODE    = 0x28
REG_STATUS  = 0x30

MAX_MSG = 64
MAX_AD  = 64
MAX_PT  = 64
MAX_CT  = 80
MAX_OUT = 80

HASH_KAT_FILE = os.path.join(KAT_DIR, "LWC_HASH_KAT_128_256.txt")
AEAD_KAT_FILE = os.path.join(KAT_DIR, "LWC_AEAD_KAT_128_128.txt")


def trim(s: str) -> str:
    return s.strip(" \t\r\n")


def hexs(b: bytes) -> str:
    return "".join(f"{x:02x}" for x in b)


def hex_to_bytes(s: str) -> bytes:
    s = trim(s)
    return bytes.fromhex(s) if s else b""


def sync_to_dev(buf):
    if hasattr(buf, "sync_to_device"):
        buf.sync_to_device()
    elif hasattr(buf, "flush"):
        buf.flush()


def sync_from_dev(buf):
    if hasattr(buf, "sync_from_device"):
        buf.sync_from_device()
    elif hasattr(buf, "invalidate"):
        buf.invalidate()


def free_buf(buf):
    if buf is not None and hasattr(buf, "freebuffer"):
        buf.freebuffer()


def open_overlay():
    try:
        return Overlay(BIT, download=False)
    except Exception:
        return Overlay(BIT, download=True, ignore_version=True)


def check_overlay(ol):
    if ASCON_IP not in ol.ip_dict:
        raise RuntimeError(f"Missing IP '{ASCON_IP}' in overlay")
    if not hasattr(ol, DMA_IP):
        raise RuntimeError(f"Missing DMA '{DMA_IP}' in overlay")


def wait_for_done(mmio, timeout_sec=2.0):
    t0 = time.time()
    while True:
        ap = mmio.read(REG_AP_CTRL)
        done = (ap >> 1) & 0x1
        idle = (ap >> 2) & 0x1
        if done or idle:
            return
        if (time.time() - t0) > timeout_sec:
            raise RuntimeError("ASCON core timeout waiting for ap_done/ap_idle")


def run_dma_job(ol, tx_bytes: bytes, in_len: int, ad_len: int, out_len: int, mode: int):
    dma = getattr(ol, DMA_IP)
    ascon_meta = ol.ip_dict[ASCON_IP]
    mmio = MMIO(ascon_meta["phys_addr"], ascon_meta["addr_range"])

    tx_buf = None
    rx_buf = None

    tx_len = len(tx_bytes)
    if out_len < 0:
        raise RuntimeError("out_len must be non-negative")
    if in_len < 0 or ad_len < 0:
        raise RuntimeError("in_len/ad_len must be non-negative")

    try:
        tx_buf = allocate(shape=(max(1, tx_len),), dtype=np.uint8)
        rx_buf = allocate(shape=(max(1, out_len),), dtype=np.uint8)

        tx_buf[:] = 0
        rx_buf[:] = 0

        if tx_len > 0:
            tx_buf[:tx_len] = np.frombuffer(tx_bytes, dtype=np.uint8)
            sync_to_dev(tx_buf)

        mmio.write(REG_IN_LEN,  int(in_len))
        mmio.write(REG_AD_LEN,  int(ad_len))
        mmio.write(REG_OUT_LEN, int(out_len))
        mmio.write(REG_MODE,    int(mode))

        if out_len > 0:
            dma.recvchannel.transfer(rx_buf)

        if tx_len > 0:
            dma.sendchannel.transfer(tx_buf)

        mmio.write(REG_AP_CTRL, 0x01)

        if tx_len > 0:
            dma.sendchannel.wait()

        if out_len > 0:
            dma.recvchannel.wait()
            sync_from_dev(rx_buf)

        wait_for_done(mmio)
        status = int(mmio.read(REG_STATUS))

        out_bytes = bytes(rx_buf[:out_len]) if out_len > 0 else b""
        return out_bytes, status

    finally:
        free_buf(tx_buf)
        free_buf(rx_buf)


def load_hash_kats(path: str):
    if not os.path.exists(path):
        raise RuntimeError(f"Cannot open HASH KAT file: {path}")

    kats = []
    cur = {"count": -1, "msg": b"", "md": b""}

    with open(path, "r") as f:
        for line in f:
            line = trim(line)

            if not line:
                if cur["count"] >= 0:
                    kats.append(cur)
                    cur = {"count": -1, "msg": b"", "md": b""}
                continue

            if line.startswith("Count = "):
                cur["count"] = int(line[8:])
            elif line.startswith("Msg = "):
                cur["msg"] = hex_to_bytes(line[6:])
            elif line.startswith("MD = "):
                cur["md"] = hex_to_bytes(line[5:])

    if cur["count"] >= 0:
        kats.append(cur)

    return kats


def load_aead_kats(path: str):
    if not os.path.exists(path):
        raise RuntimeError(f"Cannot open AEAD KAT file: {path}")

    kats = []
    cur = {
        "count": -1,
        "key": b"",
        "nonce": b"",
        "ad": b"",
        "pt": b"",
        "ct": b"",
    }

    with open(path, "r") as f:
        for line in f:
            line = trim(line)

            if not line:
                if cur["count"] >= 0:
                    kats.append(cur)
                    cur = {
                        "count": -1,
                        "key": b"",
                        "nonce": b"",
                        "ad": b"",
                        "pt": b"",
                        "ct": b"",
                    }
                continue

            if line.startswith("Count = "):
                cur["count"] = int(line[8:])
            elif line.startswith("Key = "):
                cur["key"] = hex_to_bytes(line[6:])
            elif line.startswith("Nonce = "):
                cur["nonce"] = hex_to_bytes(line[8:])
            elif line.startswith("AD = "):
                cur["ad"] = hex_to_bytes(line[5:])
            elif line.startswith("PT = "):
                cur["pt"] = hex_to_bytes(line[5:])
            elif line.startswith("CT = "):
                cur["ct"] = hex_to_bytes(line[5:])

    if cur["count"] >= 0:
        kats.append(cur)

    return kats


def run_hash_kats(ol):
    print(f"Using HASH KAT file: {HASH_KAT_FILE}")
    kats = load_hash_kats(HASH_KAT_FILE)
    print(f"Loaded HASH KAT count = {len(kats)}")

    if not kats:
        raise RuntimeError("No HASH KATs loaded")

    tested = 0
    skipped = 0

    for kat in kats:
        count = kat["count"]
        msg = kat["msg"]
        md  = kat["md"]

        if count < 0:
            raise RuntimeError("Malformed HASH KAT entry")

        if len(msg) > MAX_MSG:
            skipped += 1
            continue

        if len(md) != 32:
            raise RuntimeError(f"Bad HASH digest length at Count={count}: got {len(md)}")

        out, status = run_dma_job(
            ol=ol,
            tx_bytes=msg,
            in_len=len(msg),
            ad_len=0,
            out_len=32,
            mode=MODE_HASH,
        )

        if status != 0:
            raise RuntimeError(f"HASH status FAIL at Count={count}, status={status}")

        if out != md:
            raise RuntimeError(
                f"HASH KAT FAIL at Count={count}\n"
                f"Expected: {hexs(md)}\n"
                f"Got     : {hexs(out)}"
            )

        tested += 1
        if (tested % 100) == 0:
            print(f"  HASH progress: tested={tested}, skipped={skipped}")

    print(f"HASH KAT PASS, tested {tested} cases, skipped {skipped} cases (>64-byte messages)")


def run_aead_enc_kats(ol):
    print(f"Using AEAD KAT file for encrypt: {AEAD_KAT_FILE}")
    kats = load_aead_kats(AEAD_KAT_FILE)
    print(f"Loaded AEAD KAT count = {len(kats)}")

    if not kats:
        raise RuntimeError("No AEAD KATs loaded")

    tested = 0
    skipped = 0

    for kat in kats:
        count = kat["count"]
        key   = kat["key"]
        nonce = kat["nonce"]
        ad    = kat["ad"]
        pt    = kat["pt"]
        ct    = kat["ct"]

        if count < 0:
            raise RuntimeError("Malformed AEAD KAT entry")

        if len(key) != 16:
            raise RuntimeError(f"Bad key size at Count={count}: {len(key)}")
        if len(nonce) != 16:
            raise RuntimeError(f"Bad nonce size at Count={count}: {len(nonce)}")
        if len(ad) > MAX_AD or len(pt) > MAX_PT:
            skipped += 1
            continue
        if len(ct) != (len(pt) + 16):
            raise RuntimeError(
                f"Bad ciphertext/tag size at Count={count}, "
                f"expected {len(pt) + 16}, got {len(ct)}"
            )

        tx = key + nonce + ad + pt

        out, status = run_dma_job(
            ol=ol,
            tx_bytes=tx,
            in_len=len(pt),
            ad_len=len(ad),
            out_len=len(pt) + 16,
            mode=MODE_AEAD_ENC,
        )

        if status != 0:
            raise RuntimeError(f"AEAD ENC status FAIL at Count={count}, status={status}")

        if out != ct:
            raise RuntimeError(
                f"AEAD ENC KAT FAIL at Count={count}\n"
                f"Expected: {hexs(ct)}\n"
                f"Got     : {hexs(out)}"
            )

        tested += 1
        if (tested % 100) == 0:
            print(f"  AEAD ENC progress: tested={tested}, skipped={skipped}")

    print(f"AEAD ENC KAT PASS, tested {tested} cases, skipped {skipped} cases (>64-byte AD/PT)")


def run_aead_dec_kats(ol):
    print(f"Using AEAD KAT file for decrypt: {AEAD_KAT_FILE}")
    kats = load_aead_kats(AEAD_KAT_FILE)
    print(f"Loaded AEAD KAT count = {len(kats)}")

    if not kats:
        raise RuntimeError("No AEAD KATs loaded")

    tested = 0
    skipped = 0

    for kat in kats:
        count = kat["count"]
        key   = kat["key"]
        nonce = kat["nonce"]
        ad    = kat["ad"]
        pt    = kat["pt"]
        ct    = kat["ct"]

        if count < 0:
            raise RuntimeError("Malformed AEAD KAT entry")

        if len(key) != 16:
            raise RuntimeError(f"Bad key size at Count={count}: {len(key)}")
        if len(nonce) != 16:
            raise RuntimeError(f"Bad nonce size at Count={count}: {len(nonce)}")
        if len(ad) > MAX_AD or len(pt) > MAX_PT:
            skipped += 1
            continue
        if len(ct) < 16 or len(ct) > MAX_CT:
            skipped += 1
            continue
        if len(ct) != (len(pt) + 16):
            raise RuntimeError(
                f"Bad ciphertext/tag size at Count={count}, "
                f"expected {len(pt) + 16}, got {len(ct)}"
            )

        tx = key + nonce + ad + ct

        out, status = run_dma_job(
            ol=ol,
            tx_bytes=tx,
            in_len=len(ct),
            ad_len=len(ad),
            out_len=len(pt),
            mode=MODE_AEAD_DEC,
        )

        if status != 0:
            raise RuntimeError(f"AEAD DEC status FAIL at Count={count}, status={status}")

        if out != pt:
            raise RuntimeError(
                f"AEAD DEC KAT FAIL at Count={count}\n"
                f"Expected: {hexs(pt)}\n"
                f"Got     : {hexs(out)}"
            )

        tested += 1
        if (tested % 100) == 0:
            print(f"  AEAD DEC progress: tested={tested}, skipped={skipped}")

    print(f"AEAD DEC KAT PASS, tested {tested} cases, skipped {skipped} cases (>64-byte AD/PT or oversized CT)")


def main():
    which = "all"
    if len(sys.argv) > 1:
        which = sys.argv[1].strip().lower()

    print(f"Opening overlay: {BIT}")
    ol = open_overlay()
    check_overlay(ol)

    if which in ("all", "hash"):
        run_hash_kats(ol)

    if which in ("all", "aead-enc", "aead_enc", "enc"):
        run_aead_enc_kats(ol)

    if which in ("all", "aead-dec", "aead_dec", "dec"):
        run_aead_dec_kats(ol)

    print("ALL REQUESTED KATS PASSED")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"FAIL: {e}")
        sys.exit(1)
