/* T-Deck user interface: home menu, receiver (spectrum and waterfall), transmitter (picture
 * preview) and settings, driven by the trackball and the keyboard.
 *   trackball up/down  move      click / Enter  open, edit, confirm
 *   trackball left     back      left/right on a choice: change it
 *   keyboard           type into a text or number field, Backspace deletes */
#include "ui.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "board.h"
#include "datv/dvbs.h"
#include "datv/frame.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "gfx.h"
#include "av.h"
#include "radio.h"
#include "rx_pipe.h"
#include "settings.h"

/* palette */
#define C_BG RGB(14, 18, 26)
#define C_BAR RGB(30, 38, 54)
#define C_FG RGB(230, 232, 236)
#define C_DIM RGB(130, 138, 152)
#define C_ACC RGB(255, 150, 40)
#define C_SEL RGB(52, 66, 96)
#define C_OK RGB(80, 200, 120)
#define C_WARN RGB(240, 90, 80)

typedef enum { SCR_HOME, SCR_RX, SCR_TX, SCR_SET } screen_t;

static screen_t scr = SCR_HOME;
static int home_sel;
static bool redraw = true;

/* ------------------------------------------------------------ common pieces */

static void header(const char *title) {
    gfx_fill(0, 0, LCD_W, 20, C_BAR);
    gfx_text(6, 3, 2, C_ACC, "DATV");
    gfx_text(64, 3, 2, C_FG, title);
    char f[24];
    snprintf(f, sizeof(f), "%lu.%03lu", (unsigned long)(settings.freq_khz / 1000), (unsigned long)(settings.freq_khz % 1000));
    gfx_text(LCD_W - gfx_text_w(2, f) - 6, 3, 2, C_DIM, f);
}

static void footer(const char *hint) {
    gfx_fill(0, LCD_H - 14, LCD_W, 14, C_BAR);
    gfx_text(4, LCD_H - 11, 1, C_DIM, hint);
}

static const uint32_t bauds[] = {33000, 66000, 125000, 250000, 333000, 500000, 1000000};
#define NBAUD (sizeof(bauds) / sizeof(bauds[0]))
static const char *const audio_names[] = {"Microphone", "Tone", "Off"};

static void fmt_baud(char *b, size_t n, uint32_t baud) {
    if (baud >= 1000000) snprintf(b, n, "%lu MS/s", (unsigned long)(baud / 1000000));
    else snprintf(b, n, "%lu kS/s", (unsigned long)(baud / 1000));
}

/* ------------------------------------------------------------ home */

static const char *const home_items[] = {"Receive", "Transmit", "Settings"};

static void draw_home(void) {
    gfx_fill(0, 0, LCD_W, LCD_H, C_BG);
    header("T-Deck");
    for (int k = 0; k < 3; ++k) {
        const int y = 34 + k * 46;
        const bool sel = k == home_sel;
        gfx_fill(20, y, LCD_W - 40, 38, sel ? C_SEL : C_BAR);
        if (sel) gfx_fill(20, y, 5, 38, C_ACC);
        gfx_text(44, y + 7, 3, sel ? C_FG : C_DIM, home_items[k]);
    }
    char b[64], r[16];
    fmt_baud(r, sizeof(r), settings.baud);
    snprintf(b, sizeof(b), "DVB-S QPSK %s FEC %s  %s", r, dvbs_fec_name[settings.fec], settings.call);
    gfx_text(20, 176, 1, C_DIM, b);
    footer("ball: move   click: open   r t s: shortcuts");
}

static void key_home(int k) {
    if (k == KEY_UP && home_sel > 0) { --home_sel; redraw = true; }
    else if (k == KEY_DOWN && home_sel < 2) { ++home_sel; redraw = true; }
    else if (k == KEY_CLICK || k == KEY_ENTER || k == KEY_RIGHT) { scr = (screen_t)(SCR_RX + home_sel); redraw = true; }
    else if (k == 'r') { scr = SCR_RX; redraw = true; }
    else if (k == 't') { scr = SCR_TX; redraw = true; }
    else if (k == 's') { scr = SCR_SET; redraw = true; }
}

