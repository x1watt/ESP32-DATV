/* DVB-S receiver back end: soft QPSK symbols to transport stream packets.
 *
 * Acquisition tries every code rate (or only the configured one), every puncturing phase and the
 * QPSK phase ambiguities on a block of symbols, and keeps the one with the best Viterbi metric.
 * Then: Viterbi, byte and packet sync on the sync bytes (0x47, and 0xB8 every 8th packet; an
 * inverted stream from a 180 degree ambiguity is recognised by its inverted sync bytes), Forney
 * deinterleaver, RS(204,188), energy dispersal removal. Packets that RS cannot correct are passed
 * on with transport_error_indicator set. */
#pragma once
#include "datv/dvbs.h"
#include "datv/viterbi.h"

#define DVBS_RX_ACQ 2048u                     /* symbols per acquisition attempt */

typedef void (*dvbs_rx_packet_fn)(void *ctx, const uint8_t *pkt188);

typedef struct {
    int8_t i, q;
} dvbs_soft_t;

typedef struct {
    /* configuration */
    int fec_fixed;                            /* -1: search all rates */
    dvbs_rx_packet_fn on_packet;
    void *ctx;
    /* acquisition */
    dvbs_soft_t acq[DVBS_RX_ACQ];
    uint32_t nacq;
    bool locked;
    dvbs_fec_t fec;
    uint32_t rot;                             /* 0: as received, 1: rotated by 90 degrees */
    bool swap;                                /* I and Q exchanged */
    uint32_t cpos_bit;                        /* position in the coded-bit sequence of the pattern */
    double quality;                           /* Viterbi metric of the chosen hypothesis */
    uint32_t banned[16], nbanned;             /* hypotheses that locked the code but never gave byte sync */
    /* decoding */
    vit_t vit;
    uint32_t pat_k;                           /* next index into the coded-bit sequence */
    int sx;                                   /* X soft value of the current input bit */
    uint32_t sreg;                            /* last decoded bits (byte sync) */
    uint32_t nbits;                           /* bits since the last byte boundary (when synced) */
    bool byte_sync, inverted;
    uint32_t sync_miss;
    uint32_t bitpos;                          /* decoded bits since lock, mod 1632 while searching */
    uint32_t bits_unsynced;                   /* decoded bits without byte sync */
    uint8_t cnt[DVBS_CW * 8];                 /* per bit phase: consecutive sync-like bytes */
    uint8_t n47[DVBS_CW * 8];                 /* per bit phase: of those, how many were 0x47 */
    /* deinterleaver: received byte stream r(t), t = 0 at a sync byte */
    uint8_t ring[4096];
    uint32_t t;                               /* bytes received since sync */
    uint32_t u;                               /* deinterleaved bytes delivered */
    uint8_t cw[DVBS_CW];
    uint32_t group;                           /* packet index within the 8-packet group, 8 = unknown */
    /* statistics */
    uint32_t packets, rs_corrected, rs_failed, resyncs;
    uint32_t vit_q_x1000;                     /* running Viterbi quality, x 1000 */
} dvbs_rx_t;

void dvbs_rx_init(dvbs_rx_t *r, int fec_fixed, dvbs_rx_packet_fn fn, void *ctx);
void dvbs_rx_reset(dvbs_rx_t *r);             /* back to acquisition (carrier lost, retune) */
void dvbs_rx_push(dvbs_rx_t *r, const dvbs_soft_t *s, uint32_t n);
