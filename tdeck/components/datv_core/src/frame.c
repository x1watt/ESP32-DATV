#include "datv/frame.h"
#include <string.h>
#include "datv/font5x7.h"

bool i420_alloc(i420_t *f, int w, int h, void *(*alloc)(unsigned long)) {
    f->w = w;
    f->h = h;
    f->y = alloc((unsigned long)w * h * 3 / 2);
    if (!f->y) return false;
    f->u = f->y + w * h;
    f->v = f->u + (w / 2) * (h / 2);
    return true;
}

static const uint8_t bars[7][3] = {
    {180, 128, 128}, {162, 44, 142}, {131, 156, 44}, {112, 72, 58}, {84, 184, 198}, {65, 100, 212}, {35, 212, 114},
};

static void fill_luma(i420_t *f, int x0, int y0, int x1, int y1, int luma) {
    const int xa = x0 < 0 ? 0 : x0, ya = y0 < 0 ? 0 : y0;
    const int xb = x1 > f->w ? f->w : x1, yb = y1 > f->h ? f->h : y1;
    const int cw = f->w >> 1;
    for (int y = ya; y < yb; ++y)
        if (xb > xa) memset(f->y + y * f->w + xa, luma, (size_t)(xb - xa));
    for (int y = ya >> 1; y < (yb + 1) >> 1 && y < f->h >> 1; ++y) {    /* neutral chroma: grey whatever lies below */
        const int s0 = xa >> 1;
        int s1 = (xb + 1) >> 1;
        if (s1 > cw) s1 = cw;
        if (s1 > s0) {
            memset(f->u + y * cw + s0, 128, (size_t)(s1 - s0));
            memset(f->v + y * cw + s0, 128, (size_t)(s1 - s0));
        }
    }
}

static void draw_text(i420_t *f, const char *s, int n, int x0, int y0, int scale, int luma) {
    int x = x0;
    for (int i = 0; i < n; ++i) {
        unsigned ch = (unsigned char)s[i];
        if (ch < 0x20 || ch > 0x7E) ch = '?';
        const uint8_t *cols = font5x7[ch - 0x20];
        for (int c = 0; c < 5; ++c)
            for (int r = 0; r < 7; ++r) {
                if (!((cols[c] >> r) & 1)) continue;
                for (int dy = 0; dy < scale; ++dy) {
                    const int py = y0 + r * scale + dy;
                    if (py < 0 || py >= f->h) continue;
                    for (int dx = 0; dx < scale; ++dx) {
                        const int px = x + c * scale + dx;
                        if (px >= 0 && px < f->w) f->y[py * f->w + px] = (uint8_t)luma;
                    }
                }
            }
        x += 6 * scale;
    }
}

#define MAX_LINES 8
void draw_centred_text(i420_t *f, const char *text, int x0, int y0, int bw, int bh) {
    /* wrap words so that every line fits at the smallest size */
    const int fit = (int)(bw * 0.95) / 6;
    const char *ls[MAX_LINES];
    int ln[MAX_LINES], nl = 0;
    const char *p = text;
    while (*p && nl < MAX_LINES) {
        const char *para_end = strchr(p, '\n');
        if (!para_end) para_end = p + strlen(p);
        const char *line = p;
        int len = 0;
        const char *w = p;
        while (w < para_end) {
            while (w < para_end && *w == ' ') ++w;
            const char *we = w;
            while (we < para_end && *we != ' ') ++we;
            if (we == w) break;
            const int next = (int)(we - line);
            if (next <= fit || len == 0) len = next;
            else {
                if (nl < MAX_LINES) { ls[nl] = line; ln[nl++] = len; }
                line = w;
                len = (int)(we - w);
            }
            w = we;
        }
        if (nl < MAX_LINES) { ls[nl] = line; ln[nl++] = len; }
        p = *para_end ? para_end + 1 : para_end;
    }
    while (nl && ln[nl - 1] == 0) --nl;
    if (!nl) return;
    int maxc = 0;
    for (int i = 0; i < nl; ++i) if (ln[i] > maxc) maxc = ln[i];
    if (!maxc) return;
    /* a character cell is 6 x 9 dots (5 x 7 glyph, one column and two rows of spacing) */
    int scale = (int)(bw * 0.9) / (maxc * 6);
    const int byh = (int)(bh * 0.9) / (nl * 9);
    if (byh < scale) scale = byh;
    if (scale > 12) scale = 12;
    if (scale < 1) scale = 1;
    const int th = nl * 9 * scale - 2 * scale, ty = y0 + (bh - th) / 2, tw = maxc * 6 * scale - scale;
    fill_luma(f, x0 + (bw - tw) / 2 - 2 * scale, ty - 2 * scale, x0 + (bw + tw) / 2 + 2 * scale, ty + th + 2 * scale, 16);
    for (int i = 0; i < nl; ++i) {
        const int lw = ln[i] * 6 * scale - scale;
        draw_text(f, ls[i], ln[i], x0 + (bw - lw) / 2, ty + i * 9 * scale, scale, 235);
    }
}