/* ------------------------------------------------------------ settings */

typedef enum { IT_FREQ, IT_BAUD, IT_FEC, IT_CALL, IT_TEXT, IT_AUDIO, IT_AMP, IT_GAIN, IT_PPM, IT_COUNT } item_t;
static const char *const item_names[IT_COUNT] = {"Frequency", "Symbol rate", "FEC", "Callsign", "Text", "Audio", "TX level", "RX gain", "Crystal ppm"};
static int set_sel;
static bool editing;
static char edit_buf[64];

static void item_value(item_t it, char *b, size_t n) {
    switch (it) {
        case IT_FREQ: snprintf(b, n, "%lu.%03lu MHz", (unsigned long)(settings.freq_khz / 1000), (unsigned long)(settings.freq_khz % 1000)); break;
        case IT_BAUD: fmt_baud(b, n, settings.baud); break;
        case IT_FEC: snprintf(b, n, "%s", dvbs_fec_name[settings.fec]); break;
        case IT_CALL: snprintf(b, n, "%s", settings.call); break;
        case IT_TEXT: snprintf(b, n, "%s", settings.text[0] ? settings.text : "(none)"); break;
        case IT_AUDIO: snprintf(b, n, "%s", audio_names[settings.audio % 3]); break;
        case IT_AMP: snprintf(b, n, "%u", (unsigned)settings.amp); break;
        case IT_GAIN: if (settings.rx_gain < 0) snprintf(b, n, "AGC"); else snprintf(b, n, "%d", settings.rx_gain); break;
        case IT_PPM: snprintf(b, n, "%.1f", settings.ppm_x10 / 10.0); break;
        default: b[0] = 0;
    }
}

static bool item_is_choice(item_t it) { return it == IT_BAUD || it == IT_FEC || it == IT_AUDIO || it == IT_GAIN; }

static void draw_settings(void) {
    gfx_fill(0, 0, LCD_W, LCD_H, C_BG);
    header("Settings");
    for (int k = 0; k < IT_COUNT; ++k) {
        const int y = 24 + k * 22;
        const bool sel = k == set_sel;
        if (sel) gfx_fill(0, y - 2, LCD_W, 20, C_SEL);
        gfx_text(6, y + 2, 2, sel ? C_FG : C_DIM, item_names[k]);
        char v[72];
        if (sel && editing) snprintf(v, sizeof(v), "%s_", edit_buf);
        else item_value((item_t)k, v, sizeof(v));
        const int maxc = 13;
        const size_t len = strlen(v);
        const char *shown = len > (size_t)maxc ? v + len - maxc : v;
        gfx_text(160, y + 2, 2, sel && editing ? C_ACC : C_FG, shown);
    }
    footer(editing ? "type   Bksp: delete   Enter: save   left: cancel"
                   : item_is_choice((item_t)set_sel) ? "left/right: change   up/down: move"
                                                     : "click: edit   left: back   up/down: move");
}

static void choice_step(item_t it, int d) {
    switch (it) {
        case IT_BAUD: {
            int i = 0;
            while (i < (int)NBAUD - 1 && bauds[i] != settings.baud) ++i;
            i = (i + d + NBAUD) % NBAUD;
            settings.baud = bauds[i];
            break;
        }
        case IT_FEC: settings.fec = (uint8_t)((settings.fec + d + DVBS_FEC_COUNT) % DVBS_FEC_COUNT); break;
        case IT_AUDIO: settings.audio = (uint8_t)((settings.audio + d + 3) % 3); break;
        case IT_GAIN: {
            int g = settings.rx_gain + 2 * d;          /* AGC, 0, 2, ... 70 */
            if (g < -1) g = 70;
            if (g > 70) g = -1;
            if (settings.rx_gain == -1 && d > 0) g = 0;
            if (settings.rx_gain == 0 && d < 0) g = -1;
            settings.rx_gain = (int16_t)g;
            break;
        }
        default: break;
    }
    settings_save();
}

