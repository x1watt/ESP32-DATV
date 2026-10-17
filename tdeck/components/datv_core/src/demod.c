#include "datv/demod.h"
#include <math.h>
#include <string.h>

#define PI_F 3.14159265f
#define SOFT_SCALE 40.0f

uint32_t (*demod_clock)(void);
uint32_t demod_prof[4];

size_t demod_work_bytes(void) {
    return 2u * DEMOD_FINE_N * sizeof(cpx_t) + DEMOD_ACQ_FFT * sizeof(float) + (DEMOD_PHASES + 1u) * DEMOD_MF_MAX * sizeof(float);
}

static void fft(cpx_t *x, uint32_t n) {
    for (uint32_t i = 1, j = 0; i < n; ++i) {
        uint32_t bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) { const cpx_t t = x[i]; x[i] = x[j]; x[j] = t; }
    }
    for (uint32_t len = 2; len <= n; len <<= 1) {
        const float a = -2.0f * PI_F / (float)len;
        const cpx_t w = {cosf(a), sinf(a)};
        for (uint32_t i = 0; i < n; i += len) {
            cpx_t c = {1, 0};
            for (uint32_t k = 0; k < len / 2; ++k) {
                cpx_t *p = &x[i + k], *q = &x[i + k + len / 2];
                const cpx_t t = {q->re * c.re - q->im * c.im, q->re * c.im + q->im * c.re};
                q->re = p->re - t.re; q->im = p->im - t.im;
                p->re += t.re; p->im += t.im;
                const float nr = c.re * w.re - c.im * w.im;
                c.im = c.re * w.im + c.im * w.re;
                c.re = nr;
            }
        }
    }
}

static float rrc(float t, float b) {
    if (fabsf(t) < 1e-6f) return 1.0f - b + 4.0f * b / PI_F;
    if (fabsf(fabsf(t) - 1.0f / (4.0f * b)) < 1e-4f)
        return b / 1.41421356f * ((1.0f + 2.0f / PI_F) * sinf(PI_F / (4.0f * b)) + (1.0f - 2.0f / PI_F) * cosf(PI_F / (4.0f * b)));
    return (sinf(PI_F * t * (1.0f - b)) + 4.0f * b * t * cosf(PI_F * t * (1.0f + b))) / (PI_F * t * (1.0f - (4.0f * b * t) * (4.0f * b * t)));
}

size_t demod_ptab_bytes(const demod_t *d) { return (DEMOD_PHASES + 1u) * d->ntaps * sizeof(float); }

void demod_set_ptab(demod_t *d, float *mem) {
    memcpy(mem, d->ptab, demod_ptab_bytes(d));
    d->ptab = mem;
}

static void set_nco(demod_t *d);

void demod_reset(demod_t *d) {
    d->state = DEMOD_COARSE;
    d->nacq = 0;
    d->nco_ph = 0;
    d->nco_step = 0;
    set_nco(d);
    d->coarse_hz = d->fine_hz = 0;
    memset(d->mf_hist, 0, sizeof(d->mf_hist));
    memset(d->win, 0, sizeof(d->win));
    d->wpos = 0;
    memset(d->spec, 0, DEMOD_ACQ_FFT * sizeof(float));
    d->mf_pos = 0;
    d->n = 0;
    d->t_next = 0.0f;
    d->mid = false;
    d->tim_int = 0;
    d->ph = d->freq = 0;
    d->crot = (cpx_t){1, 0};
    d->crot_n = 0;
    d->agc = 0;
    d->mer_acc = d->mer_n = 0;
    d->mer_db = 0;
}

