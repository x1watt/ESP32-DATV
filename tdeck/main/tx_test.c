/* Transmit feasibility tests (Gate T) for the ESP32-S3 DAC playback engine.
 *   TXTEST f_MHz mode secs [tone_hz [n [rate80 [amp]]]]
 *   mode 0  tone generator only (keying check)
 *   mode 1  bank 2 replayed back to back: n words of a tone, re-triggered as soon as done
 *   mode 2  as 1, and the CPU rewrites the bank with the same words while it plays
 *   mode 3  short buffers: n words re-triggered in a loop, the CPU writes the next sample of a
 *           tone of tone_hz (at the measured trigger rate) before each trigger ("held word")
 *   mode 4  banks 0, 1, 2 hold tones of tone_hz, 2 * tone_hz, 3 * tone_hz; owner value n (1, 2, 4)
 *           selects which one the engine plays, if it follows the owner register
 *   mode 5  ping-pong: banks 0 and 1 alternate (owner switched before each trigger), tone of
 *           tone_hz continuous across buffers (16000 words each, the CPU fills the idle bank)
 *   mode 6  as 5, but the tone is computed at 5 MS/s and each sample stored 8 times with
 *           128-bit SIMD stores (the fill path of the real modulator)
 * Transmitting is for licensed amateurs: only 2300..2450 MHz. */
#include "tx_test.h"
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "esp_cpu.h"
#include "esp_rom_sys.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_heap_caps.h"
#include "rf_s3.h"

extern void phy_txtone_start(unsigned mhz, int khz, unsigned power);
extern void phy_txtone_stop(void);

#define TONE_GEN_REG 0x60006040u
#define TONE_GEN_EN (1u << 18)

/* playback words: I in bits 9..0, Q in bits 19..10 (the opposite of the capture words) */
static inline uint32_t iq_word(int i, int q) { return ((uint32_t)(q & 0x3ff) << 10) | (uint32_t)(i & 0x3ff); }

/* 8 copies of each of nb words from src into dst (16-byte aligned): one broadcast load, two 128-bit stores. */
static void IRAM_ATTR zoh8(uint32_t *dst, const uint32_t *src, uint32_t nb) {
    for (uint32_t k = 0; k < nb; ++k) {
        __asm__ volatile("ee.vldbc.32 q0, %1\n\t"
                         "ee.vst.128.ip q0, %0, 16\n\t"
                         "ee.vst.128.ip q0, %0, 16\n\t"
                         : "+r"(dst) : "r"(src + k) : "memory");
    }
}

