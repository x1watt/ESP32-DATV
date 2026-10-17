/* DVB-S encoder: TS packets to packed QPSK symbols (port of app/lib/core/dvb/dvbs.dart). */
#pragma once
#include "datv/dvbs.h"

typedef struct {
    const dvbs_punct_t *p;
    bool swap_iq, invert;
    uint32_t pkt;                  /* packets so far (mod 8 selects the inverted sync byte) */
    uint8_t ring[4096];            /* interleaver input history, indexed by the byte counter */
    uint32_t t;                    /* interleaver bytes so far */
    uint32_t cstate, cpos;         /* convolutional encoder state, puncturing position */
    int pend_bit;                  /* -1: no pending I bit */
    uint32_t pend_sym, pend_n;     /* symbols waiting for a full byte */
} dvbs_enc_t;

void dvbs_enc_init(dvbs_enc_t *e, dvbs_fec_t fec, bool swap_iq, bool invert);
/* Upper bound of output bytes for n packets. */
static inline size_t dvbs_enc_max_out(size_t npkt) { return npkt * DVBS_CW * 2 + 2; }
/* n whole packets (each starting with 0x47) -> packed symbols; returns the number of bytes written. */
size_t dvbs_enc(dvbs_enc_t *e, const uint8_t *ts, size_t npkt, uint8_t *out);
