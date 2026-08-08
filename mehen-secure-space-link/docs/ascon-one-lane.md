# ASCON in MEHEN: one lane, four services

ASCON uses one shared permutation structure that can support hashing, XOF, authenticated encryption, and authenticated decryption. MEHEN uses this to avoid four separate fixed-function accelerators.

## Main idea

- Internal state: 320 bits, five 64-bit words.
- Round structure: constants, substitution, diffusion.
- Runtime selection: mode and length registers determine whether the lane behaves as HASH, XOF, AEAD encryption, or AEAD decryption.

## Why this matters

On a small satellite payload or constrained FPGA fabric, reusing one lane reduces area pressure and creates one consistent software-visible service path.
