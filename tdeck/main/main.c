/* T-Deck DATV: standalone DVB-S transceiver firmware for the LilyGO T-Deck (ESP32-S3).
 *
 * The T-Deck runs the on-screen UI (ui.c); every board also has a USB text console:
 *   INFO
 *   HEAP
 *   BOARD tdeck|none                    which board this is (saved; tdeck starts the display UI), then reboots
 *   LCD flags                           panel orientation: 1 swap xy, 2 mirror x, 4 mirror y, 8 invert colours (saved)
 *   SHOT                                the display frame: "OK SHOT 320 240", then 320 * 240 RGB565 little-endian pixels
 *   KEY up|down|left|right|click|enter|bs|<char>   injects an input event into the UI
 *   TX f_MHz baud fec(1/2..7/8) secs [amp [ppm]]   DVB-S QPSK of null packets for secs seconds
 *   RXDEC f_MHz baud secs [fec|auto]    demodulate and decode DVB-S, a status line every second
 *   AVTX secs                           transmit the test card with callsign and text (H.264) with the saved settings
 *   AVRX secs                           receive and decode pictures with the saved settings, a status line every second
 *   SET freq|baud|fec|call|text|amp|gain|ppm|audio(mic|tone|off)|auto value   change a setting (saved); auto 1 transmits from power-up
 *   RAWSTAT f_MHz [agc|gain]            one 1 ms circular capture into bank 0, word statistics
 *   RXGATE f_MHz secs cic_r [agc|gain [dir [swap [stream]]]]
 *       gapless capture, LO 4 MHz below (dir 1) or above (dir -1) f_MHz, decimated to 4 MHz / cic_r.
 *       stream 1: after the OK line, exactly secs * rate pairs (int16 LE, field a then b) follow,
 *       then the END line with the counters. stream 0: only the END line.
 */
#include <inttypes.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "esp_cpu.h"
#include "esp_heap_caps.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "hal/usb_serial_jtag_ll.h"
#include "rf_s3.h"
#include "rx_core1.h"
#include "tx_test.h"
#include "tx_core1.h"
#include "rx_pipe.h"
#include "av.h"
#include "audio_io.h"
#include "datv/viterbi.h"
#include "datv/dvbs_tx.h"
#include "radio.h"
#include "settings.h"
#include "ui.h"
#include "gfx.h"

/* ------------------------------------------------------------ USB text I/O */

static void usb_write(const void *data, size_t n) {
    const uint8_t *p = data;
    int64_t deadline = esp_timer_get_time() + 2000000;
    while (n) {
        if (usb_serial_jtag_ll_txfifo_writable()) {
            int w = usb_serial_jtag_ll_write_txfifo(p, n > 64 ? 64 : n);
            usb_serial_jtag_ll_txfifo_flush();
            p += w;
            n -= w;
            deadline = esp_timer_get_time() + 2000000;
        } else if (esp_timer_get_time() > deadline) {
            return;   /* nobody reads */
        }
    }
}

static void say(const char *fmt, ...) {
    char b[300];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(b, sizeof(b), fmt, ap);
    va_end(ap);
    if (n > 0) usb_write(b, n < (int)sizeof(b) ? (size_t)n : sizeof(b) - 1);
}

static void usb_drain_rx(void) {
    uint8_t c;
    while (usb_serial_jtag_ll_read_rxfifo(&c, 1)) {}
}

static bool parse_gain(const char *g, int *out) {
    if (!strcmp(g, "agc")) { *out = -1; return true; }
    char *e;
    long v = strtol(g, &e, 10);
    if (*e || v < 0 || v > 127) return false;
    *out = (int)v;
    return true;
}

/* ------------------------------------------------------------ RAWSTAT */

static void rawstat(const char *args) {
    char fs[32], gs[16] = "agc";
    uint32_t fk;
    int gain;
    if (sscanf(args, "%31s %15s", fs, gs) < 1 || !rf_parse_freq(fs, &fk) || !parse_gain(gs, &gain)) {
        say("ERR RAWSTAT f_MHz [agc|gain]\r\n");
        return;
    }
    if (!rf_tune(fk)) { say("ERR TUNE\r\n"); return; }
    rf_gain(gain);
    volatile uint32_t *bank = RF_BANK(0);
    for (uint32_t k = 0; k < RF_BANK_WORDS; ++k) bank[k] = 0xFFFFFFFFu;
    portDISABLE_INTERRUPTS();
    const uint32_t owner0 = rf_rd(RF_BANK_OWNER), config0 = rf_rd(RF_CAP_CONFIG);
    const uint32_t ctrl = (1u << 17) | (1u << 16) | 0x4000u;
    rf_wr(RF_CAP_CTRL, 0);
    rf_wr(RF_CAP_CONFIG, RF_CAP_CONFIG_IQ);
    rf_wr(RF_BANK_OWNER, (owner0 & ~15u) | 1u);
    rf_wr(RF_CAP_CTRL, ctrl);
    const uint32_t i0 = rf_rd(RF_CAP_INDEX);
    rf_wr(RF_CAP_CTRL, ctrl | (1u << 31));
    const uint32_t t0 = esp_cpu_get_cycle_count();
    while (esp_cpu_get_cycle_count() - t0 < 240000u * 2u) {}     /* 2 ms: two turns of the ring */
    const uint32_t i1 = rf_rd(RF_CAP_INDEX);
    rf_wr(RF_CAP_CTRL, ctrl);
    rf_wr(RF_CAP_CTRL, 0);
    rf_wr(RF_CAP_CONFIG, config0);
    rf_wr(RF_BANK_OWNER, owner0);
    portENABLE_INTERRUPTS();
    uint32_t sent = 0, top_or = 0, gain_or = 0;
    int32_t amin = 1 << 20, amax = -(1 << 20), bmin = 1 << 20, bmax = -(1 << 20);
    double pa = 0, pb = 0, ma = 0, mb = 0;
    for (uint32_t k = 0; k < RF_BANK_WORDS; ++k) {
        const uint32_t x = bank[k];
        if (x == 0xFFFFFFFFu) { ++sent; continue; }
        top_or |= x >> 28;
        gain_or |= (x >> 20) & 0xffu;
        const int32_t a = (int32_t)(x << 22) >> 22, b = (int32_t)(x << 12) >> 22;
        if (a < amin) amin = a;
        if (a > amax) amax = a;
        if (b < bmin) bmin = b;
        if (b > bmax) bmax = b;
        ma += a; mb += b; pa += (double)a * a; pb += (double)b * b;
    }
    const double n = RF_BANK_WORDS - sent;
    if (n > 0) { ma /= n; mb /= n; pa = pa / n - ma * ma; pb = pb / n - mb * mb; }
    say("RAWSTAT idx %" PRIu32 "->%" PRIu32 " sentinels %" PRIu32 " top_or %" PRIx32 " gain_or %" PRIx32 " a %ld..%ld mean %.2f rms %.2f b %ld..%ld mean %.2f rms %.2f lo %.0f\r\n",
        i0, i1, sent, top_or, gain_or, (long)amin, (long)amax, ma, sqrt(pa), (long)bmin, (long)bmax, mb, sqrt(pb), rf_lo_hz());
    say("RAWSTAT words");
    for (int k = 0; k < 8; ++k) say(" %08" PRIx32, bank[1000 + k]);
    say("\r\n");
}

