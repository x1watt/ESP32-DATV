/* Gapless 16 MS/s capture on core 1 (see rx_core1.h).
 *
 * The capture engine writes one 32-bit word per complex pair into the bank that the owner register
 * gives it, at the circular write index (mod 16384). The CPU must not touch a bank while the radio
 * owns it, so three banks rotate: one with the radio, the others being decimated or waiting.
 *
 * The radio moves to the next bank at fixed ring targets T_s = T_0 + s * UNIT (mod 16384), one per
 * unit s. The index is only polled, so the move happens a little after T_s at an unknown index.
 * When a bank is free it is given the next unit s and sentinel words (never a sample: real words
 * have bits 31..28 = 2) are planted at both ends of that unit: from T_s and from T_s+1. When the
 * bank is back with the CPU, the first non-sentinel word after T_s and the first sentinel after
 * T_s+1 delimit what the radio wrote. Consecutive units must join without a hole, otherwise a gap
 * is counted. Planting happens while a bank waits, so the switch itself is a few register accesses.
 *
 * Decimation, all integer: the LO sits fs/4 = 4 MHz away from the signal, so mixing it to 0 Hz is
 * a rotation by a quarter turn per sample (swaps and negations); a sum of 4 mixed pairs gives
 * 4 MS/s, then a 3rd order CIC decimates by cic_r. Its nulls at multiples of the output rate fold
 * very little into a DATV channel of up to +-45 kHz (66 kBd); the demodulator's matched filter
 * does the channel selection. */
#include "rx_core1.h"
#include <string.h>
#include "esp_attr.h"
#include "esp_cpu.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "rf_s3.h"

#define NBANK 3u
#define RING_MASK (RF_BANK_WORDS - 1u)
#define UNIT 12288u               /* pairs per bank: 768 us at 16 MS/s */
#define WIN 2048u                 /* planted at both ends of a unit: the largest allowed switch lateness */
#define CHUNK 512u                /* pairs decimated between two index polls */
#define SENTINEL 0xFFFFFFFFu
_Static_assert(UNIT + WIN <= RF_BANK_WORDS, "the end window of a unit must not reach its start window");
#define UNIT_TARGET(t0, s) (((t0) + (s) * UNIT) & RING_MASK)

static TaskHandle_t core1_task;
static volatile bool want_run, running;
static rx_config_t cfg;
static rx_stream_t *st;

typedef struct {
    int32_t acc_i, acc_q;                 /* boxcar sum of the current group of 4 */
    int32_t i1, i2, i3, q1, q2, q3;       /* CIC integrators */
    int32_t di1, di2, di3, dq1, dq2, dq3; /* CIC comb delays */
    uint32_t phase;                       /* input pair index mod 4 */
    uint32_t rc;                          /* 4 MS/s samples left until the next output */
} dec_t;

static inline int16_t sat16(int32_t v) { return v > 32767 ? 32767 : v < -32768 ? -32768 : (int16_t)v; }

/* Field a = bits 9..0, b = bits 19..10, both signed. */
#define FA(x) ((int32_t)((x) << 22) >> 22)
#define FB(x) ((int32_t)((x) << 12) >> 22)

static void IRAM_ATTR emit(dec_t *d, rx_stream_t *s) {
    const int32_t ci = d->i3 - d->di1; d->di1 = d->i3;
    const int32_t c2i = ci - d->di2; d->di2 = ci;
    const int32_t c3i = c2i - d->di3; d->di3 = c2i;
    const int32_t cq = d->q3 - d->dq1; d->dq1 = d->q3;
    const int32_t c2q = cq - d->dq2; d->dq2 = cq;
    const int32_t c3q = c2q - d->dq3; d->dq3 = c2q;
    const uint32_t w = s->w;
    if (w - s->r >= s->size) { s->overruns++; return; }
    s->buf[w & (s->size - 1u)] = (iq16_t){sat16(c3i >> cfg.shift), sat16(c3q >> cfg.shift)};
    s->w = w + 1u;
}

static inline void IRAM_ATTR cic_push(dec_t *d, int32_t si, int32_t sq) {
    d->i1 += si; d->i2 += d->i1; d->i3 += d->i2;
    d->q1 += sq; d->q2 += d->q1; d->q3 += d->q2;
    if (--d->rc == 0) { d->rc = cfg.cic_r; emit(d, st); }
}

