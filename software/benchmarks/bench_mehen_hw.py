#!/usr/bin/env python3
from pynq import Overlay, MMIO, allocate
import numpy as np
import time
import csv
import statistics as st

BIT = "/home/xilinx/spaccomputing/ascon_zu3_system_wrapper.bit"
OUT_CSV = "/home/xilinx/spaccomputing/mehen_service_times.csv"

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

N_WARM = 10
N_RUNS = 200

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

def open_overlay():
    try:
        return Overlay(BIT, download=False)
    except Exception:
        return Overlay(BIT, download=True, ignore_version=True)

def run_dma_job(ol, tx_bytes: bytes, in_len: int, ad_len: int, out_len: int, mode: int):
    dma = getattr(ol, DMA_IP)
    meta = ol.ip_dict[ASCON_IP]
    mmio = MMIO(meta["phys_addr"], meta["addr_range"])

    tx = None
    rx = None

    try:
        if len(tx_bytes) > 0:
            tx = allocate(shape=(len(tx_bytes),), dtype=np.uint8)
            tx[:] = np.frombuffer(tx_bytes, dtype=np.uint8)
            sync_to_dev(tx)

        rx = allocate(shape=(out_len,), dtype=np.uint8)
        rx[:] = 0
        sync_to_dev(rx)

        mmio.write(REG_IN_LEN,  in_len)
        mmio.write(REG_AD_LEN,  ad_len)
        mmio.write(REG_OUT_LEN, out_len)
        mmio.write(REG_MODE,    mode)

        t0 = time.perf_counter()

        dma.recvchannel.transfer(rx)
        mmio.write(REG_AP_CTRL, 0x01)

        if tx is not None:
            dma.sendchannel.transfer(tx)
            dma.sendchannel.wait()

        dma.recvchannel.wait()
        sync_from_dev(rx)

        dt_ms = (time.perf_counter() - t0) * 1000.0
        status = mmio.read(REG_STATUS)
        got = bytes(rx[:out_len])

        return got, status, dt_ms

    finally:
        try:
            if tx is not None:
                tx.freebuffer()
        except Exception:
            pass
        try:
            if rx is not None:
                rx.freebuffer()
        except Exception:
            pass

def pct(vals, p):
    if not vals:
        return 0.0
    s = sorted(vals)
    idx = int(round((p / 100.0) * (len(s) - 1)))
    return s[idx]

def bench_case(ol, name, tx, in_len, ad_len, out_len, mode):
    times = []
    for _ in range(N_WARM):
        _, status, _ = run_dma_job(ol, tx, in_len, ad_len, out_len, mode)
        if status != 0:
            raise RuntimeError(f"{name}: warmup status={status}")

    for _ in range(N_RUNS):
        _, status, dt_ms = run_dma_job(ol, tx, in_len, ad_len, out_len, mode)
        if status != 0:
            raise RuntimeError(f"{name}: status={status}")
        times.append(dt_ms)
    return times

def main():
    ol = open_overlay()

    key   = bytes.fromhex("000102030405060708090a0b0c0d0e0f")
    nonce = bytes.fromhex("101112131415161718191a1b1c1d1e1f")
    ad    = bytes.fromhex("a1a2a3a4")
    pt    = bytes.fromhex("112233445566")
    msg   = bytes.fromhex("00")

    hash_tx = msg
    xof_tx  = msg
    enc_tx  = key + nonce + ad + pt

    ct, status, _ = run_dma_job(ol, enc_tx, len(pt), len(ad), len(pt) + 16, MODE_AEAD_ENC)
    if status != 0:
        raise RuntimeError(f"seed enc status={status}")

    dec_tx = key + nonce + ad + ct

    data = {
        "HASH":     bench_case(ol, "HASH",     hash_tx, len(msg), 0,        32,          MODE_HASH),
        "XOF":      bench_case(ol, "XOF",      xof_tx,  len(msg), 0,        64,          MODE_XOF),
        "AEAD_ENC": bench_case(ol, "AEAD_ENC", enc_tx,  len(pt),  len(ad),  len(pt)+16, MODE_AEAD_ENC),
        "AEAD_DEC": bench_case(ol, "AEAD_DEC", dec_tx,  len(ct),  len(ad),  len(pt),    MODE_AEAD_DEC),
    }

    with open(OUT_CSV, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["service", "iter", "ms"])
        for service, vals in data.items():
            for i, v in enumerate(vals, start=1):
                w.writerow([service, i, f"{v:.6f}"])

    print(f"Wrote {OUT_CSV}")
    for service, vals in data.items():
        print(
            f"{service}: n={len(vals)} mean_ms={st.mean(vals):.6f} "
            f"p50_ms={st.median(vals):.6f} p95_ms={pct(vals,95):.6f} max_ms={max(vals):.6f}"
        )

if __name__ == "__main__":
    main()