void demod_init(demod_t *d, float fs, float baud, float search_hz, void *work) {
    memset(d, 0, sizeof(*d));
    d->fs = fs;
    d->baud = baud;
    d->sps = fs / baud;
    d->search_hz = search_hz;
    d->acq = work;
    d->fft = (cpx_t *)work + DEMOD_FINE_N;
    d->spec = (float *)((cpx_t *)work + 2u * DEMOD_FINE_N);
    /* RRC matched filter over 8 symbols */
    uint32_t nt = (uint32_t)(8.0f * d->sps) | 1u;
    if (nt > DEMOD_MF_MAX - 1u) nt = DEMOD_MF_MAX - 1u;
    d->ntaps = nt;
    float e = 0;
    for (uint32_t i = 0; i < nt; ++i) {
        d->taps[i] = rrc(((float)i - (float)(nt - 1) / 2.0f) / d->sps, 0.35f);
        e += d->taps[i];
    }
    for (uint32_t i = 0; i < nt; ++i) d->taps[i] /= e;     /* unity gain at DC */
    /* polyphase: row q gives the output at (newest - c - q / P) from the window, oldest sample first */
    d->ptab = d->spec + DEMOD_ACQ_FFT;
    const float c = (float)(nt - 1) / 2.0f;
    for (uint32_t q = 0; q <= DEMOD_PHASES; ++q)
        for (uint32_t j = 0; j < nt; ++j) {
            const uint32_t k = nt - 1u - j;                  /* window position j holds x[n - k] */
            d->ptab[q * nt + j] = rrc(((float)k - c - (float)q / DEMOD_PHASES) / d->sps, 0.35f) / e;
        }
    demod_reset(d);
}

static void set_nco(demod_t *d) {
    d->rot = (cpx_t){1, 0};
    d->rot_step = (cpx_t){(float)cos(d->nco_step), (float)sin(d->nco_step)};
    d->rot_n = 0;
}

static inline cpx_t mix(demod_t *d, float re, float im) {
    const float c = d->rot.re, s = d->rot.im;
    const cpx_t r = {re * c - im * s, re * s + im * c};
    const float nr = c * d->rot_step.re - s * d->rot_step.im;
    d->rot.im = c * d->rot_step.im + s * d->rot_step.re;
    d->rot.re = nr;
    if (++d->rot_n == 1024u) {                              /* keep |rot| = 1 */
        d->rot_n = 0;
        const float g = 1.5f - 0.5f * (d->rot.re * d->rot.re + d->rot.im * d->rot.im);
        d->rot.re *= g;
        d->rot.im *= g;
    }
    return r;
}

static inline cpx_t mf(demod_t *d, cpx_t x) {
    const uint32_t nt = d->ntaps;
    d->mf_hist[d->mf_pos] = x;
    d->mf_hist[d->mf_pos + nt] = x;                         /* mirrored: a contiguous window always */
    d->mf_pos = d->mf_pos + 1u == nt ? 0u : d->mf_pos + 1u;
    const cpx_t *h = &d->mf_hist[d->mf_pos];
    /* symmetric taps (odd count): fold the window */
    const uint32_t half = nt / 2u;
    float re = h[half].re * d->taps[half], im = h[half].im * d->taps[half];
    for (uint32_t i = 0; i < half; ++i) {
        const float t = d->taps[i];
        re += (h[i].re + h[nt - 1u - i].re) * t;
        im += (h[i].im + h[nt - 1u - i].im) * t;
    }
    return (cpx_t){re, im};
}

/* spectrum centre: the window of the signal's width with the most power above the noise floor */
static void coarse_estimate(demod_t *d) {
    const uint32_t N = DEMOD_ACQ_FFT;
    float sorted[64];
    /* median of a decimated copy as the floor */
    for (uint32_t k = 0; k < 64; ++k) sorted[k] = d->spec[k * (N / 64)];
    for (int i = 1; i < 64; ++i) { const float t = sorted[i]; int j = i - 1; while (j >= 0 && sorted[j] > t) { sorted[j + 1] = sorted[j]; --j; } sorted[j + 1] = t; }
    const float floor_p = sorted[32];
    const float bin_hz = d->fs / (float)N;
    const int w = (int)(d->baud * 1.0f / bin_hz);           /* the flat top of the RRC spectrum */
    const int lim = (int)(d->search_hz / bin_hz);
    double best = -1;
    int best_c = 0;
    for (int c = -lim; c <= lim; ++c) {
        double s = 0;
        for (int k = c - w / 2; k <= c + w / 2; ++k) {
            const int idx = (k + (int)N) % (int)N;
            const float p = d->spec[idx] - floor_p;
            if (p > 0) s += p;
        }
        if (s > best) { best = s; best_c = c; }
    }
    /* centroid of the excess power around the best window */
    double num = 0, den = 0;
    for (int k = best_c - w; k <= best_c + w; ++k) {
        const int idx = (k + (int)N) % (int)N;
        const float p = d->spec[idx] - floor_p;
        if (p > 0) { num += p * k; den += p; }
    }
    d->coarse_hz = den > 0 ? (float)(num / den) * bin_hz : 0.0f;
    d->nco_step = -2.0 * M_PI * d->coarse_hz / d->fs;
    set_nco(d);
}