/* Modes 4, 5 and 6. */
static bool tx_test_banks(uint32_t fkhz, int mode, uint32_t secs, int32_t tone_hz, uint32_t n, bool rate80, int amp, tx_test_result_t *res) {
    const double fs = rate80 ? 80e6 : 40e6;
    const uint32_t words = 16000u;
    static uint32_t *base;                                 /* mode 6 baseband line */
    if (!base) base = heap_caps_malloc(2000 * 4, MALLOC_CAP_INTERNAL);
    if (!base) return false;
    if (mode == 4)
        for (uint32_t b = 0; b < 3; ++b)
            for (uint32_t k = 0; k < words; ++k) {
                const double ph = 2 * M_PI * tone_hz * (b + 1.0) * k / fs;
                RF_BANK(b)[k] = iq_word((int)lrint(amp * cos(ph)), (int)lrint(amp * sin(ph)));
            }
    if (!rf_tune(fkhz)) return false;
    phy_txtone_start(fkhz / 1000, (int)(fkhz % 1000), 40);
    esp_rom_delay_us(3000);
    const uint32_t ctrl = (words - 1u) | (rate80 ? 1u << 15 : 0u);
    portDISABLE_INTERRUPTS();
    const uint32_t owner0 = rf_rd(RF_BANK_OWNER), tg0 = rf_rd(TONE_GEN_REG), dac0 = rf_rd(RF_DAC_CTRL);
    rf_wr(TONE_GEN_REG, tg0 & ~TONE_GEN_EN);
    rf_wr(RF_DAC_CTRL, 0);
    const uint32_t t0 = esp_cpu_get_cycle_count(), cyc_total = secs * 240000000u;
    uint32_t trig = 0, timeouts = 0, fill = 0, maxwait = 0;
    static uint32_t *tab;
    if (!tab) tab = heap_caps_malloc(1024 * 4, MALLOC_CAP_SPIRAM);
    if (!tab) return false;
    for (int k = 0; k < 1024; ++k) tab[k] = iq_word((int)lrint(amp * cos(2 * M_PI * k / 1024)), (int)lrint(amp * sin(2 * M_PI * k / 1024)));
    const uint32_t dph = (uint32_t)llrint(tone_hz / fs * 4294967296.0);
    uint32_t ph = 0;                                    /* tone phase at the start of the next buffer */
    const uint32_t gap = n;                             /* mode 5: samples of pause per re-trigger (phase kept across it) */
    if (mode >= 5) {                                    /* first buffer into bank 0 */
        uint32_t *b0 = (uint32_t *)RF_BANK(0);
        for (uint32_t k = 0; k < words; ++k, ph += dph) b0[k] = tab[ph >> 22];
        ph += dph * gap;
    }
    uint32_t cur = 0, t_done = 0;
    while (esp_cpu_get_cycle_count() - t0 < cyc_total) {
        const uint32_t ta = esp_cpu_get_cycle_count();
        rf_wr(RF_BANK_OWNER, (owner0 & ~15u) | (mode == 4 ? n : 1u << cur));
        (void)rf_rd(RF_BANK_OWNER);
        const uint32_t tb = esp_cpu_get_cycle_count();
        rf_wr(RF_DAC_CTRL, ctrl);
        rf_wr(RF_DAC_CTRL, ctrl | (1u << 31));
        (void)rf_rd(RF_DAC_CTRL);
        const uint32_t tw = esp_cpu_get_cycle_count();
        if (tb - ta > res->owner_cycles) res->owner_cycles = tb - ta;
        if (tw - tb > res->trig_cycles) res->trig_cycles = tw - tb;
        if (trig && ta - t_done > res->done_to_owner) res->done_to_owner = ta - t_done;
        if (mode >= 5) {                                /* fill the other bank meanwhile */
            uint32_t *nb = (uint32_t *)RF_BANK(cur ^ 1u);
            if (mode == 5) {
                for (uint32_t k = 0; k < words; ++k, ph += dph) nb[k] = tab[ph >> 22];
            } else {

                for (uint32_t k = 0; k < words / 8u; ++k, ph += 8u * dph) base[k] = tab[(ph + 4u * dph) >> 22];
                zoh8(nb, base, words / 8u);
            }
            ph += dph * gap;
            fill = esp_cpu_get_cycle_count() - tw;
        }
        while (!(rf_rd(RF_DAC_CTRL) & (1u << 18)))
            if (esp_cpu_get_cycle_count() - tw > 24000000u) { ++timeouts; break; }
        t_done = esp_cpu_get_cycle_count();
        const uint32_t wt = t_done - tw;
        if (wt > maxwait) maxwait = wt;
        ++trig;
        cur ^= 1u;
    }
    const uint32_t el = esp_cpu_get_cycle_count() - t0;
    rf_wr(RF_DAC_CTRL, dac0 & ~(1u << 31));
    rf_wr(TONE_GEN_REG, tg0);
    rf_wr(RF_BANK_OWNER, owner0);
    portENABLE_INTERRUPTS();
    phy_txtone_stop();
    rf_tune(fkhz);
    res->triggers = trig;
    res->timeouts = timeouts;
    res->max_wait = maxwait;
    res->cycles_per_trigger = trig ? (double)el / trig : 0;
    res->trig_rate = trig ? trig * 240e6 / el : 0;
    res->duty = trig ? (double)trig * words / fs / (el / 240e6) : 0;
    res->fill_cycles = fill;
    return true;
}

