/* MPEG audio Layer I/II/III decoder: thin wrapper around minimp3 (third_party/minimp3, CC0-1.0),
 * built with Layer II support and without SIMD. One call decodes one complete frame.
 * minimp3 keeps about 16 KB of scratch on the stack during a call: size the task stack for it. */
#pragma once
#include <stddef.h>
#include <stdint.h>

#define MP2DEC_MAX_SAMPLES (1152 * 2) /* interleaved samples one frame can produce */

/* same layout as minimp3's mp3dec_t, which mp2dec.c checks at compile time */
typedef struct {
    float mdct_overlap[2][9 * 32], qmf_state[15 * 2 * 32];
    int reserv, free_format_bytes;
    unsigned char header[4], reserv_buf[511];
} mp2dec_t;

void mp2dec_init(mp2dec_t *d);

/* Decodes the frame in frame[0..len) into pcm (MP2DEC_MAX_SAMPLES interleaved samples); returns samples
 * per channel, 0 if no frame was decoded. channels and rate (either may be NULL) receive the format. */
int mp2dec_decode(mp2dec_t *d, const uint8_t *frame, size_t len, int16_t *pcm, int *channels, int *rate);
