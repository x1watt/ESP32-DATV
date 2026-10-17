/* QPSK transmitter on the ESP32-S3 RF block (see tx_core1.h).
 *
 * The playback engine plays one 64 KiB bank per trigger at 40 MS/s and has no loop mode; the CPU
 * must not touch a bank while it plays. So banks 0 and 1 alternate: core 1 fills one while the other
 * plays, moves the owner register to it when the engine reports done, and triggers again. The
 * re-trigger leaves a hole of about 140 samples (3.5 us); the cycle counter (same crystal as the DAC
 * clock, 6 CPU cycles per DAC sample) measures it and the waveform skips that time, so carrier phase
 * and symbol timing run on as if the output were continuous.
 *
 * Waveform: root-raised-cosine (roll-off 0.35, span 8 symbols) QPSK computed at 5 MS/s from the
 * packed lookup tables of the C3 transmitter (firmware/main/qpsk_lut.h, lut_build_t) with 128
 * timing phases per symbol and a 32-bit symbol phase accumulator, so any symbol rate is exact.
 * Each baseband word is stored 8 times (zero-order hold to 40 MS/s) with two 128-bit stores.
 * The words have I in bits 9..0 and Q in bits 19..10, the DAC format of the S3.
 *
 * Bank 2 is free while transmitting and holds the tables, the symbol ring and the baseband line. */
#include "tx_core1.h"
#include <math.h>
#include <string.h>
#include "esp_attr.h"
#include "esp_cpu.h"
#include "esp_heap_caps.h"
#include "esp_rom_sys.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "rf_s3.h"
#include "rx_core1.h"

static float rrc_pulse(float t, float b) {
    const float pi = 3.14159265f;
    if (fabsf(t) < 1e-6f) return 1.0f - b + 4.0f * b / pi;
    if (fabsf(fabsf(t) - 1.0f / (4.0f * b)) < 1e-4f)
        return b / 1.41421356f * ((1.0f + 2.0f / pi) * sinf(pi / (4.0f * b)) + (1.0f - 2.0f / pi) * cosf(pi / (4.0f * b)));
    const float num = sinf(pi * t * (1.0f - b)) + 4.0f * b * t * cosf(pi * t * (1.0f + b));
    const float den = pi * t * (1.0f - (4.0f * b * t) * (4.0f * b * t));
    return num / den;
}
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
#include "qpsk_lut.h"
#pragma GCC diagnostic pop

extern void phy_txtone_start(unsigned mhz, int khz, unsigned power);
extern void phy_txtone_stop(void);

#define TONE_GEN_REG 0x60006040u
#define TONE_GEN_EN (1u << 18)
#define PHASES 128u                        /* timing phases per symbol in the tables */
#define WORDS 16000u                       /* DAC words per buffer (400 us) */
#define BASE (WORDS / 8u)                  /* baseband samples per buffer at 5 MS/s */
#define FS_DAC 40000000.0
#define FS_BASE 5000000.0

/* bank 2 layout */
#define T_TABLES ((int32_t *)RF_BANK(2))                               /* 4 * 128 * 16 words = 32 KiB */
#define T_RING ((uint8_t *)RF_BANK(2) + 32768)                         /* TX_RING bytes */
#define T_LINE ((uint32_t *)((uint8_t *)RF_BANK(2) + 32768 + TX_RING)) /* BASE words */
_Static_assert(32768 + TX_RING + BASE * 4 <= 65536, "bank 2 layout");

static tx_status_t stat;
static uint32_t step;                      /* symbol phase per baseband sample, 2^32 = one symbol */
static volatile uint32_t ring_w, ring_r;   /* symbol ring, bytes (4 symbols each), free running */

/* 8 copies of each of n words from src into dst (16-byte aligned): one broadcast load, two 128-bit stores. */
static void IRAM_ATTR zoh8(uint32_t *dst, const uint32_t *src, uint32_t n) {
    for (uint32_t k = 0; k < n; ++k)
        __asm__ volatile("ee.vldbc.32 q0, %1\n\t"
                         "ee.vst.128.ip q0, %0, 16\n\t"
                         "ee.vst.128.ip q0, %0, 16\n\t"
                         : "+r"(dst) : "r"(src + k) : "memory");
}

typedef struct {
    uint32_t hist;          /* last 8 symbols, 2 bits each, newest in bits 1:0 */
    uint32_t ph;            /* phase inside the current symbol */
    uint32_t bits, nbits;   /* symbols taken from the ring, not yet used */
    uint32_t rng;
} mod_t;

static inline uint32_t IRAM_ATTR next_symbol(mod_t *m) {
    if (!m->nbits) {
        if (ring_w != ring_r) {
            m->bits = T_RING[ring_r & (TX_RING - 1u)];
            ++ring_r;
        } else {                           /* nothing from the encoder: keep the carrier modulated */
            m->rng ^= m->rng << 13; m->rng ^= m->rng >> 17; m->rng ^= m->rng << 5;
            m->bits = m->rng & 255u;
            stat.underruns++;
        }
        m->nbits = 4;
    }
    const uint32_t s = m->bits & 3u;
    m->bits >>= 2;
    --m->nbits;
    return s;
}

/* advances the symbol clock by n baseband samples without output (the re-trigger hole) */
static void IRAM_ATTR skip(mod_t *m, uint32_t n) {
    for (uint32_t k = 0; k < n; ++k) {
        const uint32_t p = m->ph + step;
        if (p < m->ph) m->hist = ((m->hist << 2) | next_symbol(m)) & 0xFFFFu;
        m->ph = p;
    }
}

