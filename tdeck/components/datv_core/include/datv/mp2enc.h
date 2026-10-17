/* MPEG-1/2 Layer II ("mp2") audio encoder, port of app/lib/core/codec/audio/mp2_encoder.dart.
 * MPEG-1 at 32/44.1/48 kHz and MPEG-2 LSF at 16/22.05/24 kHz, mono or stereo (independent channels),
 * CRC off, padding for the 44.1/22.05 kHz families. Same tables, psychoacoustic model and allocation as
 * the Dart, and with doubles (the default) the output is bit-identical to it on the same libm.
 *
 * MP2ENC_FLOAT=1 runs the per-frame work in single precision (the ESP32-S3 has a single-precision FPU
 * only and does doubles in software); the datv_core component sets it for ESP-IDF builds. Output then
 * differs slightly from the Dart. Only init uses doubles in that mode.
 *
 * No allocation: the state lives in the struct (144 KB with doubles, 74 KB with floats, so make it
 * static or put it in PSRAM, not on a task stack). */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define MP2_FRAME_SAMPLES 1152 /* samples per channel in one frame */
#define MP2_CODEC_DELAY 481    /* decoder output lags the encoder input by this many samples */
#define MP2_FRAME_BYTES_MAX 1728 /* 384 kbit/s at 32 kHz */

#if defined(MP2ENC_FLOAT) && MP2ENC_FLOAT
typedef float mp2_real_t;
#else
typedef double mp2_real_t;
#endif

#define MP2_HIST (480 + MP2_FRAME_SAMPLES)
#define MP2_FFT_N 1024
#define MP2_LINES (MP2_FFT_N / 2 + 1)
#define MP2_MAX_PART 76 /* 1/3 Bark partitions up to 24 kHz */

typedef struct {
    mp2_real_t re[MP2_FFT_N], im[MP2_FFT_N], hann[MP2_FFT_N], cosv[MP2_FFT_N / 2], sinv[MP2_FFT_N / 2];
    int16_t rev[MP2_FFT_N];
    mp2_real_t power[MP2_LINES], thr[MP2_LINES], ath[MP2_LINES];
    uint8_t part[MP2_LINES];
    int npart;
    int16_t pcnt[MP2_MAX_PART];
    mp2_real_t pe[MP2_MAX_PART], pmax[MP2_MAX_PART], pbark[MP2_MAX_PART], poff[MP2_MAX_PART], pthr[MP2_MAX_PART];
    mp2_real_t spr_norm[MP2_MAX_PART], spread[MP2_MAX_PART * MP2_MAX_PART];
    mp2_real_t lsb[32];
} mp2_psy_t;

typedef struct mp2enc {
    int sample_rate, channels, bitrate_kbps;
    bool lsf;
    int freq_index, bitrate_index;
    int slots, pad_incr, pad_acc;  /* frame bytes = slots (+1 padding) */
    int sblimit, bw_target;
    uint8_t nbal[32], alloc_q[32][16];
    mp2_real_t hist[2][MP2_HIST];  /* 480 samples of filter memory + one frame */
    mp2_real_t sb[2][36 * 32];     /* subband samples */
    mp2_real_t smr[2][32];
    uint8_t scf[2][32 * 3], scfsi[2][32], alloc[2][32];
    uint32_t frames;               /* frames produced so far */
    mp2_psy_t psy;
} mp2enc_t;

/* True when bitrate_kbps is a valid Layer II rate for this sample rate and channel count
 * (MPEG-1 forbids mono above 192 and stereo at 32/48/56/80). */
bool mp2enc_valid(int sample_rate, int channels, int bitrate_kbps);

/* sample_rate 16000/22050/24000/32000/44100/48000, channels 1 or 2; false if the combination is invalid. */
bool mp2enc_init(mp2enc_t *e, int sample_rate, int channels, int bitrate_kbps);

/* Largest frame mp2enc_encode() can write (nominal size, plus one byte when padding is used). */
size_t mp2enc_frame_bytes_max(const mp2enc_t *e);

/* Encodes one frame from MP2_FRAME_SAMPLES * channels interleaved samples into out (at least
 * mp2enc_frame_bytes_max() bytes); returns the frame length. To flush the filterbank delay at the end of
 * a stream, encode one more frame of silence (as the Dart flush() does). */
size_t mp2enc_encode(mp2enc_t *e, const int16_t *pcm, uint8_t *out);
