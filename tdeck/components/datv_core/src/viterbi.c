#include "datv/viterbi.h"
#include <string.h>

static uint8_t outs[64][2];   /* coded pair (x | y << 1) for state s (last 6 bits, newest in bit 0) and input b */
static int ready;
#if VIT_SIMD
static int16_t mx[32] __attribute__((aligned(16))), my[32] __attribute__((aligned(16)));   /* -1 where the coded bit is 1 */
#endif

static void init_tables(void) {
    for (uint32_t s = 0; s < 64; ++s)
        for (uint32_t b = 0; b < 2; ++b) {
            const uint32_t x = b ^ (s & 1u) ^ ((s >> 1) & 1u) ^ ((s >> 2) & 1u) ^ ((s >> 5) & 1u);
            const uint32_t y = b ^ ((s >> 1) & 1u) ^ ((s >> 2) & 1u) ^ ((s >> 4) & 1u) ^ ((s >> 5) & 1u);
            outs[s][b] = (uint8_t)(x | (y << 1));
        }
#if VIT_SIMD
    for (uint32_t j = 0; j < 32; ++j) {
        mx[j] = (int16_t)((outs[j][0] & 1u) ? -1 : 0);
        my[j] = (int16_t)((outs[j][0] & 2u) ? -1 : 0);
    }
#endif
    ready = 1;
}

static uint32_t traceback(vit_t *v, uint32_t best, uint8_t *out_bits);

void vit_init(vit_t *v) {
    if (!ready) init_tables();
    memset(v, 0, sizeof(*v));
}

uint32_t vit_step_c(vit_t *v, int sx, int sy, uint8_t *out_bits) {
    /* branch metric for coded pair c: +s for bit 0, -s for bit 1 */
    const int32_t bm[4] = {sx + sy, -sx + sy, sx - sy, -sx - sy};
    const int32_t *pm = v->pm[v->cur];
    int32_t *np = v->pm[v->cur ^ 1u];
    uint32_t dlo = 0, dhi = 0;
    /* Butterflies: from states j and j + 32 (they differ only in the oldest bit) to 2j and 2j + 1.
       Both generators contain the oldest tap and the input, so with c = output(j, input 0):
       output(j + 32, 0) = output(j, 1) = c ^ 3 and output(j + 32, 1) = c, i.e. metric -m where j has +m. */
#define BFLY(j, word, shift)                                                         \
    do {                                                                             \
        const int32_t m = bm[outs[j][0]];                                            \
        const int32_t a = pm[j], b = pm[(j) + 32u];                                  \
        const int32_t m00 = a + m, m10 = b - m, m01 = a - m, m11 = b + m;            \
        np[2u * (j)] = m10 > m00 ? m10 : m00;                                        \
        np[2u * (j) + 1u] = m11 > m01 ? m11 : m01;                                   \
        word |= ((uint32_t)(m10 > m00) | (uint32_t)(m11 > m01) << 1) << (shift);     \
    } while (0)
    for (uint32_t j = 0; j < 16; ++j) BFLY(j, dlo, 2u * j);
    for (uint32_t j = 16; j < 32; ++j) BFLY(j, dhi, 2u * j - 32u);
#undef BFLY
    v->cur ^= 1u;
    uint32_t *sv = v->surv[v->n % VIT_RING];
    sv[0] = dlo;
    sv[1] = dhi;
    v->energy_part += (sx < 0 ? -sx : sx) + (sy < 0 ? -sy : sy);
    ++v->n;
    if ((v->n & 255u) == 0) {                 /* keep the metrics small */
        int32_t mx = np[0];
        for (int k = 1; k < 64; ++k) if (np[k] > mx) mx = np[k];
        for (int k = 0; k < 64; ++k) np[k] -= mx;
        v->score += mx;
        v->energy += v->energy_part;
        v->energy_part = 0;
    }
    if (v->n < VIT_TB + VIT_OUT || (v->n - VIT_TB) % VIT_OUT) return 0;
    uint32_t best = 0;
    for (uint32_t k = 1; k < 64; ++k) if (np[k] > np[best]) best = k;
    return traceback(v, best, out_bits);
}

/* traceback over the stored decisions (both versions) */
static uint32_t traceback(vit_t *v, uint32_t best, uint8_t *out_bits) {
    uint32_t s = best, t = v->n;
#define DEC(t, s) ((v->surv[(t) % VIT_RING][(s) >> 5] >> ((s) & 31u)) & 1u)
    for (uint32_t k = 0; k < VIT_TB; ++k) {
        --t;
        s = (s >> 1) | (DEC(t, s) << 5);
    }
    for (uint32_t k = VIT_OUT; k-- > 0;) {
        --t;
        out_bits[k] = (uint8_t)(s & 1u);
        s = (s >> 1) | (DEC(t, s) << 5);
    }
#undef DEC
    v->released += VIT_OUT;
    return VIT_OUT;
}

#if VIT_SIMD
static const int16_t weights[16] __attribute__((aligned(16))) = {1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, -32768};

static inline int16_t *pm16(vit_t *v, uint32_t which) {
    return (int16_t *)(((uintptr_t)v->pm16_raw + 15u) & ~(uintptr_t)15u) + 64u * which;
}

/* One group of 8 butterflies j = 8g .. 8g + 7: metrics of states 16g .. 16g + 15 and their 16 decision bits.
   M = (sx ^ MX) - MX + (sy ^ MY) - MY is the branch metric of each j (bit 0: +s, bit 1: -s). */