static void IRAM_ATTR line(mod_t *m, uint32_t *out) {
    const int32_t *T = T_TABLES;
    uint32_t h = m->hist, ph = m->ph;
    for (uint32_t k = 0; k < BASE; ++k) {
        const uint32_t j = ph >> 25;                          /* 128 phases */
        const int32_t *r = T + j * 16u;
        const uint32_t w = (uint32_t)(r[h & 15u] + r[PHASES * 16u + ((h >> 4) & 15u)] + r[2u * PHASES * 16u + ((h >> 8) & 15u)] +
                                      r[3u * PHASES * 16u + ((h >> 12) & 15u)]);
        out[k] = w ^ LUT_XOR;
        const uint32_t p = ph + step;
        if (p < ph) h = ((h << 2) | next_symbol(m)) & 0xFFFFu;
        ph = p;
    }
    m->hist = h;
    m->ph = ph;
}

static void IRAM_ATTR tx_loop(void) {
    static mod_t m;
    memset(&m, 0, sizeof(m));
    m.rng = 0x2545F491u;
    const uint32_t owner0 = rf_rd(RF_BANK_OWNER), tg0 = rf_rd(TONE_GEN_REG), dac0 = rf_rd(RF_DAC_CTRL);
    rf_wr(TONE_GEN_REG, tg0 & ~TONE_GEN_EN);
    rf_wr(RF_DAC_CTRL, 0);
    const uint32_t ctrl = WORDS - 1u;                         /* 40 MS/s */
    line(&m, T_LINE);
    zoh8((uint32_t *)RF_BANK(0), T_LINE, BASE);
    uint32_t cur = 0, t_prev = 0, hole = 140;                 /* DAC samples between buffers, measured below */
    bool first = true;
    while (core1_want()) {
        __asm__ volatile("memw" ::: "memory");
        rf_wr(RF_BANK_OWNER, (owner0 & ~15u) | (1u << cur));
        rf_wr(RF_DAC_CTRL, ctrl);
        rf_wr(RF_DAC_CTRL, ctrl | (1u << 31));
        const uint32_t t = esp_cpu_get_cycle_count();
        if (!first) {
            const uint32_t dt = t - t_prev, samples = (dt + 3u) / 6u;
            if (samples > WORDS && samples < WORDS + 2000u) hole = samples - WORDS;
            else stat.late++;
            if (hole > stat.hole_max) stat.hole_max = hole;
        }
        first = false;
        t_prev = t;
        /* the next buffer starts after this one and the hole that follows it */
        skip(&m, (hole + 4u) / 8u);
        line(&m, T_LINE);
        zoh8((uint32_t *)RF_BANK(cur ^ 1u), T_LINE, BASE);
        stat.fill_cycles = esp_cpu_get_cycle_count() - t;
        while (!(rf_rd(RF_DAC_CTRL) & (1u << 18)) && esp_cpu_get_cycle_count() - t < 2000000u) {}
        stat.buffers++;
        cur ^= 1u;
    }
    rf_wr(RF_DAC_CTRL, dac0 & ~(1u << 31));
    rf_wr(TONE_GEN_REG, tg0);
    rf_wr(RF_BANK_OWNER, owner0);
}

bool tx_start(const tx_params_t *p) {
    if (p->fkhz < 2300000 || p->fkhz > 2450000) return false;           /* licensed amateurs: 13 cm band only */
    const double half_bw = p->baud * 1.35 / 2.0;
    if (p->fkhz * 1000.0 - half_bw < 2300e6 || p->fkhz * 1000.0 + half_bw > 2450e6) return false;
    if (p->baud < 10000 || p->baud > 1250000 || p->amp < 10 || p->amp > 250) return false;
    memset(&stat, 0, sizeof(stat));
    ring_w = ring_r = 0;
    /* tables: 128 phases of the RRC filter as "samples per symbol" */
    float *hb = heap_caps_malloc(8 * PHASES * sizeof(float), MALLOC_CAP_SPIRAM);
    if (!hb) return false;
    lut_build_t(T_TABLES, PHASES, 0, 0.35f, (float)p->amp, p->dci, p->dcq, p->gain, p->phase_deg, hb);
    heap_caps_free(hb);
    const double baud = p->baud * (1.0 + p->ppm * 1e-6);
    step = (uint32_t)llround(baud / FS_BASE * 4294967296.0);
    if (!rf_tune(p->fkhz)) return false;
    phy_txtone_start(p->fkhz / 1000, (int)(p->fkhz % 1000), 40);
    esp_rom_delay_us(3000);
    if (!core1_launch(tx_loop)) {
        phy_txtone_stop();
        return false;
    }
    return true;
}

void tx_stop(void) {
    core1_stop();
    phy_txtone_stop();
    rf_tune(2412000);
}

uint32_t tx_room(void) { return TX_RING - 1u - (ring_w - ring_r); }

void tx_push(const uint8_t *sym_bytes, uint32_t n) {
    uint32_t w = ring_w;
    for (uint32_t k = 0; k < n; ++k) T_RING[(w + k) & (TX_RING - 1u)] = sym_bytes[k];
    __asm__ volatile("memw" ::: "memory");
    ring_w = w + n;
}

const tx_status_t *tx_status(void) {
    stat.ring_fill = ring_w - ring_r;
    return &stat;
}