/* One pair at an arbitrary phase (unit heads and tails). */
static void IRAM_ATTR dec_one(dec_t *d, uint32_t x) {
    int32_t a = FA(x), b = FB(x);
    if (cfg.swap) { const int32_t t = a; a = b; b = t; }
    /* (a + jb) * exp(-j * dir * pi/2 * phase) */
    switch ((d->phase * (cfg.dir > 0 ? 1u : 3u)) & 3u) {
        case 0: d->acc_i += a; d->acc_q += b; break;
        case 1: d->acc_i += b; d->acc_q -= a; break;
        case 2: d->acc_i -= a; d->acc_q -= b; break;
        default: d->acc_i -= b; d->acc_q += a; break;
    }
    if (++d->phase == 4u) {
        d->phase = 0;
        cic_push(d, d->acc_i, d->acc_q);
        d->acc_i = d->acc_q = 0;
    }
}

/* n pairs from p (n a multiple of 4, phase 0), the state in registers. SWAP / FWD select the variant. */
#define DEC_BLOCK(NAME, SWAP, FWD)                                                                          \
    static void IRAM_ATTR NAME(dec_t *d, const uint32_t *p, uint32_t n) {                          \
        int32_t i1 = d->i1, i2 = d->i2, i3 = d->i3, q1 = d->q1, q2 = d->q2, q3 = d->q3;                     \
        uint32_t rc = d->rc;                                                                                \
        const uint32_t *const end = p + n;                                                                  \
        while (p != end) {                                                                                  \
            const uint32_t x0 = p[0], x1 = p[1], x2 = p[2], x3 = p[3];                                      \
            p += 4;                                                                                         \
            int32_t a0 = FA(x0), b0 = FB(x0), a1 = FA(x1), b1 = FB(x1);                                     \
            int32_t a2 = FA(x2), b2 = FB(x2), a3 = FA(x3), b3 = FB(x3);                                     \
            if (SWAP) {                                                                                     \
                int32_t t;                                                                                  \
                t = a0; a0 = b0; b0 = t; t = a1; a1 = b1; b1 = t;                                           \
                t = a2; a2 = b2; b2 = t; t = a3; a3 = b3; b3 = t;                                           \
            }                                                                                               \
            const int32_t si = FWD ? a0 + b1 - a2 - b3 : a0 - b1 - a2 + b3;                                 \
            const int32_t sq = FWD ? b0 - a1 - b2 + a3 : b0 + a1 - b2 - a3;                                 \
            i1 += si; i2 += i1; i3 += i2;                                                                   \
            q1 += sq; q2 += q1; q3 += q2;                                                                   \
            if (__builtin_expect(--rc == 0, 0)) {                                                           \
                rc = cfg.cic_r;                                                                             \
                d->i3 = i3; d->q3 = q3;                                                                     \
                emit(d, st);                                                                                \
            }                                                                                               \
        }                                                                                                   \
        d->i1 = i1; d->i2 = i2; d->i3 = i3; d->q1 = q1; d->q2 = q2; d->q3 = q3; d->rc = rc;                 \
    }
DEC_BLOCK(dec_block_nf, 0, 1)
DEC_BLOCK(dec_block_nr, 0, 0)
DEC_BLOCK(dec_block_sf, 1, 1)
DEC_BLOCK(dec_block_sr, 1, 0)
typedef void (*dec_block_fn)(dec_t *, const uint32_t *, uint32_t);
static dec_block_fn dec_block;

/* Decimates ring positions [from, from + n) of bank b. */
static void IRAM_ATTR dec_range(dec_t *d, uint32_t b, uint32_t from, uint32_t n) {
    /* plain loads: the bank belongs to the CPU now, and volatile would put a memw before each */
    const uint32_t *bank = (const uint32_t *)RF_BANK(b);
    while (n) {
        const uint32_t pos = from & RING_MASK;
        uint32_t m = RF_BANK_WORDS - pos;                  /* up to the end of the ring */
        if (m > n) m = n;
        uint32_t k = 0;
        while (k < m && d->phase) dec_one(d, bank[pos + k++]);
        const uint32_t blk = (m - k) & ~3u;
        if (blk) dec_block(d, bank + pos + k, blk);
        k += blk;
        while (k < m) dec_one(d, bank[pos + k++]);
        from += m;
        n -= m;
    }
}

static inline uint32_t cap_index(void) { return rf_rd(RF_CAP_INDEX) & RING_MASK; }

