# MEHEN live demo guide

## Operator flow

1. RESET + OPEN F-PRIME
2. CHECK + PRIME F-PRIME
3. ESTABLISH SECURE CHANNEL
4. SEND AUP1 TO AUP2
5. SEND AUP2 TO AUP1
6. TAMPER TEST
7. RUN FULL DEMO
8. OPTIONAL F-PRIME EVENT SET

Wait for `GATE: DONE` before pressing the next button.

## What to show the audience

- Two F′ GDS windows: AUP1 and AUP2.
- Mission Control dashboard: board facts, temperatures, ports, TRNG state, service latency.
- F′ Events: Key128Ready, HashOk, XofOk, RoundTripOk.
- Secure-link animation: ciphertext + tag, bidirectional packet flow, BAD_TAG rejection.
