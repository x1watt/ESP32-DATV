#include "av.h"
#include <math.h>
#include <string.h>
#include "datv/ts.h"
#include "esp_h264_dec_sw.h"
#include "esp_cpu.h"
#include "esp_heap_caps.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "freertos/idf_additions.h"
#include "rx_pipe.h"
#include "audio_io.h"
#include "board.h"
#include "datv/mp2dec.h"
#include "settings.h"

#define AU_SLOTS 6
#define AU_MAX 24576
#define VBUF 32768

static ts_demux_t *dmx;
static uint8_t *vbuf;
static uint8_t *au_buf[AU_SLOTS];
static uint32_t au_len[AU_SLOTS];
static volatile uint32_t au_w, au_r;
static volatile bool run, dec_running;
static av_rx_stat_t st;
static uint8_t *pic;                  /* newest decoded picture, I420 */
static int pic_w, pic_h;
static volatile bool pic_new;
static SemaphoreHandle_t pic_mtx;
static TaskHandle_t dec_task_h;
static volatile uint32_t cyc_video, cyc_audio, cyc_t0;

/* audio: MP2 PES payloads queued for the audio task */
#define AU_ASLOTS 8
#define AU_AMAX 4096
static uint8_t *aud_buf[AU_ASLOTS];
static uint32_t aud_len[AU_ASLOTS];
static volatile uint32_t aud_w, aud_r;
static volatile bool aud_running;
static TaskHandle_t aud_task_h;
static uint8_t *abuf;

/* MP2 frame length from its header (Layer II: 144000 * kbit/s / rate, + padding); 0 if not a header */
static uint32_t mp2_frame_len(const uint8_t *h) {
    static const uint16_t br1[16] = {0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0};
    static const uint16_t br2[16] = {0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0};
    static const uint32_t fs1[3] = {44100, 48000, 32000};
    if (h[0] != 0xFF || (h[1] & 0xE0) != 0xE0 || ((h[1] >> 1) & 3) != 2) return 0;   /* sync, Layer II */
    const bool lsf = !(h[1] & 0x08);
    const int bi = h[2] >> 4, fi = (h[2] >> 2) & 3;
    if (fi == 3 || !bi || bi == 15) return 0;
    const uint32_t fs = lsf ? fs1[fi] / 2 : fs1[fi];
    const uint32_t kbps = lsf ? br2[bi] : br1[bi];
    return 144000u * kbps / fs + ((h[2] >> 1) & 1u);
}

static void aud_task(void *arg) {
    (void)arg;
    static mp2dec_t dec;
    static int16_t pcm[MP2DEC_MAX_SAMPLES];
    mp2dec_init(&dec);
    bool speaker = false;
    const bool have_speaker = board_i2c_bus() != NULL;
    aud_running = true;
    while (run) {
        if (aud_r == aud_w) { ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(50)); continue; }
        const uint32_t k = aud_r % AU_ASLOTS;
        uint32_t c0 = esp_cpu_get_cycle_count();
        const uint8_t *p = aud_buf[k];
        uint32_t left = aud_len[k];
        while (left >= 4) {
            const uint32_t fl = mp2_frame_len(p);
            if (!fl) { ++p; --left; continue; }                 /* resynchronise on the next header */
            if (fl > left) break;
            int ch = 1, rate = 0;
            const int n = mp2dec_decode(&dec, p, fl, pcm, &ch, &rate);
            p += fl;
            left -= fl;
            if (n <= 0) continue;
            st.audio_frames++;
            st.audio_rate = rate;
            {   /* level and the share of a 1 kHz tone (lets a test check the sound without listening) */
                float e = 0, s1 = 0, s2 = 0;                       /* single precision: the S3 has no double FPU */
                const float c = 2.0f * cosf(2.0f * 3.14159265f * 1000.0f / (float)(rate ? rate : 16000));
                for (int i = 0; i < n; ++i) {
                    const float x = pcm[i * ch];
                    e += x * x;
                    const float s0 = x + c * s1 - s2;
                    s2 = s1;
                    s1 = s0;
                }
                const float tone = (s1 * s1 + s2 * s2 - c * s1 * s2) * 2.0f / (float)n;
                st.audio_rms = sqrtf(e / (float)n);
                st.audio_tone_pct = e > 0 ? 100.0f * tone / e : 0;
            }
            cyc_audio += esp_cpu_get_cycle_count() - c0;
            if (!have_speaker) { c0 = esp_cpu_get_cycle_count(); continue; }
            if (!speaker) speaker = audio_out_start(rate);
            if (ch == 2) for (int i = 0; i < n; ++i) pcm[i] = (int16_t)((pcm[2 * i] + pcm[2 * i + 1]) / 2);
            if (speaker) audio_out_write(pcm, n);                  /* blocks: paces the playback, not counted */
            c0 = esp_cpu_get_cycle_count();
        }
        aud_r++;
    }
    if (speaker) audio_out_stop();
    aud_running = false;
    aud_task_h = NULL;
    vTaskDeleteWithCaps(NULL);
}

