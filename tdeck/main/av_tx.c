#include "av.h"
#include <string.h>
#include "datv/dvbs_tx.h"
#include "datv/mp2enc.h"
#include "audio_io.h"
#include "board.h"
#include <math.h>
#include "datv/ts.h"
#include "esp_h264_enc_single_sw.h"
#include "esp_h264_alloc.h"
#include "esp_heap_caps.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "freertos/idf_additions.h"
#include "radio.h"
#include "settings.h"
#include "tx_core1.h"

#define W 160
#define H 96
#define FPS 10

static volatile bool run, running;
static ts_mux_t *mux;
static dvbs_enc_t *enc;
static av_tx_stat_t st;
static i420_t pic, prev;
static volatile bool prev_new;
static SemaphoreHandle_t prev_mtx;

/* audio: 16 kHz mono MP2, from the microphone (T-Deck) or a 1 kHz tone */
#define AUDIO_RATE 16000
#define MIC_RING 16384u
static mp2enc_t *mp2;
static int audio_kbps;                 /* 0: no audio */
static bool use_mic;
static int16_t *mic_ring;
static volatile uint32_t mic_w, mic_r;
static volatile bool mic_run, mic_running;
static uint32_t aframes;

static void mic_task(void *arg) {
    (void)arg;
    int16_t buf[256];
    mic_running = true;
    while (mic_run) {
        const int n = audio_in_read(buf, 256);
        if (n <= 0) { vTaskDelay(1); continue; }
        if (MIC_RING - (mic_w - mic_r) < (uint32_t)n) { mic_r += (uint32_t)n; }   /* the mux fell behind: drop the oldest */
        for (int k = 0; k < n; ++k) mic_ring[(mic_w + (uint32_t)k) & (MIC_RING - 1u)] = buf[k];
        mic_w += (uint32_t)n;
    }
    mic_running = false;
    vTaskDelete(NULL);
}

/* one MP2 frame into the mux if its time has come; true if one was added */
static bool audio_step(ts_mux_t *m, int16_t *pcm, uint8_t *frame) {
    if (!audio_kbps) return false;
    const int64_t pts = (int64_t)aframes * MP2_FRAME_SAMPLES * 1000000 / AUDIO_RATE;
    if (ts_mux_ahead(m, pts) > 1.0) return false;
    if (use_mic) {
        if (mic_w - mic_r < MP2_FRAME_SAMPLES) return false;
        for (int k = 0; k < MP2_FRAME_SAMPLES; ++k) pcm[k] = mic_ring[(mic_r + (uint32_t)k) & (MIC_RING - 1u)];
        mic_r += MP2_FRAME_SAMPLES;
    } else {
        for (int k = 0; k < MP2_FRAME_SAMPLES; ++k) {
            const uint32_t n = aframes * MP2_FRAME_SAMPLES + (uint32_t)k;
            pcm[k] = (int16_t)(6000.0f * sinf(2.0f * 3.14159265f * (float)(n % 16u) / 16.0f));   /* 1 kHz: 16 samples per period at 16 kHz */
        }
    }
    float e = 0;
    for (int k = 0; k < MP2_FRAME_SAMPLES; ++k) e += (float)pcm[k] * (float)pcm[k];
    st.audio_rms = sqrtf(e / MP2_FRAME_SAMPLES);
    const size_t len = mp2enc_encode(mp2, pcm, frame);
    if (len) ts_mux_add_audio(m, frame, (uint32_t)len, pts);
    aframes++;
    return true;
}

static void *ps_alloc(size_t n) { return heap_caps_malloc(n, MALLOC_CAP_SPIRAM); }
static void *ps_alloc_ul(unsigned long n) { return heap_caps_malloc(n, MALLOC_CAP_SPIRAM); }

static void tx_task(void *arg) {
    (void)arg;
    esp_h264_enc_handle_t h = NULL;
    const esp_h264_enc_cfg_sw_t cfg = {
        .pic_type = ESP_H264_RAW_FMT_I420, .gop = 2 * FPS, .fps = FPS, .res = {.width = W, .height = H},
        .rc = {.bitrate = st.video_bps, .qp_min = 24, .qp_max = 48},
    };
    uint32_t in_len = 0, out_len = 0;
    uint8_t *in = esp_h264_aligned_calloc(16, 1, W * H * 3 / 2, &in_len, MALLOC_CAP_SPIRAM);
    uint8_t *out = esp_h264_aligned_calloc(16, 1, W * H * 2, &out_len, MALLOC_CAP_SPIRAM);
    esp_h264_err_t e1 = in && out ? esp_h264_enc_sw_new(&cfg, &h) : ESP_H264_ERR_MEM;
    esp_h264_err_t e2 = e1 == ESP_H264_ERR_OK ? esp_h264_enc_open(h) : e1;
    if (e2 != ESP_H264_ERR_OK) run = false;
    static int16_t apcm[MP2_FRAME_SAMPLES];
    static uint8_t aframe[MP2_FRAME_BYTES_MAX];
    char text[96];
    snprintf(text, sizeof(text), "%s%s%s", settings.call, settings.text[0] ? "\n" : "", settings.text);
    uint8_t pkt[TS_PKT], sym[dvbs_enc_max_out(1)];
    running = true;
    while (run) {
        /* keep the modulator fed at exactly the channel rate */
        while (tx_room() >= sizeof(sym)) {
            ts_mux_next(mux, pkt);
            tx_push(sym, (uint32_t)dvbs_enc(enc, pkt, 1, sym));
        }
        while (audio_step(mux, apcm, aframe)) {}
        /* one more picture while the next one would be less than a second ahead of the mux clock (real time on air) */
        if (ts_mux_ahead(mux, (int64_t)st.frames * (1000000 / FPS)) < 1.0) {
            test_pattern(&pic, (int)st.frames, FPS, text);
            memcpy(in, pic.y, W * H * 3 / 2);
            esp_h264_enc_in_frame_t fi = {.raw_data = {.buffer = in, .len = in_len}, .pts = st.frames * (1000 / FPS)};
            esp_h264_enc_out_frame_t fo = {.raw_data = {.buffer = out, .len = out_len}};
            const esp_h264_err_t pe = esp_h264_enc_process(h, &fi, &fo);
            if (pe == ESP_H264_ERR_OK && fo.length) {
                ts_mux_add_video(mux, out, fo.length, (int64_t)st.frames * (1000000 / FPS));
                st.bytes += fo.length;
            }
            st.frames++;
            if (xSemaphoreTake(prev_mtx, 0) == pdTRUE) {
                memcpy(prev.y, pic.y, W * H * 3 / 2);
                prev_new = true;
                xSemaphoreGive(prev_mtx);
            }
        } else {
            vTaskDelay(pdMS_TO_TICKS(10));
        }
    }
    if (h) { esp_h264_enc_close(h); esp_h264_enc_del(h); }
    esp_h264_free(in);
    esp_h264_free(out);
    running = false;
    vTaskDeleteWithCaps(NULL);
}

