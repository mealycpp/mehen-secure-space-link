<div align="center">
  <img src="assets/logos/rscl-logo.png" alt="RSCL logo" width="150"/>

# MEHEN Secure Space-Link

### F′-Visible TRNG + ASCON Secure Services on AUP-ZU3

[![Platform](https://img.shields.io/badge/platform-AUP--ZU3-0B5FFF?style=for-the-badge)](#hardware-requirements)
[![Flight Software](https://img.shields.io/badge/flight_software-NASA_JPL_F′-00A86B?style=for-the-badge)](#fprime-command--event-map)
[![Crypto](https://img.shields.io/badge/crypto-ASCON_AEAD_HASH_XOF-F59E0B?style=for-the-badge)](#why-ascon)
[![Entropy](https://img.shields.io/badge/entropy-TRNG-7C3AED?style=for-the-badge)](#what-this-repository-demonstrates)
[![Demo](https://img.shields.io/badge/demo-two_AUP_secure_link-E11D48?style=for-the-badge)](#live-demo-flow)

**MEHEN turns a TRNG + multi-mode ASCON hardware lane into a commandable, observable flight-software service and visualizes a two-node secure space-link demonstration.**

</div>

---

## What this repository demonstrates

MEHEN is a runtime-reconfigurable hardware-security architecture for space-flight software. It integrates:

- a board-resident **TRNG entropy service**,
- a **multi-mode ASCON lane** for hash, XOF, AEAD encryption, and AEAD decryption,
- a DMA/FIFO-backed service path,
- an F′ `SecureLaneBridge` command/event interface,
- and a Windows mission-control dashboard for a **two-AUP secure-link demonstration**.

The repository is organized around a live demo: AUP1 and AUP2 run F′/MEHEN stacks, expose F′ events, exchange protected packets through a demo link agent, and visibly reject a tampered packet with `BAD_TAG`.

> Honest scope: the published MEHEN paper demonstrates the single AUP-ZU3 flight-software-visible service path. The two-AUP dashboard extends that service into a visual secure-link demonstration for presentation and integration testing.

---

## Architecture

```mermaid
flowchart LR
    GDS[Laptop Ground Station / F′ GDS] -->|TCP/IP command| FSW[F′ Flight Software]
    FSW --> BR[SecureLaneBridge]
    BR --> BE[Backend Service Layer]
    BE --> DMA[DMA/FIFO Service Path]
    DMA --> TRNG[TRNG entropy service]
    DMA --> ASCON[Multi-mode ASCON lane]
    ASCON --> OUT[Hash / XOF / AEAD enc / AEAD dec]
    OUT -. events + telemetry .-> GDS
```

### Two-AUP demonstration path

```mermaid
flowchart LR
    A1[AUP1 Space Node\nF′ + TRNG + ASCON] <-->|ciphertext + tag / BAD_TAG rejection| A2[AUP2 Space Node\nF′ + TRNG + ASCON]
    A1 -. F′ events .-> G1[Local GDS 5101]
    A2 -. F′ events .-> G2[Local GDS 5102]
```

---

## Why ASCON

ASCON maps naturally to a single runtime-selectable lane:

| Service | Shared ASCON behavior | MEHEN role |
|---|---|---|
| Hash | absorb message, squeeze digest | `HASH_TEST` |
| XOF | absorb message, squeeze variable output | `XOF_TEST` |
| AEAD encrypt | absorb AD/plaintext, output ciphertext + tag | link/demo + `ROUNDTRIP` |
| AEAD decrypt | verify tag before accepting plaintext | link/demo + tamper rejection |

MEHEN changes mode and length controls. It does **not** require partial FPGA reconfiguration or four replicated datapaths.

---

## F′ command / event map

| F′ command | Service meaning | Expected F′ event |
|---|---|---|
| `SecureLane.secureLaneBridge.GET_KEY128` | TRNG-backed key material | `Key128Ready` |
| `SecureLane.secureLaneBridge.HASH_TEST` | ASCON hash service | `HashOk` |
| `SecureLane.secureLaneBridge.XOF_TEST` | ASCON XOF service | `XofOk` |
| `SecureLane.secureLaneBridge.ROUNDTRIP` | AEAD encrypt/decrypt/tag verification | `RoundTripOk` |

---

## Live demo flow

Operator flow in the dashboard:

1. **RESET + OPEN F-PRIME**  
   Cleans both AUPs, starts both F′ stacks, opens GDS windows.

2. **CHECK + PRIME F-PRIME**  
   Runs board proof: overlay, TRNG, ASCON KATs, benchmark, and safe F′ events.

3. **ESTABLISH SECURE CHANNEL**  
   Starts/refreshes link receivers and generates a session probe.

4. **SEND AUP1 TO AUP2**  
   Shows ciphertext + tag movement and verification.

5. **SEND AUP2 TO AUP1**  
   Shows reverse secure reply.

6. **TAMPER TEST**  
   Flips protected data/AAD and confirms `BAD_TAG` rejection.

7. **RUN FULL DEMO**  
   Runs session + bidirectional packets + tamper rejection.

8. **OPTIONAL F-PRIME EVENT SET**  
   Issues `GET_KEY128`, `HASH_TEST`, `XOF_TEST`, and `ROUNDTRIP` to both AUP GDS instances.

---

## Quick start

### Windows host

Open PowerShell from:

```powershell
cd dashboard/windows
.\RUN_MEHEN_MISSION_CONTROL.bat
```

The dashboard expects:

| Node | SSH user | Address | GDS tunnel |
|---|---:|---:|---:|
| AUP1 | `xilinx` | `100.116.148.59` | `http://127.0.0.1:5101/` |
| AUP2 | `xilinx` | `100.71.108.15` | `http://127.0.0.1:5102/` |

### AUP-side expected project path

```bash
~/spaccomputing
~/spaccomputing/SecureLane
```

---

## Dashboard package

The current Windows mission-control package is stored at:

```text
dashboard/windows/
```

Main entry point:

```text
dashboard/windows/RUN_MEHEN_MISSION_CONTROL.bat
```

Key files:

| File | Purpose |
|---|---|
| `MEHEN_Mission_Control.ps1` | Main WinForms dashboard |
| `START_AUP1_FPRIME.ps1` | Launch AUP1 F′ stack/watchdog |
| `START_AUP2_FPRIME.ps1` | Launch AUP2 F′ stack/watchdog |
| `OPEN_BOTH_FPRIME_GUIS.ps1` | GDS tunnel/browser helper |
| `RUN_MEHEN_LINK_ACTION.ps1` | Secure-link action runner |
| `mehen_secure_link_agent.py` | Two-node demo link agent |
| `mehen_remote_control.sh` | Board-side MEHEN service checker |
| `fprime_watchdog_remote.sh` | Remote F′ app/GDS watchdog |

---

## Evidence expected during demo

### Board/service proof

The dashboard should report:

```text
OVERLAY=PASS
TRNG=PASS
ASCON_KAT=PASS
BENCH=PASS
SERVICE_CHECK=PASS
```

### F′ event proof

The F′ event panes should show:

```text
Key128Ready
HashOk
XofOk
RoundTripOk
```

### Secure-link proof

The dashboard event rail should show:

```text
TRNG_SESSION_READY
AEAD_ENCRYPT_DONE
AEAD_DECRYPT_VERIFY_PASS
AEAD_DECRYPT_VERIFY_BAD_TAG_REJECT
```

---

## Known limitations and honest boundaries

- The MEHEN paper result is a single AUP-ZU3 flight-software-visible security service.
- The two-AUP dashboard is a presentation/integration extension around that service.
- The TRNG evidence in this repository is board-level smoke testing, not a full NIST SP 800-90B entropy-source assessment.
- The demo link agent visualizes protected packet exchange and tag rejection; the F′ component path is separately exercised through `SecureLaneBridge` commands and events.
- Full mission deployment would require additional authentication, operational hardening, and sustained-load testing.

---

## Citation

```bibtex
@inproceedings{elhadedy2026mehen,
  title        = {MEHEN: A Runtime-Reconfigurable Security Architecture for Space Flight Software},
  author       = {El-Hadedy, Mohamed},
  booktitle    = {IEEE SMC-IT/SCC 2026},
  year         = {2026},
  note         = {Space Computing, Pasadena, CA}
}
```

---

## Acknowledgments

This work is gratefully supported by:

- **U.S. Navy Naval Engineering Education Center (NEEC)**
- **ONR Summer Faculty Research Program (SFRP)**
- **Air Force Research Laboratory (AFRL)**
- **U.S. Department of Defense**
- **AMD Adaptive Computing** as platform partner through the AUP-ZU3 platform

The views and conclusions are those of the author and do not necessarily represent the official policies or endorsements of the sponsors.

---

<div align="center">

**MEHEN: make hardware security commandable, observable, and flight-software visible.**

</div>