/* ------------------------------------------------------------ RAWDUMP f_MHz [agc|gain]: one ring of 16384 raw words at 16 MS/s */

static void rawdump(const char *args) {
    char fs[32], gs[16] = "agc";
    uint32_t fk;
    int gain;
    if (sscanf(args, "%31s %15s", fs, gs) < 1 || !rf_parse_freq(fs, &fk) || !parse_gain(gs, &gain)) {
        say("ERR RAWDUMP f_MHz [agc|gain]\r\n");
        return;
    }
    if (!rf_tune(fk)) { say("ERR TUNE\r\n"); return; }
    rf_gain(gain);
    vTaskDelay(20);
    portDISABLE_INTERRUPTS();
    const uint32_t owner0 = rf_rd(RF_BANK_OWNER), config0 = rf_rd(RF_CAP_CONFIG);
    const uint32_t ctrl = (1u << 17) | (1u << 16) | 0x4000u;
    rf_wr(RF_CAP_CTRL, 0);
    rf_wr(RF_CAP_CONFIG, RF_CAP_CONFIG_IQ);
    rf_wr(RF_BANK_OWNER, (owner0 & ~15u) | 1u);
    rf_wr(RF_CAP_CTRL, ctrl);
    rf_wr(RF_CAP_CTRL, ctrl | (1u << 31));
    const uint32_t t0 = esp_cpu_get_cycle_count();
    while (esp_cpu_get_cycle_count() - t0 < 240000u * 3u / 2u) {}     /* 1.5 ms: more than one turn */
    const uint32_t w = rf_rd(RF_CAP_INDEX) & 0x3fffu;
    rf_wr(RF_CAP_CTRL, ctrl);
    rf_wr(RF_CAP_CTRL, 0);
    rf_wr(RF_CAP_CONFIG, config0);
    rf_wr(RF_BANK_OWNER, owner0);
    portENABLE_INTERRUPTS();
    say("OK RAWDUMP lo %.0f first %" PRIu32 " words 16384\r\n", rf_lo_hz(), w);
    usb_write((const void *)RF_BANK(0), 4 * RF_BANK_WORDS);
    say("\r\nRAWDUMP END\r\n");
}

/* ------------------------------------------------------------ BANKTEST: which bank each owner value feeds */

static void banktest(void) {
    if (!rf_tune(2370000)) return;
    for (uint32_t v = 1; v <= 4; v <<= 1) {
        for (uint32_t b = 0; b < 3; ++b)
            for (uint32_t k = 0; k < RF_BANK_WORDS; ++k) RF_BANK(b)[k] = 0xFFFFFFFFu;
        portDISABLE_INTERRUPTS();
        const uint32_t owner0 = rf_rd(RF_BANK_OWNER), config0 = rf_rd(RF_CAP_CONFIG);
        const uint32_t ctrl = (1u << 17) | (1u << 16) | 0x4000u;
        rf_wr(RF_CAP_CTRL, 0);
        rf_wr(RF_CAP_CONFIG, RF_CAP_CONFIG_IQ);
        rf_wr(RF_BANK_OWNER, (owner0 & ~15u) | v);
        rf_wr(RF_CAP_CTRL, ctrl);
        rf_wr(RF_CAP_CTRL, ctrl | (1u << 31));
        const uint32_t t0 = esp_cpu_get_cycle_count();
        while (esp_cpu_get_cycle_count() - t0 < 240000u / 4u) {}     /* 250 us: 4000 pairs */
        const uint32_t i1 = rf_rd(RF_CAP_INDEX);
        rf_wr(RF_CAP_CTRL, ctrl);
        rf_wr(RF_CAP_CTRL, 0);
        rf_wr(RF_CAP_CONFIG, config0);
        rf_wr(RF_BANK_OWNER, owner0);
        portENABLE_INTERRUPTS();
        say("BANKTEST owner %" PRIu32 " (reg was %" PRIx32 ") index %" PRIu32 ":", v, owner0, i1 & 0x3fffu);
        for (uint32_t b = 0; b < 3; ++b) {
            uint32_t n = 0, first = 0xFFFFFFFFu, last = 0;
            for (uint32_t k = 0; k < RF_BANK_WORDS; ++k)
                if (RF_BANK(b)[k] != 0xFFFFFFFFu) { ++n; if (first == 0xFFFFFFFFu) first = k; last = k; }
            say(" bank%" PRIu32 " %" PRIu32 " written [%" PRIu32 "..%" PRIu32 "]", b, n, first, last);
        }
        say("\r\n");
    }
}

/* ------------------------------------------------------------ RXGATE */

static rx_stream_t rxs;