static void fine_estimate(demod_t *d) {
    const uint32_t N = DEMOD_FINE_N;
    for (uint32_t k = 0; k < N; ++k) {                      /* 4th power removes the QPSK modulation */
        const cpx_t z = d->acq[k];
        const float r2 = z.re * z.re - z.im * z.im, i2 = 2.0f * z.re * z.im;
        d->fft[k] = (cpx_t){r2 * r2 - i2 * i2, 2.0f * r2 * i2};
    }
    fft(d->fft, N);
    uint32_t pk = 0;
    float best = -1;
    for (uint32_t k = 0; k < N; ++k) {
        const float p = d->fft[k].re * d->fft[k].re + d->fft[k].im * d->fft[k].im;
        if (p > best) { best = p; pk = k; }
    }
    /* parabolic refinement */
    const uint32_t km = (pk + N - 1u) % N, kp = (pk + 1u) % N;
    const float a = sqrtf(d->fft[km].re * d->fft[km].re + d->fft[km].im * d->fft[km].im);
    const float b = sqrtf(best), c = sqrtf(d->fft[kp].re * d->fft[kp].re + d->fft[kp].im * d->fft[kp].im);
    const float den = a - 2.0f * b + c;
    const float delta = den != 0.0f ? 0.5f * (a - c) / den : 0.0f;
    float k4 = (float)pk + delta;
    if (k4 > (float)N / 2) k4 -= (float)N;
    d->fine_hz = k4 * d->fs / (float)N / 4.0f;
    d->nco_step -= 2.0 * M_PI * d->fine_hz / d->fs;
    const cpx_t keep = d->rot;                               /* continue from the current phase */
    set_nco(d);
    d->rot = keep;
}

static uint32_t on_symbol(demod_t *d, cpx_t y, dvbs_soft_t *out) {
    /* carrier: z = y e^(-j ph) */
    const float c = d->crot.re, s = d->crot.im;
    const float zr = y.re * c + y.im * s, zi = y.im * c - y.re * s;
    const float m = (fabsf(zr) + fabsf(zi)) * 0.5f;
    d->agc = d->agc <= 0 ? m : d->agc + 0.002f * (m - d->agc);
    /* no hardware divide on the ESP32-S3: one reciprocal per symbol */
    const float inv = 1.0f / (d->agc + 1e-6f);
    /* Gardner timing error with the half-symbol sample */
    const float e = ((d->prev_sym.re - y.re) * d->mid_sym.re + (d->prev_sym.im - y.im) * d->mid_sym.im) * inv * inv;
    d->prev_sym = y;
    const float kp = 0.02f, ki = 0.0002f;
    const float ec = e > 1.0f ? 1.0f : e < -1.0f ? -1.0f : e;
    d->tim_int += ki * ec;
    if (d->tim_int > 0.2f) d->tim_int = 0.2f;
    if (d->tim_int < -0.2f) d->tim_int = -0.2f;
    d->t_next += (kp * ec + d->tim_int) * d->sps;
    const float nr = zr * inv, ni = zi * inv;
    const float sr = nr >= 0 ? 1.0f : -1.0f, si = ni >= 0 ? 1.0f : -1.0f;
    float err = sr * ni - si * nr;
    err = err > 2.0f ? 2.0f : err < -2.0f ? -2.0f : err;
    const float ckp = 0.04f, cki = 0.0004f;
    d->freq += cki * err;
    if (d->freq > 0.3f) d->freq = 0.3f;
    if (d->freq < -0.3f) d->freq = -0.3f;
    const float dp = d->freq + ckp * err;                    /* small: turn the rotator by dp */
    const float dc = 1.0f - 0.5f * dp * dp, ds = dp - dp * dp * dp * (1.0f / 6.0f);
    const float r2 = c * dc - s * ds;
    d->crot.im = c * ds + s * dc;
    d->crot.re = r2;
    if (++d->crot_n == 64u) {
        d->crot_n = 0;
        const float g = 1.5f - 0.5f * (d->crot.re * d->crot.re + d->crot.im * d->crot.im);
        d->crot.re *= g;
        d->crot.im *= g;
    }
    /* MER */
    d->mer_acc += (nr - sr) * (nr - sr) + (ni - si) * (ni - si);
    if (++d->mer_n >= 2000.0f) {
        d->mer_db = 10.0f * log10f(2.0f * d->mer_n / (d->mer_acc + 1e-9f));
        d->mer_acc = d->mer_n = 0;
    }
    d->symbols++;
    float vr = nr * SOFT_SCALE, vi = ni * SOFT_SCALE;
    vr = vr > 127 ? 127 : vr < -127 ? -127 : vr;
    vi = vi > 127 ? 127 : vi < -127 ? -127 : vi;
    out->i = (int8_t)(vr >= 0 ? vr + 0.5f : vr - 0.5f);
    out->q = (int8_t)(vi >= 0 ? vi + 0.5f : vi - 0.5f);
    return 1;
}

