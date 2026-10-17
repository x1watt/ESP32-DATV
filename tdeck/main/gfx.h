/* Minimal drawing on a 320x240 RGB565 frame in PSRAM, flushed to the panel by dirty rows. */
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "board.h"

#define RGB(r, g, b) ((uint16_t)((((r) & 0xF8) << 8) | (((g) & 0xFC) << 3) | ((b) >> 3)))

extern uint16_t *gfx_fb;

bool gfx_init(void);
void gfx_fill(int x, int y, int w, int h, uint16_t c);
void gfx_hline(int x, int y, int w, uint16_t c);
void gfx_vline(int x, int y, int h, uint16_t c);
void gfx_rect(int x, int y, int w, int h, uint16_t c);
/* 5x7 font in a 6x8 cell, times scale; returns the x after the text. bg 0xFFFF... use gfx_text_bg for a background. */
int gfx_text(int x, int y, int scale, uint16_t fg, const char *s);
int gfx_text_bg(int x, int y, int scale, uint16_t fg, uint16_t bg, const char *s);
int gfx_text_w(int scale, const char *s);
void gfx_flush(void);                           /* sends the dirty rows */
void gfx_dirty(int y0, int y1);