bool tx_test(uint32_t fkhz, int mode, uint32_t secs, int32_t tone_hz, uint32_t n, bool rate80, int amp, tx_test_result_t *res) {
    memset(res, 0, sizeof(*res));
    if (fkhz < 2300000 || fkhz > 2450000 || secs < 1 || secs > 10 || n < 1 || n > 16384 || amp < 1 || amp > 400) return false;
    if (mode >= 4) return tx_test_banks(fkhz, mode, secs, tone_hz, n, rate80, amp, res);
    if (!rf_tune(fkhz)) return false;
    phy_txtone_start(fkhz / 1000, (int)(fkhz % 1000), 40);
    esp_rom_delay_us(3000);
    const uint32_t cyc_total = secs * 240000000u;
    volatile uint32_t *bank = RF_BANK(2);
    const double fs = rate80 ? 80e6 : 40e6;
    if (mode == 0) {
        vTaskDelay(pdMS_TO_TICKS(secs * 1000));
    } else {
        /* one tone period table for mode 3; whole buffer for modes 1, 2 */
        static uint32_t *tab;
        if (!tab) tab = heap_caps_malloc(256 * 4, MALLOC_CAP_SPIRAM);
        if (!tab) return false;
        for (int k = 0; k < 256; ++k) tab[k] = iq_word((int)lrint(amp * cos(2 * M_PI * k / 256)), (int)lrint(amp * sin(2 * M_PI * k / 256)));
        if (mode != 3)
            for (uint32_t k = 0; k < n; ++k) {
                const double ph = 2 * M_PI * tone_hz * k / fs;
                bank[k] = iq_word((int)lrint(amp * cos(ph)), (int)lrint(amp * sin(ph)));
            }
        else
            for (uint32_t k = 0; k < n; ++k) bank[k] = tab[0];
        const uint32_t ctrl = (n - 1u) | (rate80 ? 1u << 15 : 0u);
        portDISABLE_INTERRUPTS();
        const uint32_t owner0 = rf_rd(RF_BANK_OWNER), tg0 = rf_rd(TONE_GEN_REG), dac0 = rf_rd(RF_DAC_CTRL);
        rf_wr(RF_BANK_OWNER, (owner0 & ~15u) | 4u);
        rf_wr(TONE_GEN_REG, tg0 & ~TONE_GEN_EN);
        rf_wr(RF_DAC_CTRL, 0);
        const uint32_t t0 = esp_cpu_get_cycle_count();
        uint32_t trig = 0, timeouts = 0, phase = 0, step = 0, rw = 0, maxwait = 0;
        /* mode 3: tone step per trigger from the rate of the first 1000 triggers */
        for (;;) {
            const uint32_t now = esp_cpu_get_cycle_count();
            if (now - t0 > cyc_total) break;
            if (mode == 3) {
                if (trig == 1000u && !step) {
                    const double rate = 1000.0 * 240e6 / (double)(now - t0);
                    step = (uint32_t)lrint(tone_hz / rate * 65536.0 * 256.0) ;
                    res->trig_rate = rate;
                }
                phase += step;
                const uint32_t w = tab[(phase >> 16) & 255u];
                for (uint32_t k = 0; k < n; ++k) bank[k] = w;
            }
            rf_wr(RF_DAC_CTRL, ctrl);
            rf_wr(RF_DAC_CTRL, ctrl | (1u << 31));
            const uint32_t tw = esp_cpu_get_cycle_count();
            while (!(rf_rd(RF_DAC_CTRL) & (1u << 18))) {
                if (mode == 2) {                       /* rewrite one word with its own value */
                    bank[rw] = bank[rw];
                    rw = rw + 1u == n ? 0u : rw + 1u;
                }
                if (esp_cpu_get_cycle_count() - tw > 24000000u) { ++timeouts; break; }
            }
            const uint32_t wt = esp_cpu_get_cycle_count() - tw;
            if (wt > maxwait) maxwait = wt;
            ++trig;
        }
        const uint32_t el = esp_cpu_get_cycle_count() - t0;
        rf_wr(RF_DAC_CTRL, dac0 & ~(1u << 31));
        rf_wr(TONE_GEN_REG, tg0);
        rf_wr(RF_BANK_OWNER, owner0);
        portENABLE_INTERRUPTS();
        res->triggers = trig;
        res->timeouts = timeouts;
        res->cycles_per_trigger = trig ? (double)el / trig : 0;
        res->max_wait = maxwait;
        if (mode != 3) res->trig_rate = trig ? trig * 240e6 / el : 0;
        res->duty = trig ? (double)trig * n / fs / (el / 240e6) : 0;
    }
    phy_txtone_stop();
    rf_tune(fkhz);
    return true;
}
