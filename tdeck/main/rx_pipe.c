#include "rx_pipe.h"
#include <math.h>
#include <string.h>
#include "esp_cpu.h"
#include "esp_heap_caps.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/idf_additions.h"
#include "radio.h"
#include "settings.h"

/* Two stages: acquisition at 4 MHz / 16 = 250 kS/s (+-125 kHz covers the crystal offset of two boards), then the
   radio is retuned onto the signal and tracking runs at 4 MHz / 24 = 167 kS/s: a third fewer samples to demodulate. */
#define CIC_WIDE 16u
#define CIC_NARROW 24u
#define BLOCK 512u

static demod_t *dm;
static dvbs_rx_t *dv;
static void *work;
static volatile bool run, running;
static rx_ts_fn ts_cb;
static int16_t snap[512];
static volatile bool snap_new;
static uint32_t unlocked_syms;
static uint32_t cyc_demod, cyc_dvbs, cyc_total0;
static uint32_t f_khz, cur_cic, baud_cfg;
static int32_t retune_khz;                        /* LO moved by this much onto the signal (narrow stage) */
static float *ptab;
const char *rx_pipe_err = "";
static size_t ptab_size;

static bool start_stage(uint32_t cic, int32_t off_khz) {
    radio_rx_stop();
    cur_cic = cic;
    retune_khz = off_khz;
    if (!radio_rx_start((uint32_t)((int32_t)f_khz + off_khz), cic, settings.rx_gain)) return false;
    demod_init(dm, 4e6f / (float)cic, (float)baud_cfg, cic == CIC_WIDE ? 115e3f : 25e3f, work);
    if (ptab_size >= demod_ptab_bytes(dm)) demod_set_ptab(dm, ptab);   /* the polyphase table is read for every symbol: internal RAM */
    dvbs_rx_reset(dv);
    return true;
}

static void on_packet(void *ctx, const uint8_t *p) {
    (void)ctx;
    if (ts_cb) ts_cb(p);
}

static void pipe_task(void *arg) {
    (void)arg;
    rx_stream_t *s = radio_stream();
    static int16_t iq[2 * BLOCK];
    static dvbs_soft_t soft[BLOCK];
    uint32_t blocks = 0, seen_over = s->overruns;
    running = true;
    while (run) {
        /* locked onto the carrier in the wide stage: move the LO onto the signal and continue narrow */
        if (cur_cic == CIC_WIDE && dm->state == DEMOD_TRACK) {
            const int32_t off = (int32_t)lroundf((dm->coarse_hz + dm->fine_hz) / 1000.0f);
            if (!start_stage(CIC_NARROW, off)) start_stage(CIC_WIDE, 0);
            seen_over = s->overruns;
            continue;
        }
        if (s->overruns != seen_over) {                     /* fell behind: samples were lost, start clean */
            seen_over = s->overruns;
            s->r = s->w;
            continue;
        }
        const uint32_t avail = s->w - s->r;
        if (avail < BLOCK) { vTaskDelay(1); continue; }
        for (uint32_t k = 0; k < BLOCK; ++k) {
            const iq16_t v = s->buf[(s->r + k) & (s->size - 1u)];
            iq[2 * k] = v.i;
            iq[2 * k + 1] = v.q;
        }
        s->r += BLOCK;
        if (!snap_new) { memcpy(snap, iq + 2 * (BLOCK - 256u), sizeof(snap)); snap_new = true; }
        const uint32_t c0 = esp_cpu_get_cycle_count();
        const uint32_t n = demod_push(dm, iq, BLOCK, soft);
        const uint32_t c1 = esp_cpu_get_cycle_count();
        if (n) dvbs_rx_push(dv, soft, n);
        cyc_demod += c1 - c0;
        cyc_dvbs += esp_cpu_get_cycle_count() - c1;
        if (++blocks % 8u == 0) vTaskDelay(1);              /* never starve the UI and the console */
        /* no DVB-S sync for a long time after the carrier loops settled: search the spectrum again */
        if (dm->state == DEMOD_TRACK && !dv->byte_sync) {
            unlocked_syms += n;
            if (unlocked_syms > 40u * (uint32_t)dm->baud / 10u) {
                unlocked_syms = 0;
                if (cur_cic == CIC_NARROW) { start_stage(CIC_WIDE, 0); seen_over = s->overruns; }   /* lost it: search wide again */
                else { demod_reset(dm); dvbs_rx_reset(dv); }
            }
        } else unlocked_syms = 0;
    }
    running = false;
    vTaskDeleteWithCaps(NULL);
}