static void edit_commit(item_t it) {
    switch (it) {
        case IT_FREQ: {
            const double mhz = atof(edit_buf);
            if (mhz >= 2200 && mhz <= 2800) settings.freq_khz = (uint32_t)llround(mhz * 1000);
            break;
        }
        case IT_CALL: snprintf(settings.call, sizeof(settings.call), "%s", edit_buf); break;
        case IT_TEXT: snprintf(settings.text, sizeof(settings.text), "%s", edit_buf); break;
        case IT_AMP: { const long a = atol(edit_buf); if (a >= 10 && a <= 250) settings.amp = (uint16_t)a; break; }
        case IT_PPM: { const double p = atof(edit_buf); if (fabs(p) <= 100) settings.ppm_x10 = (int16_t)lround(p * 10); break; }
        default: break;
    }
    settings_save();
}

static void key_settings(int k) {
    const item_t it = (item_t)set_sel;
    if (editing) {
        if (k == KEY_ENTER || k == KEY_CLICK) { edit_commit(it); editing = false; }
        else if (k == KEY_LEFT) editing = false;
        else if (k == KEY_BACKSPACE) { const size_t n = strlen(edit_buf); if (n) edit_buf[n - 1] = 0; }
        else if (k >= 0x20 && k < 0x7F) {
            const size_t n = strlen(edit_buf);
            const size_t cap = it == IT_CALL ? sizeof(settings.call) - 1 : it == IT_TEXT ? sizeof(settings.text) - 1 : 12;
            const bool numeric = it == IT_FREQ || it == IT_AMP || it == IT_PPM;
            if (n < cap && (!numeric || (k >= '0' && k <= '9') || k == '.' || k == '-'))
                { edit_buf[n] = (char)(it == IT_CALL && k >= 'a' && k <= 'z' ? k - 32 : k); edit_buf[n + 1] = 0; }
        } else return;
        redraw = true;
        return;
    }
    if (k == KEY_UP && set_sel > 0) --set_sel;
    else if (k == KEY_DOWN && set_sel < IT_COUNT - 1) ++set_sel;
    else if (item_is_choice(it) && (k == KEY_RIGHT || k == KEY_CLICK || k == KEY_ENTER)) choice_step(it, 1);
    else if (item_is_choice(it) && k == KEY_LEFT) choice_step(it, -1);
    else if (k == KEY_LEFT) scr = SCR_HOME;
    else if (k == KEY_CLICK || k == KEY_ENTER || k == KEY_RIGHT) {
        editing = true;
        edit_buf[0] = 0;
        if (it == IT_FREQ) snprintf(edit_buf, sizeof(edit_buf), "%lu.%03lu", (unsigned long)(settings.freq_khz / 1000), (unsigned long)(settings.freq_khz % 1000));
        else if (it == IT_CALL) snprintf(edit_buf, sizeof(edit_buf), "%s", settings.call);
        else if (it == IT_TEXT) snprintf(edit_buf, sizeof(edit_buf), "%s", settings.text);
        else if (it == IT_AMP) snprintf(edit_buf, sizeof(edit_buf), "%u", (unsigned)settings.amp);
        else if (it == IT_PPM) snprintf(edit_buf, sizeof(edit_buf), "%.1f", settings.ppm_x10 / 10.0);
    } else if (k == 'q') scr = SCR_HOME;
    else return;
    redraw = true;
}

/* audio level meter: rms of 16-bit samples, -60..0 dBFS */
static void meter(int x, int y, int w, int h, float rms, bool on) {
    gfx_fill(x, y, w, h, RGB(30, 38, 54));
    if (!on) { gfx_text(x + 2, y + 1, 1, C_DIM, "no audio"); return; }
    float db = 20.0f * log10f(rms / 32768.0f + 1e-6f);
    int len = (int)((db + 60.0f) / 60.0f * (float)w);
    if (len < 0) len = 0;
    if (len > w) len = w;
    gfx_fill(x, y, len, h, db > -6.0f ? C_WARN : C_OK);
}

