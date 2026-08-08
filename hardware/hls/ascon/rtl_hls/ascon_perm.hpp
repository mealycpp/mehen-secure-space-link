#ifndef ASCON_PERM_HPP
#define ASCON_PERM_HPP

#include "ascon_core.hpp"

void ascon_permute(ascon_state_t &s, int rounds);

u64 load64_le(const u8 b[8]);
void store64_le(u8 b[8], u64 x);

#endif