uint32_t demod_push(demod_t *d, const int16_t *iq, uint32_t n, dvbs_soft_t *out) {
    uint32_t nout = 0;
    for (uint32_t k = 0; k < n; ++k) {
        const float re = iq[2 * k], im = iq[2 * k + 1];
        if (d->state == DEMOD_COARSE) {
            cpx_t *f = d->fft;
            f[d->nacq % DEMOD_ACQ_FFT] = (cpx_t){re, im};
            if (++d->nacq % DEMOD_ACQ_FFT == 0) {
                for (uint32_t i = 0; i < DEMOD_ACQ_FFT; ++i) {
                    const float w = 0.5f - 0.5f * cosf(2.0f * PI_F * i / DEMOD_ACQ_FFT);
                    f[i].re *= w; f[i].im *= w;
                }
                fft(f, DEMOD_ACQ_FFT);
                for (uint32_t i = 0; i < DEMOD_ACQ_FFT; ++i) d->spec[i] += f[i].re * f[i].re + f[i].im * f[i].im;
                if (d->nacq == DEMOD_ACQ_FFT * DEMOD_ACQ_AVG) {
                    coarse_estimate(d);
                    d->state = DEMOD_FINE;
                    d->nacq = 0;
                }
            }
            continue;
        }
        const uint32_t c0 = demod_clock ? demod_clock() : 0;
        const cpx_t xm = mix(d, re, im);
        if (demod_clock) demod_prof[0] += demod_clock() - c0;
        if (d->state == DEMOD_FINE) {
            const cpx_t x = mf(d, xm);
            if (d->nacq >= d->ntaps) d->acq[d->nacq - d->ntaps] = x;     /* skip the filter's start-up */
            if (++d->nacq == DEMOD_FINE_N + d->ntaps) {
                fine_estimate(d);
                d->state = DEMOD_TRACK;
                d->n = 0;
                d->t_next = 0.0f;
                d->agc = 0;
            }
            continue;
        }
        /* track: the matched filter only at the interpolation instants (polyphase) */
        const uint32_t nt = d->ntaps;
        d->win[d->wpos] = xm;
        d->win[d->wpos + nt] = xm;
        d->wpos = d->wpos + 1u == nt ? 0u : d->wpos + 1u;
        ++d->n;
        d->t_next -= 1.0f;
        while (d->t_next < 1.0f) {
            const float mu = 1.0f - (d->t_next < 0 ? 0 : d->t_next);   /* how far before the newest gap's end */
            const uint32_t i0 = demod_clock ? demod_clock() : 0;
            uint32_t q = (uint32_t)(mu * DEMOD_PHASES + 0.5f);
            if (q > DEMOD_PHASES) q = DEMOD_PHASES;
            const float *h = d->ptab + q * nt;
            const cpx_t *w = &d->win[d->wpos];
            float yr = 0, yi = 0;
            for (uint32_t j = 0; j < nt; ++j) { yr += w[j].re * h[j]; yi += w[j].im * h[j]; }
            const cpx_t y = {yr, yi};
            const uint32_t i1 = demod_clock ? demod_clock() : 0;
            d->t_next += d->sps * 0.5f;
            if (d->mid) d->mid_sym = y;
            else nout += on_symbol(d, y, &out[nout]);
            d->mid = !d->mid;
            if (demod_clock) { const uint32_t i2 = demod_clock(); demod_prof[2] += i1 - i0; demod_prof[3] += i2 - i1; }
        }
    }
    return nout;
}