/* ------------------------------------------------------------ receiver: picture, or the spectrum until there is one */

#define NFFT 256
#define PIC_Y 22
#define PIC_H 192
#define RX_STAT_Y (PIC_Y + PIC_H + 1)

static bool rx_on;
static const char *rx_err;
static float fre[NFFT], fim[NFFT], win[NFFT];
static i420_t rx_pic;
static int64_t rx_next_stat;
static uint32_t rx_frames_prev;
static int64_t rx_fps_t;
static float rx_fps;

static void fft(float *re, float *im, int n) {
    for (int i = 1, j = 0; i < n; ++i) {
        int bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) { float t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t; }
    }
    for (int len = 2; len <= n; len <<= 1) {
        const float a = -2.0f * (float)M_PI / (float)len;
        const float wr = cosf(a), wi = sinf(a);
        for (int i = 0; i < n; i += len) {
            float cr = 1, ci = 0;
            for (int k = 0; k < len / 2; ++k) {
                const int p = i + k, q = p + len / 2;
                const float tr = re[q] * cr - im[q] * ci, ti = re[q] * ci + im[q] * cr;
                re[q] = re[p] - tr; im[q] = im[p] - ti;
                re[p] += tr; im[p] += ti;
                const float nr = cr * wr - ci * wi;
                ci = cr * wi + ci * wr;
                cr = nr;
            }
        }
    }
}

static void draw_rx_static(void) {
    gfx_fill(0, 0, LCD_W, LCD_H, C_BG);
    header("Receive");
    gfx_fill(0, PIC_Y, LCD_W, PIC_H, RGB(8, 10, 16));
    footer("ball left: back");
}

static void rx_enter(void) {
    for (int k = 0; k < NFFT; ++k) win[k] = 0.5f - 0.5f * cosf(2.0f * (float)M_PI * k / NFFT);
    rx_err = NULL;
    rx_frames_prev = 0;
    rx_fps = 0;
    rx_fps_t = esp_timer_get_time();
    rx_on = av_rx_start();
    if (!rx_on) rx_err = "Receiver did not start (radio busy?)";
}

static void rx_leave(void) {
    if (!rx_on) return;
    av_rx_stop();
    rx_on = false;
}

/* spectrum of the newest input samples while there is no picture yet */
static void rx_spectrum(void) {
    int16_t iq[512];
    if (!rx_pipe_snapshot(iq)) return;
    for (int k = 0; k < NFFT; ++k) { fre[k] = iq[2 * k] * win[k]; fim[k] = iq[2 * k + 1] * win[k]; }
    fft(fre, fim, NFFT);
    float db[NFFT], sorted[NFFT];
    for (int k = 0; k < NFFT; ++k) {
        const int m = (k + NFFT / 2) & (NFFT - 1);
        db[k] = 10.0f * log10f(fre[m] * fre[m] + fim[m] * fim[m] + 1e-3f);
        sorted[k] = db[k];
    }
    for (int i = 1; i < NFFT; ++i) { const float t = sorted[i]; int j = i - 1; while (j >= 0 && sorted[j] > t) { sorted[j + 1] = sorted[j]; --j; } sorted[j + 1] = t; }
    const float fl = sorted[NFFT / 2] - 6.0f, top = fl + 60.0f;
    gfx_fill(0, PIC_Y, LCD_W, PIC_H, RGB(8, 10, 16));
    for (int x = 0; x < LCD_W; x += 40) gfx_vline(x, PIC_Y, PIC_H, RGB(26, 32, 44));
    gfx_text(6, PIC_Y + 4, 1, C_DIM, "searching for a DVB-S signal... (250 kHz span)");
    int prev = -1;
    for (int x = 0; x < LCD_W; ++x) {
        int h = (int)((db[x * NFFT / LCD_W] - fl) / (top - fl) * (PIC_H - 20));
        if (h < 0) h = 0;
        if (h > PIC_H - 21) h = PIC_H - 21;
        const int y = PIC_Y + PIC_H - 1 - h;
        if (prev >= 0) gfx_vline(x, y < prev ? y : prev, abs(prev - y) + 1, C_OK);
        prev = y;
    }
}

