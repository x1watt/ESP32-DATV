#include "gfx.h"
#include <string.h>
#include "esp_heap_caps.h"
#include "datv/font5x7.h"

uint16_t *gfx_fb;
static int dirty0 = LCD_H, dirty1 = 0;

bool gfx_init(void) {
    gfx_fb = heap_caps_calloc(LCD_W * LCD_H, 2, MALLOC_CAP_SPIRAM);
    if (!gfx_fb) return false;
    gfx_dirty(0, LCD_H);
    return true;
}

void gfx_dirty(int y0, int y1) {
    if (y0 < 0) y0 = 0;
    if (y1 > LCD_H) y1 = LCD_H;
    if (y0 < dirty0) dirty0 = y0;
    if (y1 > dirty1) dirty1 = y1;
}

void gfx_fill(int x, int y, int w, int h, uint16_t c) {
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > LCD_W) w = LCD_W - x;
    if (y + h > LCD_H) h = LCD_H - y;
    if (w <= 0 || h <= 0) return;
    for (int r = y; r < y + h; ++r) {
        uint16_t *p = gfx_fb + r * LCD_W + x;
        for (int k = 0; k < w; ++k) p[k] = c;
    }
    gfx_dirty(y, y + h);
}

void gfx_hline(int x, int y, int w, uint16_t c) { gfx_fill(x, y, w, 1, c); }
void gfx_vline(int x, int y, int h, uint16_t c) { gfx_fill(x, y, 1, h, c); }
void gfx_rect(int x, int y, int w, int h, uint16_t c) {
    gfx_hline(x, y, w, c); gfx_hline(x, y + h - 1, w, c);
    gfx_vline(x, y, h, c); gfx_vline(x + w - 1, y, h, c);
}

static int text(int x, int y, int sc, uint16_t fg, int bg, const char *s) {
    for (; *s; ++s) {
        unsigned ch = (unsigned char)*s;
        if (ch < 0x20 || ch > 0x7E) ch = '?';
        const uint8_t *g = font5x7[ch - 0x20];
        if (bg >= 0) gfx_fill(x, y, 6 * sc, 8 * sc, (uint16_t)bg);
        for (int col = 0; col < 5; ++col)
            for (int row = 0; row < 7; ++row)
                if (g[col] >> row & 1) gfx_fill(x + col * sc, y + row * sc, sc, sc, fg);
        x += 6 * sc;
    }
    gfx_dirty(y, y + 8 * sc);
    return x;
}

int gfx_text(int x, int y, int sc, uint16_t fg, const char *s) { return text(x, y, sc, fg, -1, s); }
int gfx_text_bg(int x, int y, int sc, uint16_t fg, uint16_t bg, const char *s) { return text(x, y, sc, fg, bg, s); }
int gfx_text_w(int sc, const char *s) { return (int)strlen(s) * 6 * sc; }

void gfx_flush(void) {
    if (dirty0 >= dirty1) return;
    board_lcd_flush(gfx_fb, dirty0, dirty1);
    dirty0 = LCD_H;
    dirty1 = 0;
}