static void on_pes(void *ctx, int kind, const uint8_t *pl, uint32_t len, int64_t pts90k, bool damaged) {
    (void)ctx; (void)pts90k;
    if (kind == 1) {
        if (damaged || !len || len > AU_AMAX || aud_w - aud_r >= AU_ASLOTS) return;
        const uint32_t k = aud_w % AU_ASLOTS;
        memcpy(aud_buf[k], pl, len);
        aud_len[k] = len;
        aud_w++;
        if (aud_task_h) xTaskNotifyGive(aud_task_h);
        return;
    }
    if (kind != 0 || damaged || !len || len > AU_MAX) return;
    if (au_w - au_r >= AU_SLOTS) return;                 /* decoder behind: drop */
    const uint32_t k = au_w % AU_SLOTS;
    memcpy(au_buf[k], pl, len);
    au_len[k] = len;
    au_w++;
    if (dec_task_h) xTaskNotifyGive(dec_task_h);
}

static void on_ts(const uint8_t *pkt) { ts_demux_push(dmx, pkt); }

static void dec_task(void *arg) {
    (void)arg;
    esp_h264_dec_handle_t h = NULL;
    const esp_h264_dec_cfg_sw_t cfg = {.pic_type = ESP_H264_RAW_FMT_I420};
    esp_h264_dec_param_sw_handle_t ph = NULL;
    if (esp_h264_dec_sw_new(&cfg, &h) != ESP_H264_ERR_OK || esp_h264_dec_open(h) != ESP_H264_ERR_OK) h = NULL;
    if (h) esp_h264_dec_sw_get_param_hd(h, &ph);
    dec_running = true;
    while (run) {
        if (au_r == au_w) { ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(50)); continue; }
        const uint32_t k = au_r % AU_SLOTS;
        const uint32_t c0 = esp_cpu_get_cycle_count();
        esp_h264_dec_in_frame_t in = {.raw_data = {.buffer = au_buf[k], .len = au_len[k]}};
        while (h && in.raw_data.len) {
            esp_h264_dec_out_frame_t out = {0};
            const esp_h264_err_t e = esp_h264_dec_process(h, &in, &out);
            if (e != ESP_H264_ERR_OK) { st.decode_errors++; break; }
            in.raw_data.buffer += in.consume;
            in.raw_data.len -= in.consume;
            if (out.out_size) {
                esp_h264_resolution_t res = {0};
                if (ph) esp_h264_dec_get_resolution(ph, &res);
                if (res.width && res.height && out.out_size >= (uint32_t)res.width * res.height * 3 / 2) {
                    xSemaphoreTake(pic_mtx, portMAX_DELAY);
                    const size_t n = (size_t)res.width * res.height * 3 / 2;
                    if (res.width != pic_w || res.height != pic_h) {
                        heap_caps_free(pic);
                        pic = heap_caps_malloc(n, MALLOC_CAP_SPIRAM);
                        pic_w = pic ? res.width : 0;
                        pic_h = pic ? res.height : 0;
                    }
                    if (pic) { memcpy(pic, out.outbuf, n); pic_new = true; st.frames++; }
                    xSemaphoreGive(pic_mtx);
                }
            }
            if (!in.consume) break;
        }
        cyc_video += esp_cpu_get_cycle_count() - c0;
        au_r++;
    }
    if (h) { esp_h264_dec_close(h); esp_h264_dec_del(h); }
    dec_running = false;
    dec_task_h = NULL;
    vTaskDeleteWithCaps(NULL);
}