static void rx_tick(void) {
    char b[96];
    if (!rx_on) {
        gfx_text_bg(6, RX_STAT_Y + 1, 1, C_WARN, C_BG, rx_err ? rx_err : "Receiver off");
        return;
    }
    av_rx_stat_t st;
    if (av_rx_frame(&rx_pic)) {
        i420_to_rgb565(&rx_pic, gfx_fb + PIC_Y * LCD_W, LCD_W, LCD_W, PIC_H);
        gfx_dirty(PIC_Y, PIC_Y + PIC_H);
    }
    const int64_t now = esp_timer_get_time();
    if (now < rx_next_stat) return;
    rx_next_stat = now + 500000;
    av_rx_stats(&st);
    if (!st.picture) rx_spectrum();
    if (now - rx_fps_t >= 2000000) {
        rx_fps = (float)(st.frames - rx_frames_prev) * 1e6f / (float)(now - rx_fps_t);
        rx_frames_prev = st.frames;
        rx_fps_t = now;
    }
    gfx_fill(0, RX_STAT_Y, LCD_W, LCD_H - 14 - RX_STAT_Y, C_BG);
    if (st.locked)
        snprintf(b, sizeof(b), "LOCK %.0fdB %+.1fkHz %s %.0ffps %s", st.mer_db, st.offset_hz / 1000.0f,
                 st.fec >= 0 ? dvbs_fec_name[st.fec] : "-", rx_fps, st.service);
    else
        snprintf(b, sizeof(b), "no lock MER %.0f dB %+.1f kHz", st.mer_db, st.offset_hz / 1000.0f);
    gfx_text(4, RX_STAT_Y + 1, 1, st.locked ? C_OK : C_WARN, b);
    static uint32_t aud_prev;
    meter(LCD_W - 52, RX_STAT_Y + 1, 48, 8, st.audio_rms, st.audio_frames != aud_prev);
    aud_prev = st.audio_frames;
}

/* ------------------------------------------------------------ transmitter: start / stop, picture on air */

static i420_t tx_pic;
static int tx_frame;
static int64_t tx_next;
static bool tx_on;
static const char *tx_err;

static void *psram_alloc(unsigned long n) { return heap_caps_malloc(n, MALLOC_CAP_SPIRAM); }

static void tx_status(void) {
    char b[80], r[16];
    fmt_baud(r, sizeof(r), settings.baud);
    gfx_fill(0, PIC_Y + PIC_H, LCD_W, LCD_H - 14 - PIC_Y - PIC_H, C_BG);
    if (tx_on) {
        av_tx_stat_t st;
        av_tx_stats(&st);
        snprintf(b, sizeof(b), "ON AIR %s %s %lus %s", r, dvbs_fec_name[settings.fec], (unsigned long)(st.frames / 10),
                 st.audio_kbps ? (st.mic ? "mic" : "tone") : "");
        gfx_text(4, PIC_Y + PIC_H + 2, 1, C_WARN, b);
        meter(LCD_W - 52, PIC_Y + PIC_H + 2, 48, 8, st.audio_rms, st.audio_kbps != 0);
    } else {
        snprintf(b, sizeof(b), "%s  QPSK %s FEC %s  Enter/click: transmit", tx_err ? tx_err : "Off", r, dvbs_fec_name[settings.fec]);
        gfx_text(4, PIC_Y + PIC_H + 2, 1, C_FG, b);
    }
}

static void draw_tx_static(void) {
    gfx_fill(0, 0, LCD_W, LCD_H, C_BG);
    header(tx_on ? "ON AIR" : "Transmit");
    tx_status();
    footer(tx_on ? "Enter/click: stop   ball left: stop and back" : "Enter/click: start   ball left: back");
}

