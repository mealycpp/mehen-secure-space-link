# MEHEN Mission Control v1.0.45

This package is the two-AUP MEHEN mission-control dashboard for the live demo.

## Operator flow

1. **RESET + OPEN F-PRIME**
   - Cleans AUP1 and AUP2.
   - Starts the AUP1 and AUP2 F Prime flight apps/GDS with watchdogs.
   - Opens the local tunnels and browser GUIs.
   - No secure-link packets are sent in this step.

2. **CHECK + PRIME F-PRIME**
   - Runs board-side overlay/TRNG/ASCON KAT/benchmark checks.
   - Sends one safe `SecureLane.secureLaneBridge.GET_KEY128` command through each F Prime GDS tunnel.
   - This populates the F Prime Events panes with `Key128Ready` without auto-bursting HASH/XOF/ROUNDTRIP.

3. **ESTABLISH SECURE CHANNEL**
   - Verifies both MEHEN link-agent receivers.
   - Sends the AUP1 -> AUP2 session probe.
   - Sends one safe F Prime GET_KEY128 pulse afterward so the Events panes show activity for the mission action.

4. **SEND AUP1 TO AUP2**
   - Sends a protected packet from AUP1 to AUP2.
   - Sends one safe F Prime GET_KEY128 pulse afterward.

5. **SEND AUP2 TO AUP1**
   - Sends a protected reply from AUP2 to AUP1.
   - Sends one safe F Prime GET_KEY128 pulse afterward.

6. **TAMPER TEST**
   - Sends a deliberately modified packet.
   - BAD_TAG / rejected packet is the expected result.
   - Sends one safe F Prime GET_KEY128 pulse afterward if the expected reject path completes.

## Ports

- AUP1 flight app: prefer 50000, fallback 50100
- AUP1 GDS web: remote 5000 -> local 5101
- AUP2 flight app: prefer 50100, fallback 50000
- AUP2 GDS web: remote 5001 -> local 5102
- MEHEN link-agent receivers: 9092 on both boards

## Important note

The dashboard packet lane is the two-AUP secure-link visualization. The F Prime Events pane is populated through safe `GET_KEY128` pulses because the current implemented F Prime component exposes GET_KEY128/HASH_TEST/XOF_TEST/ROUNDTRIP, while the link-agent packet operations are external to F Prime. Full packet-specific F Prime events would require adding new SecureLaneBridge events such as `SecurePacketTx`, `SecurePacketRx`, `SecurePacketVerified`, and `BadTagRejected` in the flight software.


## v1.0.45 stability changes

- Link-agent preflight now always restarts the receiver after copying the current agent. This prevents stale `/tmp` receiver processes from running an older protocol.
- `RUN_MEHEN_LINK_ACTION.ps1` is the single stable runner for session/send/tamper/full-demo actions.
- Every link action performs receiver preflight and retries once if a transient socket-close or connection refusal occurs.
- Full demo now performs receiver preflight before each phase, including the AUP2 -> AUP1 reply, which fixes the observed `ConnectionError: socket closed` failure.
- F Prime GET_KEY128 event pulses are non-fatal warnings if the GDS API is temporarily unavailable; the link action itself remains the main pass/fail criterion.


## v1.0.45 updates
- Dashboard event rail now surfaces TRNG/session, AEAD encrypt, and AEAD decrypt/verify events from the link agent.
- Reverse and full-demo visualization supports AUP2 -> AUP1 and bidirectional packet animation.
- Recent-log polling now reads selected logs oldest-to-newest so newest mission events win over stale earlier logs.


## v1.0.45 strict board facts

The CHECK + PRIME step now prints and parses board-side telemetry from each AUP: thermal-zone temperature, load average, uptime, available memory, root-disk use, kernel, PYNQ version, FPGA/zocl presence, and the key port states for F-Prime and MEHEN link agents. The dashboard maps sender/receiver temperatures according to packet direction, so AUP2-to-AUP1 traffic no longer swaps board temperatures.


## v1.0.26 operator-status cleanup

- MISSION STATE no longer says DONE after every action. It now shows phase-specific states such as STACK READY, CHECK OK, LINK READY, TX AUP1, TX AUP2, REJECT OK, and DEMO OK.
- ACTION GATE is the only place that says DONE. DONE means it is safe to press the next button.
- The top status area was split into dedicated visual tiles to avoid redraw artifacts or dark clipping around the status text.