bool av_rx_start(void) {
    if (run) return false;
    if (!dmx) dmx = heap_caps_malloc(sizeof(*dmx), MALLOC_CAP_SPIRAM);
    if (!vbuf) vbuf = heap_caps_malloc(VBUF, MALLOC_CAP_SPIRAM);
    for (int k = 0; k < AU_SLOTS; ++k) if (!au_buf[k]) au_buf[k] = heap_caps_malloc(AU_MAX, MALLOC_CAP_SPIRAM);
    if (!pic_mtx) pic_mtx = xSemaphoreCreateMutex();
    if (!abuf) abuf = heap_caps_malloc(8192, MALLOC_CAP_SPIRAM);
    for (int k = 0; k < AU_ASLOTS; ++k) if (!aud_buf[k]) aud_buf[k] = heap_caps_malloc(AU_AMAX, MALLOC_CAP_SPIRAM);
    if (!dmx || !vbuf || !au_buf[AU_SLOTS - 1] || !abuf || !aud_buf[AU_ASLOTS - 1]) return false;
    memset(&st, 0, sizeof(st));
    ts_demux_init(dmx, vbuf, VBUF, abuf, 8192, on_pes, NULL);
    au_w = au_r = 0;
    aud_w = aud_r = 0;
    run = true;
    /* the demodulator chain first: it needs internal RAM, which the codec libraries would otherwise take */
    if (!rx_pipe_start(settings.freq_khz, settings.baud, settings.fec, on_ts)) { run = false; return false; }
    bool ok = xTaskCreatePinnedToCoreWithCaps(dec_task, "h264dec", 24576, NULL, 5, &dec_task_h, 0, MALLOC_CAP_SPIRAM) == pdPASS;
    /* minimp3 keeps about 16 KB of scratch on its stack */
    ok = ok && xTaskCreatePinnedToCoreWithCaps(aud_task, "mp2dec", 24576, NULL, 5, &aud_task_h, 0, MALLOC_CAP_SPIRAM) == pdPASS;
    if (!ok) { av_rx_stop(); return false; }
    return true;
}

void av_rx_stop(void) {
    if (!run && !dec_running && !aud_running) return;
    rx_pipe_stop();
    run = false;
    if (dec_task_h) xTaskNotifyGive(dec_task_h);
    if (aud_task_h) xTaskNotifyGive(aud_task_h);
    while (dec_running || aud_running) vTaskDelay(1);
}

void av_rx_stats(av_rx_stat_t *s) {
    rx_pipe_stat_t p;
    rx_pipe_stats(&p);
    st.running = run;
    st.locked = p.locked;
    st.offset_hz = p.offset_hz;
    st.mer_db = p.mer_db;
    st.fec = p.fec;
    st.packets = p.packets;
    st.rs_failed = p.rs_failed;
    st.load = p.load_demod + p.load_dvbs;
    const uint32_t now = esp_cpu_get_cycle_count(), el = now - cyc_t0;
    st.load_video = el ? 100.0f * cyc_video / el : 0;
    st.load_audio = el ? 100.0f * cyc_audio / el : 0;
    cyc_video = cyc_audio = 0;
    cyc_t0 = now;
    if (dmx) {
        st.cc_errors = dmx->cc_errors;
        st.pes_damaged = dmx->pes_damaged;
        memcpy(st.service, dmx->service, sizeof(st.service));
        memcpy(st.provider, dmx->provider, sizeof(st.provider));
    }
    st.picture = pic != NULL;
    st.width = pic_w;
    st.height = pic_h;
    *s = st;
}

static void *ps_alloc_ul(unsigned long n) { return heap_caps_malloc(n, MALLOC_CAP_SPIRAM); }

bool av_rx_frame(i420_t *dst) {
    if (!pic_new || !pic_mtx) return false;
    xSemaphoreTake(pic_mtx, portMAX_DELAY);
    if (dst->w != pic_w || dst->h != pic_h || !dst->y) {
        heap_caps_free(dst->y);
        dst->y = NULL;
        if (!i420_alloc(dst, pic_w, pic_h, ps_alloc_ul)) { xSemaphoreGive(pic_mtx); return false; }
    }
    memcpy(dst->y, pic, (size_t)pic_w * pic_h * 3 / 2);
    pic_new = false;
    xSemaphoreGive(pic_mtx);
    return true;
}
