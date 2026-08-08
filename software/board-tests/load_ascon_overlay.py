#!/usr/bin/env python3
from pathlib import Path
import shutil
import sys

OVERLAY_DIR = Path("/home/xilinx/spaccomputing")


def main() -> int:
    try:
        from pynq import Overlay
    except Exception as e:
        print(f"ERROR: could not import pynq. {e}")
        return 1

    if not OVERLAY_DIR.exists():
        print(f"ERROR: overlay directory does not exist: {OVERLAY_DIR}")
        return 1

    bit_files = sorted(OVERLAY_DIR.glob("*.bit"))
    hwh_files = sorted(OVERLAY_DIR.glob("*.hwh"))

    if not bit_files:
        print(f"ERROR: no .bit file found in {OVERLAY_DIR}")
        return 1

    if not hwh_files:
        print(f"ERROR: no .hwh file found in {OVERLAY_DIR}")
        return 1

    if len(bit_files) > 1:
        print("ERROR: multiple .bit files found:")
        for f in bit_files:
            print(f"  - {f.name}")
        return 1

    if len(hwh_files) > 1:
        print("ERROR: multiple .hwh files found:")
        for f in hwh_files:
            print(f"  - {f.name}")
        return 1

    bit_path = bit_files[0]
    hwh_path = hwh_files[0]
    expected_hwh = bit_path.with_suffix(".hwh")

    print(f"Found bit: {bit_path.name}")
    print(f"Found hwh: {hwh_path.name}")

    if hwh_path.name != expected_hwh.name:
        print(f"Creating matching HWH: {expected_hwh.name}")
        shutil.copy2(hwh_path, expected_hwh)
    else:
        print("HWH name already matches BIT name.")

    print(f"Loading overlay: {bit_path}")
    ol = Overlay(str(bit_path), download=True)

    print("Overlay loaded successfully.")
    print(f"BIT: {bit_path.name}")
    print(f"HWH: {expected_hwh.name}")

    try:
        ip_dict = ol.ip_dict
        if ip_dict:
            print("Discovered IP blocks:")
            for name, meta in ip_dict.items():
                phys = meta.get("phys_addr", "N/A")
                addr = meta.get("addr_range", "N/A")
                print(f"  - {name}: phys_addr={phys}, addr_range={addr}")
        else:
            print("No IP blocks reported in ip_dict.")
    except Exception as e:
        print(f"WARNING: overlay loaded, but could not print ip_dict. {e}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