void test_pattern(i420_t *f, int frame_no, int fps, const char *text) {
    const int w = f->w, h = f->h, cw = w >> 1;
    const int bar_h = h * 2 / 3;
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x) {
            uint8_t c[3];
            if (y < bar_h) memcpy(c, bars[x * 7 / w], 3);
            else { c[0] = (uint8_t)(16 + x * 219 / w); c[1] = c[2] = 128; }
            f->y[y * w + x] = c[0];
            if (!(x & 1) && !(y & 1)) {
                f->u[(y >> 1) * cw + (x >> 1)] = c[1];
                f->v[(y >> 1) * cw + (x >> 1)] = c[2];
            }
        }
    /* moving box */
    const int bs = h / 6 & ~1, span = w - bs;
    const int pos = span <= 0 ? 0 : (frame_no * 4) % (2 * span);
    const int bx = (pos < span ? pos : 2 * span - pos) & ~1, by = (bar_h - bs) / 2 & ~1;
    for (int y = by; y < by + bs; ++y)
        for (int x = bx; x < bx + bs && x < w; ++x) {
            f->y[y * w + x] = 235;
            f->u[(y >> 1) * cw + (x >> 1)] = 128;
            f->v[(y >> 1) * cw + (x >> 1)] = 128;
        }
    const int secs = frame_no / fps, ff = frame_no % fps;
    char clock[16];
    clock[0] = (char)('0' + secs / 60 % 60 / 10); clock[1] = (char)('0' + secs / 60 % 60 % 10); clock[2] = ':';
    clock[3] = (char)('0' + secs % 60 / 10); clock[4] = (char)('0' + secs % 60 % 10); clock[5] = ':';
    clock[6] = (char)('0' + ff / 10 % 10); clock[7] = (char)('0' + ff % 10); clock[8] = 0;
    int scale = h / 60;
    if (scale < 1) scale = 1;
    if (scale > 8) scale = 8;
    const int tw = 8 * 6 * scale, ty = bar_h + (h - bar_h - 7 * scale) / 2;
    for (int y = ty - scale; y < ty + 8 * scale && y < h; ++y)
        for (int x = (w - tw) / 2 - scale; x < (w + tw) / 2 + scale && x < w; ++x)
            if (x >= 0 && y >= 0) f->y[y * w + x] = 16;
    draw_text(f, clock, 8, (w - tw) / 2, ty, scale, 235);
    if (text) {
        const char *t = text;
        while (*t == ' ' || *t == '\n') ++t;
        if (*t) draw_centred_text(f, text, 0, 0, w, bar_h);
    }
}

static inline uint8_t clip(int v) { return v < 0 ? 0 : v > 255 ? 255 : (uint8_t)v; }

void i420_to_rgb565(const i420_t *f, uint16_t *dst, int dstride, int dw, int dh) {
    static uint16_t xmap[1024];                          /* source column of every output column (no division per pixel) */
    if (dw > 1024) dw = 1024;
    for (int x = 0; x < dw; ++x) xmap[x] = (uint16_t)(x * f->w / dw);
    for (int y = 0; y < dh; ++y) {
        const int sy = y * f->h / dh;
        const uint8_t *py = f->y + sy * f->w, *pu = f->u + (sy >> 1) * (f->w >> 1), *pv = f->v + (sy >> 1) * (f->w >> 1);
        uint16_t *d = dst + y * dstride;
        int last = -1;
        uint16_t px = 0;
        for (int x = 0; x < dw; ++x) {
            const int sx = xmap[x];
            if (sx != last) {                               /* scaled up: neighbours share a source pixel */
                last = sx;
                const int c = 298 * (py[sx] - 16), du = pu[sx >> 1] - 128, dv = pv[sx >> 1] - 128;   /* BT.601 limited range */
                const uint8_t r = clip((c + 409 * dv + 128) >> 8), g = clip((c - 100 * du - 208 * dv + 128) >> 8), b = clip((c + 516 * du + 128) >> 8);
                px = (uint16_t)(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
            }
            d[x] = px;
        }
    }
}