static void IRAM_ATTR plant(uint32_t b, uint32_t from, uint32_t n) {
    uint32_t *bank = (uint32_t *)RF_BANK(b);
    from &= RING_MASK;
    while (n) {
        uint32_t m = RF_BANK_WORDS - from;
        if (m > n) m = n;
        uint32_t *p = bank + from, *const e = p + m;
        while (p != e) *p++ = SENTINEL;
        n -= m;
        from = 0;
    }
}

/* First k in [0, n) where (word at from + k == SENTINEL) == want; n if none. */
static uint32_t IRAM_ATTR scan(uint32_t b, uint32_t from, uint32_t n, bool want) {
    const uint32_t *bank = (const uint32_t *)RF_BANK(b);
    for (uint32_t k = 0; k < n; ++k)
        if ((bank[(from + k) & RING_MASK] == SENTINEL) == want) return k;
    return n;
}

/* Bank b takes unit u: sentinels at both ends. */
static void IRAM_ATTR assign(uint32_t *unit_of, uint32_t b, uint32_t t0, uint32_t u) {
    unit_of[b] = u;
    plant(b, UNIT_TARGET(t0, u), WIN);
    plant(b, UNIT_TARGET(t0, u + 1u), WIN);
}

static void IRAM_ATTR capture_loop(void) {
    rx_stream_t *s = st;
    static dec_t d;
    memset(&d, 0, sizeof(d));
    d.rc = cfg.cic_r;
    dec_block = cfg.swap ? (cfg.dir > 0 ? dec_block_sf : dec_block_sr) : (cfg.dir > 0 ? dec_block_nf : dec_block_nr);

    uint32_t unit_of[NBANK];            /* unit number given to each bank */
    uint32_t q[NBANK], qn = 0;          /* banks with the CPU, oldest first; q[0] is being decimated */
    uint32_t ready[NBANK], nready = 0;  /* planted banks for the next units, in unit order */
    uint32_t next_unit;                 /* next unit number to give out */
    uint32_t pos = 0, end = 0;          /* q[0]: next ring index to decimate, end of its unit */
    bool open = false;
    uint32_t prev_end = 0;
    bool have_prev = false;
    uint32_t unit_min = UINT32_MAX, unit_max = 0, lat_max = 0;

    const uint32_t owner0 = rf_rd(RF_BANK_OWNER), config0 = rf_rd(RF_CAP_CONFIG);
    const uint32_t ctrl = (1u << 17) | (1u << 16) | 0x4000u;     /* circular, 16 MS/s, 16384 pairs */
    rf_wr(RF_CAP_CTRL, 0);
    rf_wr(RF_CAP_CONFIG, RF_CAP_CONFIG_IQ);
    rf_wr(RF_BANK_OWNER, (owner0 & ~15u) | 1u);
    rf_wr(RF_CAP_CTRL, ctrl);
    const uint32_t t0 = cap_index();    /* unit 0 starts here, in bank 0 */
    plant(0, 0, RF_BANK_WORDS);
    unit_of[0] = 0;
    for (uint32_t b = 1; b < NBANK; ++b) {
        assign(unit_of, b, t0, b);
        ready[nready++] = b;
    }
    next_unit = NBANK;
    uint32_t cur = 0;
    rf_wr(RF_CAP_CTRL, ctrl | (1u << 31));
    const uint32_t c_start = esp_cpu_get_cycle_count();
    uint32_t busy = 0;

    while (want_run) {
        /* switch when the index has passed the start of the next unit */
        const uint32_t due = unit_of[cur] + 1u;
        const uint32_t late = (cap_index() - UNIT_TARGET(t0, due)) & RING_MASK;
        if (late < RF_BANK_WORDS - UNIT) {
            if (!nready) {                                   /* core 1 too slow: drop the oldest CPU bank */
                s->late++;
                const uint32_t b = q[0];
                for (uint32_t k = 1; k < qn; ++k) q[k - 1] = q[k];
                --qn;
                open = false;
                have_prev = false;
                assign(unit_of, b, t0, due);
                ready[nready++] = b;
                next_unit = due + 1u;
            }
            const uint32_t nb = ready[0];
            for (uint32_t k = 1; k < nready; ++k) ready[k - 1] = ready[k];
            --nready;
            __asm__ volatile("memw" ::: "memory");           /* planted words out before the radio owns nb */
            rf_wr(RF_BANK_OWNER, (owner0 & ~15u) | (1u << nb));
            __asm__ volatile("memw" ::: "memory");
            if (late > lat_max) lat_max = late;
            q[qn++] = cur;
            cur = nb;
            continue;
        }
        if (!qn) continue;
        const uint32_t c0 = esp_cpu_get_cycle_count();
        const uint32_t b = q[0];
        if (!open) {                                         /* find what the radio wrote into b */
            const uint32_t u = unit_of[b];
            const uint32_t ts = UNIT_TARGET(t0, u), te = UNIT_TARGET(t0, u + 1u);
            const uint32_t ks = u ? scan(b, ts, WIN, false) : 0u;
            const uint32_t ke = scan(b, te, WIN, true);
            if (ks < WIN && ke < WIN) {
                pos = (ts + ks) & RING_MASK;
                end = (te + ke) & RING_MASK;
                const uint32_t len = (end - pos) & RING_MASK;
                if (len < unit_min) unit_min = len;
                if (len > unit_max) unit_max = len;
                if (have_prev && prev_end != pos) {
                    s->gaps++;
                    s->last_gap_w = s->w;
                }
                open = true;
            } else {
                s->scan_fail++;
                if (ks >= WIN) s->start_fail++;
                else s->end_fail++;
                if (s->ndiag < 4) {
                    uint32_t *g = s->diag[s->ndiag++];
                    g[0] = b; g[1] = u; g[2] = ts; g[3] = te; g[4] = ks; g[5] = ke;
                }
                have_prev = false;
            }
        }
        if (open) {
            uint32_t n = (end - pos) & RING_MASK;
            if (n > CHUNK) n = CHUNK;
            dec_range(&d, b, pos, n);
            pos = (pos + n) & RING_MASK;
            s->in_pairs += n;
        }
        if (!open || pos == end) {                           /* b is done: plant it for the next free unit */
            if (open) {
                prev_end = end;
                have_prev = true;
                s->units++;
            }
            open = false;
            for (uint32_t k = 1; k < qn; ++k) q[k - 1] = q[k];
            --qn;
            assign(unit_of, b, t0, next_unit++);
            ready[nready++] = b;
        }
        busy += esp_cpu_get_cycle_count() - c0;
        s->busy = busy;
        s->total = esp_cpu_get_cycle_count() - c_start;
        s->unit_min = unit_min;
        s->unit_max = unit_max;
        s->sw_max = lat_max;
    }
    rf_wr(RF_CAP_CTRL, ctrl);
    rf_wr(RF_CAP_CTRL, 0);
    rf_wr(RF_CAP_CONFIG, config0);
    rf_wr(RF_BANK_OWNER, owner0);
}

