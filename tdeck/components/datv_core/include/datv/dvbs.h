/* DVB-S (ETSI EN 300 421) shared definitions: FEC rates, puncturing, energy dispersal, and the
 * QPSK symbol packing that the transmitters use (4 symbols per byte, first symbol in the lowest
 * bits; per symbol bit 0 = I level, bit 1 = Q level, 1 = +1). Same as app/lib/core/dvb/dvbs.dart. */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum { DVBS_FEC_1_2, DVBS_FEC_2_3, DVBS_FEC_3_4, DVBS_FEC_5_6, DVBS_FEC_7_8, DVBS_FEC_COUNT } dvbs_fec_t;

typedef struct {
    uint8_t len;          /* input bits per puncturing period */
    uint8_t x[7], y[7];   /* 1: the coded bit is sent */
    uint8_t num, den;     /* code rate */
} dvbs_punct_t;

extern const dvbs_punct_t dvbs_punct[DVBS_FEC_COUNT];
extern const char *const dvbs_fec_name[DVBS_FEC_COUNT];

/* Useful TS bit rate at a symbol rate. */
double dvbs_ts_rate(double baud, dvbs_fec_t fec);

/* PRBS 1 + x^14 + x^15, init 100101010000000: the 1503 bytes of one 8-packet group. */
const uint8_t *dvbs_prbs(void);

#define DVBS_PKT 188
#define DVBS_CW 204
#define DVBS_IL_I 12
#define DVBS_IL_DEPTH (DVBS_CW * (DVBS_IL_I - 1))   /* 2244 bytes of interleaver memory */