bool rx_pipe_start(uint32_t fkhz, uint32_t baud, int fec_fixed, rx_ts_fn on_ts) {
    if (running) { rx_pipe_err = "running"; return false; }
    if (!dm) dm = heap_caps_malloc(sizeof(*dm), MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);   /* per-sample state: internal RAM */
    if (!dv) dv = heap_caps_malloc(sizeof(*dv), MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);   /* Viterbi state: internal RAM is much faster */
    if (!dv) dv = heap_caps_malloc(sizeof(*dv), MALLOC_CAP_SPIRAM);
    if (!work) work = heap_caps_malloc(demod_work_bytes(), MALLOC_CAP_SPIRAM);
    if (!dm || !dv || !work) { rx_pipe_err = "memory"; return false; }
    if (!radio_lock()) { rx_pipe_err = "radio busy"; return false; }
    demod_init(dm, 4e6f / CIC_WIDE, (float)baud, 115e3f, work);
    if (ptab_size < demod_ptab_bytes(dm)) {               /* the wide stage needs the larger table */
        heap_caps_free(ptab);
        ptab = heap_caps_malloc(demod_ptab_bytes(dm), MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
        ptab_size = ptab ? demod_ptab_bytes(dm) : 0;
    }
    if (ptab) demod_set_ptab(dm, ptab);
    dvbs_rx_init(dv, fec_fixed, on_packet, NULL);
    ts_cb = on_ts;
    unlocked_syms = 0;
    f_khz = fkhz;
    baud_cfg = baud;
    cur_cic = CIC_WIDE;
    retune_khz = 0;
    if (!radio_rx_start(fkhz, CIC_WIDE, settings.rx_gain)) { radio_unlock(); rx_pipe_err = "receiver start"; return false; }
    run = true;
    /* the stack in PSRAM: internal RAM goes to the Viterbi state and the polyphase table, which are used per symbol */
    if (xTaskCreatePinnedToCoreWithCaps(pipe_task, "rxpipe", 6144, NULL, 6, NULL, 0, MALLOC_CAP_SPIRAM) != pdPASS) {
        run = false;
        radio_rx_stop();
        radio_unlock();
        rx_pipe_err = "task";
        return false;
    }
    return true;
}

void rx_pipe_stop(void) {
    if (!run) return;
    run = false;
    while (running) vTaskDelay(1);
    radio_rx_stop();
    radio_unlock();
    /* give the internal RAM back: the H.264 encoder needs it when transmit follows */
    demod_t *m = dm;
    dvbs_rx_t *v = dv;
    float *p = ptab;
    dm = NULL;
    dv = NULL;
    ptab = NULL;
    ptab_size = 0;
    heap_caps_free(m);
    heap_caps_free(v);
    heap_caps_free(p);
}

bool rx_pipe_running(void) { return running; }
uint32_t rx_pipe_rate(void) { return 4000000u / (cur_cic ? cur_cic : CIC_WIDE); }

void rx_pipe_stats(rx_pipe_stat_t *st) {
    memset(st, 0, sizeof(*st));
    if (!dm || !dv) return;
    rx_stream_t *s = radio_stream();
    st->state = dm->state;
    st->locked = dv->byte_sync;
    st->offset_hz = retune_khz * 1000.0f + dm->coarse_hz + dm->fine_hz;
    st->mer_db = dm->mer_db;
    st->fec = dv->locked ? (int)dv->fec : -1;
    st->packets = dv->packets;
    st->rs_corrected = dv->rs_corrected;
    st->rs_failed = dv->rs_failed;
    st->resyncs = dv->resyncs;
    st->symbols = dm->symbols;
    st->overruns = s->overruns;
    st->gaps = s->gaps;
    const uint32_t now = esp_cpu_get_cycle_count(), el = now - cyc_total0;
    st->load_demod = el ? 100.0f * cyc_demod / el : 0;
    st->load_dvbs = el ? 100.0f * cyc_dvbs / el : 0;
    cyc_demod = cyc_dvbs = 0;
    cyc_total0 = now;
}

bool rx_pipe_snapshot(int16_t *iq512) {
    if (!snap_new) return false;
    memcpy(iq512, snap, sizeof(snap));
    snap_new = false;
    return true;
}
