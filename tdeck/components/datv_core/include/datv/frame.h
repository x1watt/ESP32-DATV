/* I420 frames, the test pattern and text overlay (port of app/lib/core/codec/image/convert.dart),
 * and conversion to RGB565 for the display. */
#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef struct {
    int w, h;                 /* even */
    uint8_t *y, *u, *v;       /* w x h, (w / 2) x (h / 2) each */
} i420_t;

bool i420_alloc(i420_t *f, int w, int h, void *(*alloc)(unsigned long));
/* Colour bars, a moving box and the elapsed time (mm:ss:ff), plus optional centred text (lines split by '\n'). */
void test_pattern(i420_t *f, int frame_no, int fps, const char *text);
void draw_centred_text(i420_t *f, const char *text, int x0, int y0, int bw, int bh);
/* Scales f into an RGB565 (native byte order) rectangle of dw x dh at dst with stride dstride (pixels), nearest neighbour. */
void i420_to_rgb565(const i420_t *f, uint16_t *dst, int dstride, int dw, int dh);