static void (*volatile core1_fn)(void);

static void core1_main(void *arg) {
    (void)arg;
    for (;;) {
        ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
        if (!want_run || !core1_fn) continue;
        running = true;
        portDISABLE_INTERRUPTS();
        core1_fn();
        portENABLE_INTERRUPTS();
        running = false;
    }
}

bool core1_launch(void (*fn)(void)) {
    if (running) return false;
    core1_fn = fn;
    want_run = true;
    xTaskNotifyGive(core1_task);
    for (int k = 0; k < 100 && !running; ++k) vTaskDelay(1);
    return running;
}

bool IRAM_ATTR core1_want(void) { return want_run; }

void rx_core1_init(void) {
    xTaskCreatePinnedToCore(core1_main, "rx_core1", 4096, NULL, configMAX_PRIORITIES - 1, &core1_task, 1);
}

bool rx_start(const rx_config_t *c, rx_stream_t *s) {
    if (running || !s->buf || !s->size || (s->size & (s->size - 1u))) return false;
    if (c->cic_r < 2 || c->cic_r > 256) return false;
    cfg = *c;
    s->r = s->w = 0;
    s->units = s->gaps = s->overruns = s->late = s->scan_fail = s->last_gap_w = s->sw_max = 0;
    s->start_fail = s->end_fail = s->ndiag = 0;
    s->unit_min = s->unit_max = 0;
    s->busy = s->total = 0;
    s->in_pairs = 0;
    st = s;
    return core1_launch(capture_loop);
}

void rx_stop(void) { core1_stop(); }

void core1_stop(void) {
    want_run = false;
    while (running) vTaskDelay(1);
}

bool rx_running(void) { return running; }