static void tx_toggle(void) {
    tx_err = NULL;
    if (tx_on) { av_tx_stop(); tx_on = false; }
    else {
        tx_on = av_tx_start();
        if (!tx_on) tx_err = "Could not start";
    }
    redraw = true;
}

static void tx_leave(void) {
    if (tx_on) { av_tx_stop(); tx_on = false; }
}

static void tx_tick(void) {
    const int64_t now = esp_timer_get_time();
    if (tx_on) {
        if (av_tx_preview(&tx_pic)) {                       /* exactly what is being encoded */
            i420_to_rgb565(&tx_pic, gfx_fb + PIC_Y * LCD_W, LCD_W, LCD_W, PIC_H);
            gfx_dirty(PIC_Y, PIC_Y + PIC_H);
        }
        if (now >= tx_next) { tx_next = now + 1000000; tx_status(); }
        return;
    }
    if (now < tx_next) return;
    tx_next = now + 100000;
    if (!tx_pic.y && !i420_alloc(&tx_pic, 160, 96, psram_alloc)) return;
    char text[96];
    snprintf(text, sizeof(text), "%s%s%s", settings.call, settings.text[0] ? "\n" : "", settings.text);
    test_pattern(&tx_pic, tx_frame++, 10, text);
    i420_to_rgb565(&tx_pic, gfx_fb + PIC_Y * LCD_W, LCD_W, LCD_W, PIC_H);
    gfx_dirty(PIC_Y, PIC_Y + PIC_H);
}

/* ------------------------------------------------------------ task */

static volatile int injected[8];
static volatile uint32_t inj_w, inj_r;

void ui_inject(int key) {
    if (inj_w - inj_r < 8) { injected[inj_w & 7] = key; ++inj_w; }
}

static int next_key(void) {
    if (inj_r != inj_w) { const int k = injected[inj_r & 7]; ++inj_r; return k; }
    return board_key();
}

static void ui_task(void *arg) {
    (void)arg;
    screen_t shown = (screen_t)-1;
    for (;;) {
        int k;
        while (scr == shown && (k = next_key()) != KEY_NONE) {   /* one screen change at a time: leave the old screen first */
            if (k == KEY_LEFT && scr != SCR_HOME && !(scr == SCR_SET && (editing || item_is_choice((item_t)set_sel)))) { scr = SCR_HOME; redraw = true; continue; }
            if (k == 'q' && scr != SCR_HOME && !editing) { scr = SCR_HOME; redraw = true; continue; }
            switch (scr) {
                case SCR_HOME: key_home(k); break;
                case SCR_SET: key_settings(k); break;
                case SCR_TX: if (k == KEY_ENTER || k == KEY_CLICK) tx_toggle(); break;
                default: break;
            }
        }
        if (scr != shown) {
            if (shown == SCR_RX) rx_leave();
            if (shown == SCR_TX) tx_leave();
            if (scr == SCR_RX) rx_enter();
            if (scr == SCR_TX) tx_next = 0;
            shown = scr;
            redraw = true;
        }
        if (redraw) {
            redraw = false;
            switch (scr) {
                case SCR_HOME: draw_home(); break;
                case SCR_SET: draw_settings(); break;
                case SCR_RX: draw_rx_static(); break;
                case SCR_TX: draw_tx_static(); break;
            }
        }
        if (scr == SCR_RX) rx_tick();
        if (scr == SCR_TX) tx_tick();
        gfx_flush();
        vTaskDelay(pdMS_TO_TICKS(20));
    }
}

bool ui_start(void) {
    if (!board_init(settings.lcd) || !gfx_init()) return false;
    xTaskCreatePinnedToCore(ui_task, "ui", 8192, NULL, 4, NULL, 0);
    return true;
}

void ui_lcd_flags(uint32_t f) {
    board_lcd_flags(f);
    redraw = true;
}
