/* QPSK demodulator for narrow DVB-S (tens of kBd) from a complex baseband stream (int16 I/Q).
 *
 * Acquisition: the averaged power spectrum gives the signal centre (crystals of two boards differ
 * by tens of kHz), then the 4th power of the matched-filter output gives the residual carrier
 * offset to a few Hz. Tracking: numerically controlled oscillator, RRC matched filter (roll-off
 * 0.35) evaluated only at the two interpolation instants of each symbol (polyphase, 32 timing phases),
 * Gardner timing recovery, decision-directed QPSK carrier loop,
 * AGC. Output: soft symbols (int8, +-40 nominal) for the DVB-S back end, which resolves the
 * QPSK phase ambiguity itself. */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "datv/dvbs_rx.h"

#define DEMOD_ACQ_FFT 1024u                 /* spectrum size */
#define DEMOD_ACQ_AVG 8u                    /* spectra averaged */
#define DEMOD_FINE_N 4096u                  /* 4th-power estimate length (samples) */
#define DEMOD_MF_MAX 64u                    /* matched filter taps */
#define DEMOD_PHASES 32u                    /* polyphase timing resolution, 1/32 sample */

typedef struct { float re, im; } cpx_t;

typedef enum { DEMOD_COARSE, DEMOD_FINE, DEMOD_TRACK } demod_state_t;

typedef struct {
    /* configuration */
    float fs, baud, sps;
    float search_hz;                        /* centre search range +- */
    /* state */
    demod_state_t state;
    uint32_t nacq;
    cpx_t *acq;                             /* DEMOD_FINE_N samples (caller supplies, may be slow memory) */
    float *spec;                            /* DEMOD_ACQ_FFT floats */
    cpx_t *fft;                             /* DEMOD_FINE_N work */
    double nco_ph, nco_step;                /* coarse mixer, radians */
    cpx_t rot, rot_step;                    /* the mixer as a complex rotator (renormalised now and then) */
    uint32_t rot_n;
    float coarse_hz, fine_hz;
    /* matched filter */
    float taps[DEMOD_MF_MAX];
    uint32_t ntaps;
    cpx_t mf_hist[2 * DEMOD_MF_MAX];
    uint32_t mf_pos;
    /* timing */
    float *ptab;                            /* (DEMOD_PHASES + 1) x ntaps polyphase taps (the work area, or demod_set_ptab) */
    cpx_t win[2 * DEMOD_MF_MAX];            /* mixed input, mirrored ring: win[wpos .. wpos + ntaps) is contiguous */
    uint32_t wpos;
    uint64_t n;                             /* MF outputs so far */
    float t_next;                           /* time of the next interpolant in input samples, 0..1 = inside the newest gap (single precision: no double FPU) */
    bool mid;                               /* the next interpolant is the half-symbol one */
    cpx_t prev_sym, mid_sym;
    float tim_int;                          /* timing loop integrator (samples per half symbol correction) */
    /* carrier */
    float ph, freq;                         /* radians, radians per symbol */
    cpx_t crot;                             /* e^(j ph), turned by small angles (no sin/cos per symbol) */
    uint32_t crot_n;
    float agc;                              /* mean |symbol| */
    float mer_acc, mer_n, mer_db;
    uint32_t symbols;
} demod_t;

/* work: 2 * DEMOD_FINE_N cpx_t + DEMOD_ACQ_FFT floats */
void demod_init(demod_t *d, float fs, float baud, float search_hz, void *work);
void demod_reset(demod_t *d);               /* back to acquisition */
/* n int16 pairs in; soft symbols out (at most n / 2); returns the number of symbols written. */
uint32_t demod_push(demod_t *d, const int16_t *iq, uint32_t n, dvbs_soft_t *out);
size_t demod_work_bytes(void);
/* moves the polyphase table to faster memory of demod_ptab_bytes(d) bytes (call after demod_init) */
size_t demod_ptab_bytes(const demod_t *d);
void demod_set_ptab(demod_t *d, float *mem);
/* profiling: when set, demod_push adds the clock ticks of its stages to demod_prof[] (mix, filter, interpolation, symbol) */
extern uint32_t (*demod_clock)(void);
extern uint32_t demod_prof[4];