## v1.0.29 update
- Header status tiles widened and centered to remove the dark/clipped STACK READY artifact.
- CHECK + PRIME now sends GET_KEY128 and HASH_TEST safely with settle delay, so F-Prime Events show key and hash activity instead of only repeated TRNG/key events.
- Mission-action F-Prime pulses are action-specific: session uses GET_KEY128, send/full-demo use HASH_TEST. XOF_TEST and ROUNDTRIP remain manual in GDS to avoid prior burst-command health faults.


## v1.0.29 notes
- Replaced status-value labels with borderless text boxes to eliminate WinForms clipping artifacts over MISSION STATE/ACTION GATE.
- Expanded board temperature discovery across thermal zones, hwmon temperature inputs, IIO temperature devices, and lm-sensors fallback.
- Temperature source and candidate count are printed for strict provenance.

## v1.0.31 update
- Replaced Mission State and Action Gate value controls with custom-painted canvas panels.
- This removes the black clipping/redraw band that appeared over STACK RDY/CLEANING/DONE on the Windows display.


## v1.0.31 notes
- Rebuilt the top status header as one owner-drawn panel to remove the status-text clipping/banding artifact.
- CHECK + PRIME sends GET_KEY128 and HASH_TEST. In F-Prime Events, GET_KEY128 is reported by the implemented event Key128Ready / TRNG key ready; HASH_TEST is reported by HashOk.

## v1.0.34 update

The top operator status was simplified to a plain one-line strip:
`STATUS: <state> | GATE: <ready/busy/done/failed> | next-step hint`.
This removes the boxed/stacked status-value rendering path that caused the black band artifact on some Windows/WinForms DPI settings.

F-Prime event mapping is explicit in the dashboard:
- `GET_KEY128` command appears as `SecureLane.secureLaneBridge.Key128Ready` / `TRNG key ready`.
- `HASH_TEST` command appears as `SecureLane.secureLaneBridge.HashOk` / `HASH test passed`.
- `XOF_TEST` and `ROUNDTRIP` remain available manually from the GDS Commanding tab.


## v1.0.34 update

- Shrunk the header subtitle region so it no longer overlaps the plain status strip.
- Shortened the subtitle to keep the title block entirely left of the status area.
- Preserved the plain one-line STATUS/GATE strip and the GET_KEY128 -> Key128Ready / HASH_TEST -> HashOk labels.


## v1.0.34 operator fixes
- Every transient action reports elapsed time and the right panel shows Last action / Action time.
- A hidden live telemetry monitor samples AUP1/AUP2 board facts continuously; right panel updates without waiting for CHECK.
- Added OPTIONAL F-PRIME EVENT SET button moved below the primary demo flow for paced GET_KEY128, HASH_TEST, XOF_TEST, and ROUNDTRIP commands.
- CHECK + PRIME remains the safe default path: board proof plus GET_KEY128/HASH_TEST.


## v1.0.36 update
- Fixed false ACTION FAILED after the F-PRIME EVENT SET when all GDS HTTP commands returned 200.
- Action success now relies on the explicit MEHEN_ACTION_FAILED flag instead of stale PowerShell LASTEXITCODE.
- CHECK + PRIME now reports explicit AUP helper-copy and service-check pass/fail lines.


## v1.0.36 note
The live measurement panel is now proactive: when a mission button is pressed, the panel immediately shows PENDING/RUNNING values for direction, tag, verify, encrypt/decrypt timing, and F-prime pulse state. When link-agent JSON arrives, the panel replaces those placeholders with measured values.


## v1.0.39
- RUN FULL DEMO now summarizes final mission state as DEMO PASS after the intentional tamper packet is rejected.
- BAD_TAG remains in the logs/event rail as evidence, but the dashboard no longer leaves the entire demo in red alert after a successful full demo.


## v1.0.45 note
Adds robust gate completion for CHECK + PRIME and repeated actions so the GUI does not remain BUSY after the board/F-prime proof has passed.


## v1.0.45 primary-flow ordering
- Restores ESTABLISH SECURE CHANNEL as the third operator button.
- Moves full F-prime event set below the main demo flow and labels it OPTIONAL.
- Adds numeric prefixes to the primary buttons so the operator does not accidentally run the optional F-prime event set when expecting the secure-channel step.