bool av_tx_start(void) {
    if (running) return false;
    const double cap = dvbs_ts_rate(settings.baud, (dvbs_fec_t)settings.fec);
    const uint32_t mux_rate = (uint32_t)cap;
    /* the app's budget for low rates (app/lib/core/esp/tx_config.dart): PSI once a second, MP2 16 kbit/s mono at 16 kHz
       (8 kbit/s below a 40 kbit/s mux), 88 % of the rest for video */
    const double psi = 3 * 188 * 8 / 1.0;
    audio_kbps = settings.audio == 2 ? 0 : cap * 0.965 < 40000 ? 8 : 16;
    memset(&st, 0, sizeof(st));
    st.video_bps = (uint32_t)((cap * 0.965 - audio_kbps * 1000 - psi) * 0.88);
    st.audio_kbps = audio_kbps;
    aframes = 0;
    if (audio_kbps) {
        if (!mp2) mp2 = heap_caps_malloc(sizeof(*mp2), MALLOC_CAP_SPIRAM);
        if (!mp2 || !mp2enc_init(mp2, AUDIO_RATE, 1, audio_kbps)) audio_kbps = 0;
    }
    use_mic = false;
    if (audio_kbps && settings.audio == 0 && board_i2c_bus()) {
        if (!mic_ring) mic_ring = heap_caps_malloc(MIC_RING * 2, MALLOC_CAP_SPIRAM);
        if (mic_ring && audio_in_start(AUDIO_RATE)) {
            mic_w = mic_r = 0;
            mic_run = true;
            xTaskCreatePinnedToCore(mic_task, "mic", 4096, NULL, 6, NULL, 0);
            use_mic = true;
        }
    }
    st.mic = use_mic;
    st.mux_rate = mux_rate;
    st.width = W; st.height = H; st.fps = FPS;
    if (!mux) mux = heap_caps_malloc(sizeof(*mux), MALLOC_CAP_SPIRAM);
    if (!pic.y && !i420_alloc(&pic, W, H, ps_alloc_ul)) return false;
    if (!prev.y && !i420_alloc(&prev, W, H, ps_alloc_ul)) return false;
    if (!prev_mtx) prev_mtx = xSemaphoreCreateMutex();
    if (!mux) return false;
    ts_mux_init(mux, mux_rate, settings.call, "T-Deck DATV", audio_kbps != 0, ps_alloc, heap_caps_free);
    mux->pat_period_ms = 1000;
    if (!enc) enc = heap_caps_malloc(sizeof(*enc), MALLOC_CAP_SPIRAM);
    if (!enc) return false;
    dvbs_enc_init(enc, (dvbs_fec_t)settings.fec, false, false);
    if (!radio_lock()) return false;
    const tx_params_t p = {.fkhz = settings.freq_khz, .baud = settings.baud, .amp = settings.amp, .ppm = settings.ppm_x10 / 10.0, .gain = 1.0f};
    if (!tx_start(&p)) { radio_unlock(); return false; }
    run = true;
    /* openh264 needs a deep stack; internal RAM is short, so it lives in PSRAM */
    xTaskCreatePinnedToCoreWithCaps(tx_task, "avtx", 24576, NULL, 5, NULL, 0, MALLOC_CAP_SPIRAM);
    for (int k = 0; k < 100 && !running && run; ++k) vTaskDelay(1);
    if (!run) { tx_stop(); radio_unlock(); return false; }
    return true;
}

void av_tx_stop(void) {
    if (!run && !running) return;
    run = false;
    while (running) vTaskDelay(1);
    if (use_mic) {
        mic_run = false;
        while (mic_running) vTaskDelay(1);
        audio_in_stop();
        use_mic = false;
    }
    tx_stop();
    radio_unlock();
}

void av_tx_stats(av_tx_stat_t *s) {
    st.running = running;
    if (mux) { st.buffered = ts_mux_buffered(mux); st.null_packets = mux->null_packets; st.dropped = mux->dropped; }
    st.underruns = tx_status()->underruns;
    st.audio_frames = aframes;
    *s = st;
}

bool av_tx_preview(i420_t *dst) {
    if (!prev_new || !prev_mtx) return false;
    if (!dst->y && !i420_alloc(dst, W, H, ps_alloc_ul)) return false;
    xSemaphoreTake(prev_mtx, portMAX_DELAY);
    memcpy(dst->y, prev.y, W * H * 3 / 2);
    prev_new = false;
    xSemaphoreGive(prev_mtx);
    return true;
}