static inline uint32_t group(const int16_t **ap, const int16_t **bp, const int16_t **mxp, const int16_t **myp, int16_t **np,
                             const int16_t *sx, const int16_t *sy) {
    int32_t acc;
    const int16_t *wp = weights;
    const int32_t zero = 0;
    __asm__ volatile(
        "ee.vldbc.16 q6, %[sx]\n"
        "ee.vldbc.16 q7, %[sy]\n"
        "ee.vld.128.ip q0, %[mx], 16\n"
        "ee.vld.128.ip q1, %[my], 16\n"
        "ee.xorq q2, q6, q0\n"
        "ee.vsubs.s16 q2, q2, q0\n"
        "ee.xorq q3, q7, q1\n"
        "ee.vsubs.s16 q3, q3, q1\n"
        "ee.vadds.s16 q2, q2, q3\n"            /* M */
        "ee.vld.128.ip q0, %[a], 16\n"         /* A = pm[j] */
        "ee.vld.128.ip q1, %[b], 16\n"         /* B = pm[j + 32] */
        "ee.vadds.s16 q3, q0, q2\n"            /* A + M -> 2j */
        "ee.vsubs.s16 q4, q1, q2\n"            /* B - M -> 2j */
        "ee.vsubs.s16 q5, q0, q2\n"            /* A - M -> 2j + 1 */
        "ee.vadds.s16 q6, q1, q2\n"            /* B + M -> 2j + 1 */
        "ee.vmax.s16 q0, q3, q4\n"
        "ee.vmax.s16 q1, q5, q6\n"
        "ee.vcmp.gt.s16 q2, q4, q3\n"          /* decision: the predecessor j + 32 won */
        "ee.vcmp.gt.s16 q7, q6, q5\n"
        "ee.vzip.16 q0, q1\n"                  /* state order 2j, 2j + 1 */
        "ee.vzip.16 q2, q7\n"
        "ee.vst.128.ip q0, %[np], 16\n"
        "ee.vst.128.ip q1, %[np], 16\n"
        "ee.vld.128.ip q0, %[w], 16\n"
        "ee.vld.128.ip q1, %[w], 0\n"
        "ee.zero.accx\n"
        "ee.vmulas.s16.accx q2, q0\n"          /* -(decision bits) */
        "ee.vmulas.s16.accx q7, q1\n"
        "ee.srs.accx %[acc], %[zero], 0\n"
        : [acc] "=r"(acc), [a] "+r"(*ap), [b] "+r"(*bp), [mx] "+r"(*mxp), [my] "+r"(*myp), [np] "+r"(*np), [w] "+r"(wp)
        : [sx] "r"(sx), [sy] "r"(sy), [zero] "r"(zero)
        : "memory");
    return (uint32_t)(-acc) & 0xFFFFu;
}

uint32_t vit_step(vit_t *v, int sx, int sy, uint8_t *out_bits) {
    const int16_t s16x = (int16_t)sx, s16y = (int16_t)sy;
    const int16_t *a = pm16(v, v->cur), *b = a + 32, *pmx = mx, *pmy = my;
    int16_t *np = pm16(v, v->cur ^ 1u);
    const uint32_t g0 = group(&a, &b, &pmx, &pmy, &np, &s16x, &s16y);
    const uint32_t g1 = group(&a, &b, &pmx, &pmy, &np, &s16x, &s16y);
    const uint32_t g2 = group(&a, &b, &pmx, &pmy, &np, &s16x, &s16y);
    const uint32_t g3 = group(&a, &b, &pmx, &pmy, &np, &s16x, &s16y);
    v->cur ^= 1u;
    uint32_t *sv = v->surv[v->n % VIT_RING];
    sv[0] = g0 | g1 << 16;
    sv[1] = g2 | g3 << 16;
    v->energy_part += (sx < 0 ? -sx : sx) + (sy < 0 ? -sy : sy);
    ++v->n;
    int16_t *cur = pm16(v, v->cur);
    if ((v->n & 15u) == 0) {                  /* keep the 16-bit metrics small (they drift by at most 254 per step) */
        const int16_t ref = cur[0];
        for (int k = 0; k < 64; ++k) cur[k] = (int16_t)(cur[k] - ref);
        v->score += ref;
        v->energy += v->energy_part;
        v->energy_part = 0;
    }
    if (v->n < VIT_TB + VIT_OUT || (v->n - VIT_TB) % VIT_OUT) return 0;
    uint32_t best = 0;
    for (uint32_t k = 1; k < 64; ++k) if (cur[k] > cur[best]) best = k;
    return traceback(v, best, out_bits);
}
#else
uint32_t vit_step(vit_t *v, int sx, int sy, uint8_t *out_bits) { return vit_step_c(v, sx, sy, out_bits); }
#endif

double vit_quality(const vit_t *v) {
    const int64_t e = v->energy + v->energy_part;
    if (!e) return 0;
    int32_t best;
#if VIT_SIMD
    const int16_t *p16 = (const int16_t *)(((uintptr_t)v->pm16_raw + 15u) & ~(uintptr_t)15u) + 64u * v->cur;
    best = p16[0];
    for (int k = 1; k < 64; ++k) if (p16[k] > best) best = p16[k];
#else
    const int32_t *pm = v->pm[v->cur];
    best = pm[0];
    for (int k = 1; k < 64; ++k) if (pm[k] > best) best = pm[k];
#endif
    return (double)(v->score + best) / (double)e;
}