static void rxgate(const char *args) {
    char fs[32], gs[16] = "agc";
    uint32_t fk;
    unsigned long secs = 0, cic = 0;
    long dir = 1, swap = 0, stream = 0;
    int gain;
    const int k = sscanf(args, "%31s %lu %lu %15s %ld %ld %ld", fs, &secs, &cic, gs, &dir, &swap, &stream);
    if (k < 3 || !rf_parse_freq(fs, &fk) || secs < 1 || secs > 3600 || (cic != 16 && cic != 32 && cic != 64 && cic != 128) ||
        !parse_gain(gs, &gain) || (dir != 1 && dir != -1)) {
        say("ERR RXGATE f_MHz secs cic_r(16|32|64|128) [agc|gain [dir 1|-1 [swap 0|1 [stream 0|1]]]]\r\n");
        return;
    }
    const uint32_t lo_khz = dir > 0 ? fk - 4000u : fk + 4000u;
    if (!rf_tune(lo_khz)) { say("ERR TUNE\r\n"); return; }
    rf_gain(gain);
    if (!rxs.buf) {
        rxs.size = 8192;
        rxs.buf = heap_caps_malloc(rxs.size * sizeof(iq16_t), MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
        if (!rxs.buf) { say("ERR out of memory\r\n"); return; }
    }
    /* CIC gain cic^3, boxcar 4, 10-bit input: scale to about 12 bits of the int16 range */
    int shift = 0;
    for (uint32_t g = cic * cic * cic * 4u; g > 8u; g >>= 1) ++shift;
    const rx_config_t cfg = {.cic_r = cic, .shift = shift, .dir = (int)dir, .swap = swap != 0};
    const uint32_t rate = 4000000u / cic;
    const uint32_t total = (uint32_t)secs * rate;
    usb_drain_rx();
    say("OK RXGATE lo %.0f rate %" PRIu32 " pairs %" PRIu32 " shift %d\r\n", rf_lo_hz(), rate, stream ? total : 0u, shift);
    if (!rx_start(&cfg, &rxs)) { say("ERR core 1 did not start\r\n"); return; }
    const int64_t t_end = esp_timer_get_time() + (int64_t)secs * 1000000;
    uint32_t sent = 0;
    static uint8_t *out;
    if (!out) out = heap_caps_malloc(4096, MALLOC_CAP_SPIRAM);
    if (!out) { say("ERR memory\r\n"); return; }
    while (stream ? sent < total : esp_timer_get_time() < t_end) {
        const uint32_t avail = rxs.w - rxs.r;
        if (!avail) { if (!stream) vTaskDelay(10); continue; }
        if (!stream) { rxs.r += avail; continue; }
        uint32_t n = avail > 1024 ? 1024 : avail;
        if (n > total - sent) n = total - sent;
        for (uint32_t j = 0; j < n; ++j) memcpy(out + 4 * j, &rxs.buf[(rxs.r + j) & (rxs.size - 1u)], 4);
        rxs.r += n;
        usb_write(out, 4 * n);
        sent += n;
    }
    rx_stop();
    say("\r\nRXGATE END in %" PRIu64 " out %" PRIu32 " units %" PRIu32 " gaps %" PRIu32 " late %" PRIu32 " scanfail %" PRIu32 " overruns %" PRIu32
        " unit %" PRIu32 "..%" PRIu32 " late_max %" PRIu32 " busy %.1f%%\r\n",
        rxs.in_pairs, rxs.w, rxs.units, rxs.gaps, rxs.late, rxs.scan_fail, rxs.overruns, rxs.unit_min, rxs.unit_max, rxs.sw_max,
        rxs.total ? 100.0 * rxs.busy / rxs.total : 0.0);
    say("RXGATE scan start_fail %" PRIu32 " end_fail %" PRIu32 "\r\n", rxs.start_fail, rxs.end_fail);
    for (uint32_t k = 0; k < rxs.ndiag; ++k)
        say("RXGATE diag bank %" PRIu32 " unit %" PRIu32 " ts %" PRIu32 " te %" PRIu32 " ks %" PRIu32 " ke %" PRIu32 "\r\n",
            rxs.diag[k][0], rxs.diag[k][1], rxs.diag[k][2], rxs.diag[k][3], rxs.diag[k][4], rxs.diag[k][5]);
}

/* ------------------------------------------------------------ TXTEST f_MHz mode secs [tone_hz [n [rate80 [amp]]]] */

static void txtest(const char *args) {
    char fs[32];
    uint32_t fk;
    long mode = 0, secs = 2, tone = 200000, n = 16000, r80 = 0, amp = 150;
    if (sscanf(args, "%31s %ld %ld %ld %ld %ld %ld", fs, &mode, &secs, &tone, &n, &r80, &amp) < 2 || !rf_parse_freq(fs, &fk) || mode < 0 || mode > 6) {
        say("ERR TXTEST f_MHz mode(0..6) secs [tone_hz [n [rate80 [amp]]]]\r\n");
        return;
    }
    say("OK TXTEST\r\n");
    tx_test_result_t r;
    if (!tx_test(fk, (int)mode, (uint32_t)secs, (int32_t)tone, (uint32_t)n, r80 != 0, (int)amp, &r)) { say("ERR TXTEST arguments (2300..2450 MHz, secs 1..10, n 1..16384)\r\n"); return; }
    say("TXTEST END triggers %" PRIu32 " timeouts %" PRIu32 " cycles/trigger %.1f rate %.1f Hz duty %.4f maxwait %" PRIu32 " fill %" PRIu32 " owner %" PRIu32 " trig %" PRIu32 " done2owner %" PRIu32 "\r\n",
        r.triggers, r.timeouts, r.cycles_per_trigger, r.trig_rate, r.duty, r.max_wait, r.fill_cycles, r.owner_cycles, r.trig_cycles, r.done_to_owner);
}

/* ------------------------------------------------------------ TX: DVB-S of null packets */

static void txrun(const char *args) {
    char fs[32], fec_s[8] = "1/2";
    uint32_t fk;
    unsigned long baud = 0, secs = 10;
    long amp = 150;
    double ppm = 0;
    if (sscanf(args, "%31s %lu %7s %lu %ld %lf", fs, &baud, fec_s, &secs, &amp, &ppm) < 2 || !rf_parse_freq(fs, &fk) || secs < 1 || secs > 3600) {
        say("ERR TX f_MHz baud fec secs [amp [ppm]]\r\n");
        return;
    }
    int fec = -1;
    for (int k = 0; k < DVBS_FEC_COUNT; ++k) if (!strcmp(fec_s, dvbs_fec_name[k])) fec = k;
    if (fec < 0) { say("ERR TX fec 1/2 2/3 3/4 5/6 7/8\r\n"); return; }
    static dvbs_enc_t *encp;
    if (!encp) encp = heap_caps_malloc(sizeof(*encp), MALLOC_CAP_SPIRAM);
    if (!encp) { say("ERR TX memory\r\n"); return; }
    dvbs_enc_t *enc = encp;
    dvbs_enc_init(enc, (dvbs_fec_t)fec, false, false);
    const tx_params_t p = {.fkhz = fk, .baud = (uint32_t)baud, .amp = (int)amp, .ppm = ppm, .gain = 1.0f};
    if (!tx_start(&p)) { say("ERR TX (2300..2450 MHz incl. bandwidth, baud 10000..1250000, amp 10..250)\r\n"); return; }
    say("OK TX %.3f MHz %lu Bd FEC %s ts %.0f bit/s\r\n", fk / 1000.0, baud, fec_s, dvbs_ts_rate(baud, (dvbs_fec_t)fec));
    uint8_t pkt[188], sym[dvbs_enc_max_out(1)];
    memset(pkt, 0xFF, sizeof(pkt));
    pkt[0] = 0x47; pkt[1] = 0x1F; pkt[2] = 0xFF; pkt[3] = 0x10;             /* null packets (PID 0x1FFF) */
    const int64_t t_end = esp_timer_get_time() + (int64_t)secs * 1000000;
    uint32_t pkts = 0;
    while (esp_timer_get_time() < t_end) {
        uint8_t c;
        if (usb_serial_jtag_ll_read_rxfifo(&c, 1)) break;                  /* any byte from the host stops */
        while (tx_room() >= dvbs_enc_max_out(1)) {
            const size_t n = dvbs_enc(enc, pkt, 1, sym);
            tx_push(sym, (uint32_t)n);
            ++pkts;
        }
        vTaskDelay(pdMS_TO_TICKS(10));
    }
    tx_stop();
    const tx_status_t *st = tx_status();
    say("TX END packets %" PRIu32 " buffers %" PRIu32 " underruns %" PRIu32 " late %" PRIu32 " hole %" PRIu32 " fill %" PRIu32 " cycles\r\n",
        pkts, st->buffers, st->underruns, st->late, st->hole_max, st->fill_cycles);
}

/* ------------------------------------------------------------ BENCH: demodulator and Viterbi cycles */

static uint32_t bench_clock(void) { return esp_cpu_get_cycle_count(); }

static void bench(void) {
    demod_t *d = heap_caps_malloc(sizeof(demod_t), MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    void *work = heap_caps_malloc(demod_work_bytes(), MALLOC_CAP_SPIRAM);
    int16_t *iq = heap_caps_malloc(4 * 4096, MALLOC_CAP_SPIRAM);
    dvbs_soft_t *soft = heap_caps_malloc(4096 * sizeof(dvbs_soft_t), MALLOC_CAP_SPIRAM);
    if (!d || !work || !iq || !soft) { say("ERR BENCH memory\r\n"); free(d); free(work); free(iq); free(soft); return; }
    uint32_t x = 1;
    for (int k = 0; k < 8192; ++k) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; iq[k] = (int16_t)((x & 4095) - 2048); }
    demod_init(d, 250000, 66000, 115e3f, work);
    d->state = DEMOD_TRACK;
    uint32_t c0 = esp_cpu_get_cycle_count(), n = 0;
    for (int r = 0; r < 16; ++r) n += demod_push(d, iq, 4096, soft);
    uint32_t c1 = esp_cpu_get_cycle_count();
    say("BENCH demod %.0f cycles/sample (%" PRIu32 " symbols)\r\n", (double)(c1 - c0) / (16 * 4096), n);
    memset(demod_prof, 0, sizeof(demod_prof));
    demod_clock = bench_clock;
    for (int r = 0; r < 4; ++r) demod_push(d, iq, 4096, soft);
    demod_clock = NULL;
    say("BENCH per sample: mix %.0f filter %.0f, per interpolant: cubic %.0f, per symbol work %.0f\r\n", demod_prof[0] / 16384.0, demod_prof[1] / 16384.0,
        demod_prof[2] / (4.0 * 2 * n / 16), demod_prof[3] / (4.0 * n / 16));
    vit_t *v = heap_caps_malloc(sizeof(vit_t), MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    vit_t *vc = heap_caps_malloc(sizeof(vit_t), MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    if (v && vc) {
        /* coded random bits through noise: the SIMD and the C decoder must release the same bits */
        int8_t *cs = heap_caps_malloc(2 * 20000, MALLOC_CAP_SPIRAM);
        if (!cs) { say("ERR memory\r\n"); free(v); free(vc); return; }
        uint32_t st = 0, rn = 12345;
        for (int k = 0; k < 20000; ++k) {
            rn ^= rn << 13; rn ^= rn >> 17; rn ^= rn << 5;
            const uint32_t b = rn & 1u;
            const uint32_t x = b ^ (st & 1u) ^ ((st >> 1) & 1u) ^ ((st >> 2) & 1u) ^ ((st >> 5) & 1u);
            const uint32_t y = b ^ ((st >> 1) & 1u) ^ ((st >> 2) & 1u) ^ ((st >> 4) & 1u) ^ ((st >> 5) & 1u);
            st = ((st << 1) | b) & 63u;
            const int nx = (int)((rn >> 8) % 61) - 30, ny = (int)((rn >> 16) % 61) - 30;      /* noise up to +-30 on +-40 */
            cs[2 * k] = (int8_t)((x ? -40 : 40) + nx);
            cs[2 * k + 1] = (int8_t)((y ? -40 : 40) + ny);
        }
        uint8_t b1[64], b2[64];
        vit_init(v);
        vit_init(vc);
        uint32_t diff = 0, outs = 0, cyc_s = 0, cyc_c = 0;
        for (int k = 0; k < 20000; ++k) {
            const uint32_t t0 = esp_cpu_get_cycle_count();
            const uint32_t n1 = vit_step(v, cs[2 * k], cs[2 * k + 1], b1);
            const uint32_t t1 = esp_cpu_get_cycle_count();
            const uint32_t n2 = vit_step_c(vc, cs[2 * k], cs[2 * k + 1], b2);
            const uint32_t t2 = esp_cpu_get_cycle_count();
            cyc_s += t1 - t0;
            cyc_c += t2 - t1;
            if (n1 != n2) ++diff;
            else for (uint32_t i = 0; i < n1; ++i) { diff += b1[i] != b2[i]; ++outs; }
        }
        say("BENCH viterbi simd %.0f cycles/step, c %.0f cycles/step, %" PRIu32 " bits compared, %" PRIu32 " differ, quality %.3f / %.3f\r\n",
            (double)cyc_s / 20000, (double)cyc_c / 20000, outs, diff, vit_quality(v), vit_quality(vc));
        heap_caps_free(cs);
    }
    free(v);
    free(vc);
    free(d); free(work); free(iq); free(soft);
}

/* ------------------------------------------------------------ ENCTEST: the H.264 encoder alone (core 1 idle) */

#include "esp_attr.h"
#include "esp_rom_sys.h"
#include "esp_h264_enc_single_sw.h"
#include "esp_h264_alloc.h"
static void *ps_ul(unsigned long n) { return heap_caps_malloc(n, MALLOC_CAP_SPIRAM); }

static void IRAM_ATTR core1_spin(void) { while (core1_want()) {} }

static void enctest(void) {
    esp_h264_enc_handle_t h = NULL;
    const esp_h264_enc_cfg_sw_t cfg = {.pic_type = ESP_H264_RAW_FMT_I420, .gop = 20, .fps = 10, .res = {.width = 160, .height = 96},
                                       .rc = {.bitrate = 47000, .qp_min = 24, .qp_max = 48}};
    uint32_t il = 0, ol = 0;
    uint8_t *in = esp_h264_aligned_calloc(16, 1, 160 * 96 * 3 / 2, &il, MALLOC_CAP_SPIRAM), *out = esp_h264_aligned_calloc(16, 1, 160 * 96 * 2, &ol, MALLOC_CAP_SPIRAM);
    i420_t pic = {0};
    if (!in || !out || !i420_alloc(&pic, 160, 96, ps_ul) || esp_h264_enc_sw_new(&cfg, &h) || esp_h264_enc_open(h)) { say("ERR ENCTEST setup\r\n"); return; }
    for (int f = 0; f < 20; ++f) {
        test_pattern(&pic, f, 10, "TEST");
        memcpy(in, pic.y, 160 * 96 * 3 / 2);
        esp_h264_enc_in_frame_t fi = {.raw_data = {.buffer = in, .len = il}, .pts = f * 100};
        esp_h264_enc_out_frame_t fo = {.raw_data = {.buffer = out, .len = ol}};
        const int64_t t0 = esp_timer_get_time();
        const int r = esp_h264_enc_process(h, &fi, &fo);
        say("ENCTEST frame %d ret %d type %d len %" PRIu32 " %lld us\r\n", f, r, fo.frame_type, fo.length, esp_timer_get_time() - t0);
    }
    esp_h264_enc_close(h); esp_h264_enc_del(h);
    esp_h264_free(in); esp_h264_free(out); heap_caps_free(pic.y);
    say("ENCTEST END\r\n");
}

/* ------------------------------------------------------------ AUDIOTEST: speaker tone heard by the microphone */

static double goertzel_db(const int16_t *x, int n, double f, double fs) {
    const double w = 2 * M_PI * f / fs, c = 2 * cos(w);
    double s1 = 0, s2 = 0;
    for (int k = 0; k < n; ++k) { const double s0 = x[k] + c * s1 - s2; s2 = s1; s1 = s0; }
    const double p = s1 * s1 + s2 * s2 - c * s1 * s2;
    return 10 * log10(p / ((double)n * n) + 1e-9);
}

static void audiotest_slot(int slot);

static void audiotest(void) { audiotest_slot(0); }

static void audiotest_slot(int slot) {
    const int fs = 16000, n = 4096;
    int16_t *rec = heap_caps_malloc(2 * n, MALLOC_CAP_SPIRAM), *tone = heap_caps_malloc(2 * 1152, MALLOC_CAP_INTERNAL);
    if (!rec || !tone) { say("ERR memory\r\n"); return; }
    if (!audio_in_start(fs)) { say("ERR AUDIOTEST microphone\r\n"); return; }
    audio_in_slot(slot);
    if (!audio_out_start(fs)) { say("ERR AUDIOTEST speaker\r\n"); audio_in_stop(); return; }
    for (int phase = 0; phase < 2; ++phase) {
        /* phase 0: silence, phase 1: 1 kHz tone */
        for (int k = 0; k < 1152; ++k) tone[k] = phase ? (int16_t)(8000 * sin(2 * M_PI * 1000 * k / fs)) : 0;
        for (int r = 0; r < 4; ++r) audio_out_write(tone, 1152);       /* prefill */
        int got = 0, rd = 0;
        while (got < n) {
            audio_out_write(tone, 1152);
            int16_t tmp[1152];
            const int m = audio_in_read(tmp, n - got < 1152 ? n - got : 1152);
            if (m <= 0) { if (++rd > 20) break; continue; }
            if (rd++ < 2) continue;                                   /* settle */
            memcpy(rec + got, tmp, 2 * m);
            got += m;
        }
        double rms = 0;
        for (int k = 0; k < got; ++k) rms += (double)rec[k] * rec[k];
        rms = sqrt(rms / (got ? got : 1));
        int ih, il;
        int16_t raw[8];
        audio_in_diag(&ih, &il, raw);
        (void)ih; (void)il; (void)raw;
        say("AUDIOTEST slot %d %s: %d samples, rms %.0f, 1 kHz %.1f dB, 1.5 kHz %.1f dB\r\n", slot, phase ? "tone" : "silence", got, rms,
            goertzel_db(rec, got, 1000, fs), goertzel_db(rec, got, 1500, fs));
    }
    audio_out_stop();
    audio_in_stop();
    heap_caps_free(rec);
    heap_caps_free(tone);
    say("AUDIOTEST END\r\n");
}

/* ------------------------------------------------------------ TASKS: CPU per task since the last call; MP2TEST: codec on this chip */

static void tasks_cmd(void) {
    static char buf[2048];
    vTaskGetRunTimeStats(buf);
    say("TASKS\r\n");
    for (char *p = buf; *p;) {
        char *e = strchr(p, '\n');
        if (e) *e = 0;
        say("%s\r\n", p);
        if (!e) break;
        p = e + 1;
    }
    say("TASKS END\r\n");
}

#include "datv/mp2enc.h"
#include "datv/mp2dec.h"
static void mp2test(void) {
    mp2enc_t *e = heap_caps_malloc(sizeof(mp2enc_t), MALLOC_CAP_SPIRAM);
    mp2dec_t *d = heap_caps_malloc(sizeof(mp2dec_t), MALLOC_CAP_SPIRAM);
    int16_t *pcm = heap_caps_malloc(2 * MP2DEC_MAX_SAMPLES, MALLOC_CAP_SPIRAM);
    uint8_t *fr = heap_caps_malloc(MP2_FRAME_BYTES_MAX, MALLOC_CAP_SPIRAM);
    if (!e || !d || !pcm || !fr || !mp2enc_init(e, 16000, 1, 16)) { say("ERR MP2TEST\r\n"); return; }
    mp2dec_init(d);
    for (int f = 0; f < 8; ++f) {
        for (int k = 0; k < 1152; ++k) pcm[k] = (int16_t)(6000.0f * sinf(2.0f * 3.14159265f * (float)((f * 1152 + k) % 16) / 16.0f));
        const int64_t t0 = esp_timer_get_time();
        const size_t len = mp2enc_encode(e, pcm, fr);
        const int64_t t1 = esp_timer_get_time();
        int ch = 0, rate = 0;
        const int n = mp2dec_decode(d, fr, len, pcm, &ch, &rate);
        const int64_t t2 = esp_timer_get_time();
        double en = 0;
        for (int k = 0; k < n * (ch ? ch : 1); ++k) en += (double)pcm[k] * pcm[k];
        say("MP2TEST frame %d: %u bytes (%lld us), decoded %d x %d ch @%d rms %.0f (%lld us)\r\n", f, (unsigned)len, t1 - t0, n, ch, rate,
            n ? sqrt(en / (n * (ch ? ch : 1))) : 0.0, t2 - t1);
    }
    say("MP2TEST END\r\n");
    heap_caps_free(e); heap_caps_free(d); heap_caps_free(pcm); heap_caps_free(fr);
}

/* ------------------------------------------------------------ PIEPROBE: semantics of the SIMD instructions the Viterbi uses */

static void pieprobe(void) {
    static int16_t a[8] __attribute__((aligned(16))) = {0, 1, 2, 3, 4, 5, 6, 7};
    static int16_t b[8] __attribute__((aligned(16))) = {10, 11, 12, 13, 14, 15, 16, 17};
    static int16_t d[8] __attribute__((aligned(16))) = {-1, 0, -1, -1, 0, 0, 0, -1};
    static int16_t w[8] __attribute__((aligned(16))) = {1, 2, 4, 8, 16, 32, 64, 128};
    static int16_t o0[8] __attribute__((aligned(16))), o1[8] __attribute__((aligned(16)));
    int32_t acc = 0;
    int16_t *pa = a, *pb = b, *p0 = o0, *p1 = o1, *pd = d, *pw = w;
    int32_t zero = 0;
    __asm__ volatile(
        "ee.vld.128.ip q0, %[pa], 0\n"
        "ee.vld.128.ip q1, %[pb], 0\n"
        "ee.vzip.16 q0, q1\n"
        "ee.vst.128.ip q0, %[p0], 0\n"
        "ee.vst.128.ip q1, %[p1], 0\n"
        "ee.vld.128.ip q2, %[pd], 0\n"
        "ee.vld.128.ip q3, %[pw], 0\n"
        "ee.zero.accx\n"
        "ee.vmulas.s16.accx q2, q3\n"
        "ee.srs.accx %[acc], %[zero], 0\n"
        : [acc] "=r"(acc), [pa] "+r"(pa), [pb] "+r"(pb), [p0] "+r"(p0), [p1] "+r"(p1), [pd] "+r"(pd), [pw] "+r"(pw)
        : [zero] "r"(zero) : "memory");
    say("PIEPROBE zip q0:");
    for (int k = 0; k < 8; ++k) say(" %d", o0[k]);
    say(" q1:");
    for (int k = 0; k < 8; ++k) say(" %d", o1[k]);
    say(" | mask acc %ld (expect -%d)\r\n", (long)acc, 1 + 4 + 8 + 128);
}

/* ------------------------------------------------------------ BEEP secs: 1 kHz on the speaker in the background (microphone tests) */

static volatile uint32_t beep_secs;

static void beep_task(void *arg) {
    (void)arg;
    static int16_t tone[1152];
    for (int k = 0; k < 1152; ++k) tone[k] = (int16_t)(6000.0f * sinf(2.0f * 3.14159265f * (float)(k % 16) / 16.0f));
    if (audio_out_start(16000)) {
        const int64_t end = esp_timer_get_time() + (int64_t)beep_secs * 1000000;
        while (esp_timer_get_time() < end) audio_out_write(tone, 1152);
        audio_out_stop();
    }
    vTaskDelete(NULL);
}

/* ------------------------------------------------------------ RXDEC */

static volatile uint32_t rxdec_null, rxdec_other;

static void rxdec_ts(const uint8_t *p) {
    if (((p[1] & 0x1F) << 8 | p[2]) == 0x1FFF) rxdec_null++;
    else rxdec_other++;
}

static void rxdec(const char *args) {
    char fs[32];
    uint32_t fk;
    unsigned long baud = 0, secs = 10;
    char fec_s[8] = "1/2";
    if (sscanf(args, "%31s %lu %lu %7s", fs, &baud, &secs, fec_s) < 2 || !rf_parse_freq(fs, &fk) || secs < 1 || secs > 3600) { say("ERR RXDEC f_MHz baud secs [fec|auto]\r\n"); return; }
    int fec = -1;
    for (int k = 0; k < DVBS_FEC_COUNT; ++k) if (!strcmp(fec_s, dvbs_fec_name[k])) fec = k;
    radio_unlock();                                   /* the pipeline takes the radio itself */
    rxdec_null = rxdec_other = 0;
    if (!rx_pipe_start(fk, (uint32_t)baud, fec, rxdec_ts)) { say("ERR RXDEC start\r\n"); radio_lock(); return; }
    say("OK RXDEC\r\n");
    for (unsigned long t = 0; t < secs; ++t) {
        vTaskDelay(pdMS_TO_TICKS(1000));
        rx_pipe_stat_t st;
        rx_pipe_stats(&st);
        say("RXDEC t %lu state %d offset %+.0f Hz MER %.1f dB fec %s sync %d packets %" PRIu32 " (null %" PRIu32 " other %" PRIu32 ") rs_fix %" PRIu32 " rs_fail %" PRIu32 " resync %" PRIu32 " overruns %" PRIu32 " gaps %" PRIu32 " cpu demod %.0f%% dvbs %.0f%%\r\n",
            t + 1, st.state, st.offset_hz, st.mer_db, st.fec >= 0 ? dvbs_fec_name[st.fec] : "-", st.locked, st.packets, rxdec_null, rxdec_other,
            st.rs_corrected, st.rs_failed, st.resyncs, st.overruns, st.gaps, st.load_demod, st.load_dvbs);
    }
    rx_pipe_stop();
    radio_lock();
    say("RXDEC END\r\n");
}

/* ------------------------------------------------------------ AVTX / AVRX / SET */

static void avtx(const char *args) {
    const unsigned long secs = strtoul(args, NULL, 10);
    radio_unlock();
    if (!av_tx_start()) { say("ERR AVTX start\r\n"); radio_lock(); return; }
    av_tx_stat_t s;
    av_tx_stats(&s);
    say("OK AVTX %.3f MHz %lu Bd FEC %s mux %lu bit/s video %lu bit/s %dx%d %d fps audio %d kbit/s %s\r\n", settings.freq_khz / 1000.0, (unsigned long)settings.baud,
        dvbs_fec_name[settings.fec], (unsigned long)s.mux_rate, (unsigned long)s.video_bps, s.width, s.height, s.fps, s.audio_kbps,
        s.audio_kbps ? (s.mic ? "microphone" : "tone") : "");
    for (unsigned long t = 0; t < (secs ? secs : 10); ++t) {
        uint8_t c;
        if (usb_serial_jtag_ll_read_rxfifo(&c, 1)) break;
        vTaskDelay(pdMS_TO_TICKS(1000));
        av_tx_stats(&s);
        say("AVTX t %lu heap %u audio %" PRIu32 " frames %" PRIu32 " video %" PRIu32 " bytes buffered %.2f s nulls %" PRIu32 " underruns %" PRIu32 " dropped %" PRIu32 "\r\n",
            t + 1, (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL), s.audio_frames, s.frames, s.bytes, s.buffered, s.null_packets, s.underruns, s.dropped);
    }
    av_tx_stop();
    radio_lock();
    say("AVTX END\r\n");
}

static void tasks_cmd(void);

static void avrx(const char *args) {
    const unsigned long secs = strtoul(args, NULL, 10);
    radio_unlock();
    if (!av_rx_start()) { say("ERR AVRX start (%s)\r\n", rx_pipe_err); radio_lock(); return; }
    say("OK AVRX\r\n");
    for (unsigned long t = 0; t < (secs ? secs : 10); ++t) {
        vTaskDelay(pdMS_TO_TICKS(1000));
        av_rx_stat_t s;
        av_rx_stats(&s);
        say("AVRX t %lu sync %d MER %.1f dB offset %+.0f Hz packets %" PRIu32 " rs_fail %" PRIu32 " cc_err %" PRIu32 " frames %" PRIu32 " %dx%d audio %" PRIu32 " @%d rms %.0f 1kHz %.0f%% dec_err %" PRIu32 " damaged %" PRIu32 " cpu demod+fec %.0f%% video %.0f%% audio %.0f%% service '%s' '%s'\r\n",
            t + 1, s.locked, s.mer_db, s.offset_hz, s.packets, s.rs_failed, s.cc_errors, s.frames, s.width, s.height, s.audio_frames, s.audio_rate, s.audio_rms, s.audio_tone_pct, s.decode_errors, s.pes_damaged, s.load, s.load_video, s.load_audio, s.service, s.provider);
    }
    av_rx_stop();
    radio_lock();
    say("AVRX END\r\n");
}

static void set_cmd(const char *args) {
    char key[16], val[80] = "";
    if (sscanf(args, "%15s %79[^\r\n]", key, val) < 1) { say("ERR SET key value\r\n"); return; }
    if (!strcmp(key, "freq")) { uint32_t k; if (rf_parse_freq(val, &k)) settings.freq_khz = k; }
    else if (!strcmp(key, "baud")) settings.baud = (uint32_t)strtoul(val, NULL, 10);
    else if (!strcmp(key, "fec")) { for (int k = 0; k < DVBS_FEC_COUNT; ++k) if (!strcmp(val, dvbs_fec_name[k])) settings.fec = (uint8_t)k; }
    else if (!strcmp(key, "call")) snprintf(settings.call, sizeof(settings.call), "%s", val);
    else if (!strcmp(key, "text")) snprintf(settings.text, sizeof(settings.text), "%s", val);
    else if (!strcmp(key, "amp")) settings.amp = (uint16_t)strtoul(val, NULL, 10);
    else if (!strcmp(key, "gain")) settings.rx_gain = (int16_t)strtol(val, NULL, 10);
    else if (!strcmp(key, "ppm")) settings.ppm_x10 = (int16_t)(strtod(val, NULL) * 10);
    else if (!strcmp(key, "audio")) settings.audio = (uint8_t)(!strcmp(val, "mic") ? 0 : !strcmp(val, "tone") ? 1 : !strcmp(val, "off") ? 2 : strtoul(val, NULL, 10) % 3);
    else if (!strcmp(key, "auto")) settings.autotx = (uint8_t)(strtoul(val, NULL, 10) != 0);
    else { say("ERR SET freq|baud|fec|call|text|amp|gain|ppm|audio|auto\r\n"); return; }
    settings_save();
    say("OK SET %.3f MHz %lu Bd FEC %s call %s text '%s' amp %u gain %d audio %s auto %d\r\n", settings.freq_khz / 1000.0, (unsigned long)settings.baud,
        dvbs_fec_name[settings.fec], settings.call, settings.text, (unsigned)settings.amp, settings.rx_gain,
        settings.audio == 0 ? "mic" : settings.audio == 1 ? "tone" : "off", settings.autotx);
}

/* ------------------------------------------------------------ commands */

static void handle(char *line) {
    if (!strcmp(line, "INFO")) { say("TDECKDATV 0 board %s\r\n", settings.board[0] ? settings.board : "none"); return; }
    if (!strncmp(line, "BOARD ", 6)) {
        snprintf(settings.board, sizeof(settings.board), "%s", strcmp(line + 6, "tdeck") ? "" : "tdeck");
        settings_save();
        say("OK BOARD %s, rebooting\r\n", settings.board[0] ? settings.board : "none");
        vTaskDelay(pdMS_TO_TICKS(100));
        esp_restart();
    }
    if (!strncmp(line, "LCD ", 4)) {
        settings.lcd = (uint32_t)strtoul(line + 4, NULL, 0) & 15u;
        settings_save();
        ui_lcd_flags(settings.lcd);
        say("OK LCD %lu\r\n", (unsigned long)settings.lcd);
        return;
    }
    if (!strcmp(line, "SHOT")) {
        if (!gfx_fb) { say("ERR no display\r\n"); return; }
        const UBaseType_t prio = uxTaskPriorityGet(NULL);
        vTaskPrioritySet(NULL, configMAX_PRIORITIES - 2);   /* the receiver tasks would starve the console */
        say("OK SHOT %d %d\r\n", LCD_W, LCD_H);
        usb_write(gfx_fb, LCD_W * LCD_H * 2);
        say("\r\nSHOT END\r\n");
        vTaskPrioritySet(NULL, prio);
        return;
    }
    if (!strncmp(line, "KEY ", 4)) {             /* injects an input event into the UI (tests) */
        const char *k = line + 4;
        ui_inject(!strcmp(k, "up") ? KEY_UP : !strcmp(k, "down") ? KEY_DOWN : !strcmp(k, "left") ? KEY_LEFT : !strcmp(k, "right") ? KEY_RIGHT
                  : !strcmp(k, "click") ? KEY_CLICK : !strcmp(k, "enter") ? KEY_ENTER : !strcmp(k, "bs") ? KEY_BACKSPACE : (unsigned char)k[0]);
        say("OK KEY\r\n");
        return;
    }
    if (!strcmp(line, "HEAP")) {
        say("HEAP internal %u largest %u psram %u\r\n", (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
            (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL), (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM));
        return;
    }
    if (!strncmp(line, "SET ", 4)) { set_cmd(line + 4); return; }
    if (!strncmp(line, "BEEP ", 5)) {
        beep_secs = (uint32_t)strtoul(line + 5, NULL, 10);
        xTaskCreatePinnedToCore(beep_task, "beep", 3072, NULL, 3, NULL, 0);
        say("OK BEEP\r\n");
        return;
    }
    if (!strcmp(line, "TASKS")) {
        /* the run-time statistics stop the scheduler, which hangs while core 1 runs a radio loop with interrupts masked */
        if (rx_running()) { say("ERR TASKS: not while the radio runs\r\n"); return; }
        tasks_cmd();
        return;
    }       /* settings do not need the radio */
    if (!strcmp(line, "STOP")) { av_tx_stop(); say("OK STOP\r\n"); return; }   /* ends an automatic transmission */
    if (!radio_lock()) { say("ERR radio busy (the UI receiver is on)\r\n"); return; }
    if (0) {}
    else if (!strncmp(line, "RAWSTAT ", 8)) rawstat(line + 8);
    else if (!strcmp(line, "BANKTEST")) banktest();
    else if (!strncmp(line, "RAWDUMP ", 8)) rawdump(line + 8);
    else if (!strncmp(line, "TXTEST ", 7)) txtest(line + 7);
    else if (!strncmp(line, "TX ", 3)) txrun(line + 3);
    else if (!strncmp(line, "RXDEC ", 6)) rxdec(line + 6);
    else if (!strcmp(line, "BENCH")) bench();
    else if (!strcmp(line, "ENCTEST")) enctest();
    else if (!strcmp(line, "AUDIOTEST")) audiotest();
    else if (!strcmp(line, "MP2TEST")) mp2test();
    else if (!strcmp(line, "PIEPROBE")) pieprobe();
    else if (!strcmp(line, "ENCTEST1")) { core1_launch(core1_spin); enctest(); core1_stop(); }
    else if (!strcmp(line, "ENCTEST2")) {
        const tx_params_t p = {.fkhz = 2370000, .baud = 66000, .amp = 150, .gain = 1.0f};
        if (tx_start(&p)) { esp_rom_printf("enctest2: tx on\n"); enctest(); tx_stop(); } else say("ERR tx\r\n");
    }
    else if (!strncmp(line, "AVTX", 4)) avtx(line + 4);
    else if (!strncmp(line, "AVRX", 4)) avrx(line + 4);
    else if (!strncmp(line, "RXGATE ", 7)) rxgate(line + 7);
    else say("ERR ? (commands: INFO, HEAP, BOARD, LCD, RAWSTAT, RAWDUMP, BANKTEST, RXGATE, TXTEST)\r\n");
    radio_unlock();
}

void app_main(void) {
    rf_s3_init();
    settings_load();
    radio_lock();
    radio_unlock();                              /* creates the mutex before the UI task exists */
    rx_core1_init();
    if (!strcmp(settings.board, "tdeck")) ui_start();
    else if (settings.autotx) av_tx_start();       /* a board without a display transmits on its own */
    char line[128];
    size_t used = 0;
    for (;;) {
        uint8_t c;
        if (!usb_serial_jtag_ll_read_rxfifo(&c, 1)) { vTaskDelay(1); continue; }
        if (c == '\r') continue;
        if (c != '\n') {
            if (used < sizeof(line) - 1) line[used++] = (char)c;
            continue;
        }
        line[used] = 0;
        used = 0;
        if (line[0]) handle(line);
    }
}
