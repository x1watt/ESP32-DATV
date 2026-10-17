/* Reed-Solomon RS(204,188, t = 8) over GF(256) with x^8 + x^4 + x^3 + x^2 + 1, generator roots
 * a^0..a^15 (DVB), a shortened RS(255,239). */
#pragma once
#include <stdint.h>

void rs_parity(const uint8_t *data188, uint8_t *parity16);
/* Corrects cw[204] in place. Returns the number of corrected bytes, or -1 if uncorrectable. */
int rs_decode(uint8_t *cw);
