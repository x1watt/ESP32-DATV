/* Audio/video sessions. Transmit: test card with callsign and text -> H.264 (esp_h264) -> TS mux ->
 * DVB-S encoder -> modulator. Receive: demodulator -> DVB-S -> TS demux -> H.264 decoder -> picture. */
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "datv/frame.h"

typedef struct {
    bool running;
    uint32_t frames, bytes, video_bps, mux_rate;
    double buffered;
    uint32_t underruns, null_packets, dropped;
    int width, height, fps;
    int audio_kbps;              /* 0: no audio */
    bool mic;                    /* microphone, else a 1 kHz tone */
    uint32_t audio_frames;
    float audio_rms;             /* level of the last audio frame */
} av_tx_stat_t;

bool av_tx_start(void);          /* from the settings (frequency, symbol rate, FEC, callsign, text, level, ppm) */
void av_tx_stop(void);
void av_tx_stats(av_tx_stat_t *s);
bool av_tx_preview(i420_t *dst); /* copies the last transmitted picture if there is a new one */

typedef struct {
    bool running, locked, picture;
    float offset_hz, mer_db;
    int fec;
    uint32_t packets, rs_failed, cc_errors, frames, decode_errors, pes_damaged;
    uint32_t audio_frames;       /* MP2 frames played */
    int audio_rate;
    float audio_rms, audio_tone_pct;   /* last frame: level and % of its energy at 1 kHz */
    int width, height;
    float load;                  /* core 0 load of the demodulator chain, % */
    float load_video, load_audio;
    char service[32], provider[32];
} av_rx_stat_t;

bool av_rx_start(void);
void av_rx_stop(void);
void av_rx_stats(av_rx_stat_t *s);
bool av_rx_frame(i420_t *dst);   /* copies the newest decoded picture if there is a new one (dst is (re)allocated in PSRAM) */
