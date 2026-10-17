/* Soft-decision Viterbi decoder for the DVB-S inner code (K = 7, G1 = 171, G2 = 133 octal),
 * rate 1/2 input (punctured positions given as 0). Soft values: positive = bit 0, |v| <= 127. */
#pragma once
#include <stdbool.h>
#include <stdint.h>

#define VIT_TB 96u            /* traceback depth */
#define VIT_OUT 64u           /* bits released per traceback */
#define VIT_RING 256u         /* survivor ring (steps) */

#ifdef ESP_PLATFORM
#include "sdkconfig.h"
#endif

/* On the ESP32-S3 the add-compare-select runs on the 128-bit SIMD unit (16-bit metrics, 8 states per instruction). */
#if defined(__XTENSA__) && defined(CONFIG_IDF_TARGET_ESP32S3)
#define VIT_SIMD 1
#else
#define VIT_SIMD 0
#endif

typedef struct {
    int32_t pm[2][64];        /* path metrics, double-buffered (C version) */
    int16_t pm16_raw[2 * 64 + 8]; /* 16-bit metrics for the SIMD version, 16-byte aligned inside */
    uint32_t cur;             /* which pm is current */
    uint32_t surv[VIT_RING][2]; /* decisions, states 0..31 and 32..63 */
    uint32_t n;               /* steps so far */
    uint32_t released;        /* bits released so far */
    int64_t score;            /* best path metric, accumulated over normalisations */
    int64_t energy;           /* sum of |soft| (the best possible metric) */
    int32_t energy_part;
} vit_t;

void vit_init(vit_t *v);
/* One step (one input bit). Every VIT_OUT steps, once primed, VIT_OUT decided bits are appended
   to out (MSB first in out bytes is up to the caller: bits are returned as 0/1 values) and the
   count is returned; otherwise 0. */
uint32_t vit_step(vit_t *v, int sx, int sy, uint8_t *out_bits);
/* the portable version, also on the S3 (tests compare the two) */
uint32_t vit_step_c(vit_t *v, int sx, int sy, uint8_t *out_bits);
/* Normalised path metric in 0..1: about 1 for the right code alignment, much lower otherwise. */
double vit_quality(const vit_t *v);
