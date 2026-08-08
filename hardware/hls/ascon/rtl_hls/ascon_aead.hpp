#ifndef ASCON_AEAD_HPP
#define ASCON_AEAD_HPP

#include "ascon_core.hpp"

void ascon_aead128_encrypt(
    const u8 key[16],
    const u8 nonce[16],
    const u8 ad[64],
    const u8 pt[64],
    u8 ct[80],
    uint32_t ad_len,
    uint32_t pt_len
);

bool ascon_aead128_decrypt(

	const u8 key[16],
	const u8 nonce[16],
	const u8 ad[64],
	const u8 ct_and_tag[80],
	      u8 pt[80],
		  uint32_t ad_len,
		  uint32_t ct_len

);



#endif
