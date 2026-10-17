/* Native tests of the portable DATV core.
 *   ./test_core app/test/fixtures/dvb_goldens.json
 * 1. DVB-S encoder output is bit-identical to app/lib/core/dvb/dvbs.dart and host/dvbs.py (golden SHA-256).
 * 2. RS(204,188) corrects up to 8 byte errors.
 * 3. Loopback: encoder -> QPSK with noise, phase ambiguity, I/Q swap and a random start -> receiver.
 * 4. MP2 encoder output is bit-identical to app/lib/core/codec/audio/mp2_encoder.dart (SHA-256), and a
 *    tone survives the encoder and minimp3. Built a second time with MP2ENC_FLOAT=1 (MP2 tests only). */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "datv/demod.h"
#include "datv/dvbs_rx.h"
#include "datv/dvbs_tx.h"
#include "datv/mp2dec.h"
#include "datv/mp2enc.h"
#include "datv/rs.h"
#include "datv/ts.h"

void sha256_hex(const uint8_t *data, size_t n, char out[65]);

static int failures;
#define CHECK(c, ...) do { if (!(c)) { ++failures; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static uint32_t rng = 1;
static uint32_t xr(void) { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }
static double gauss(void) {
    const double u1 = (xr() + 1.0) / 4294967297.0, u2 = (xr() + 1.0) / 4294967297.0;
    return sqrt(-2 * log(u1)) * cos(2 * M_PI * u2);
}

/* the same generator as goldenTs() in app/test/dvb/dvb_golden_test.dart */
static uint8_t *golden_ts(int n) {
    uint32_t x = 0x2545F491u;
    uint8_t *out = malloc((size_t)n * 188), *o = out;
    for (int p = 0; p < n; ++p) {
        *o++ = 0x47;
        for (int i = 0; i < 187; ++i) {
            x ^= x << 13; x ^= x >> 17; x ^= x << 5;
            *o++ = (uint8_t)(x >> 11);
        }
    }
    return out;
}

static char *read_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    const long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *b = malloc((size_t)n + 1);
    if (fread(b, 1, (size_t)n, f) != (size_t)n) { fclose(f); free(b); return NULL; }
    b[n] = 0;
    fclose(f);
    return b;
}

static void test_goldens(const char *path) {
    char *js = read_file(path);
    CHECK(js, "cannot read %s", path);
    if (!js) return;
    const int npk = 400;
    uint8_t *ts = golden_ts(npk);
    uint8_t *out = malloc(dvbs_enc_max_out(npk));
    int checked = 0;
    for (int f = 0; f < DVBS_FEC_COUNT; ++f)
        for (int v = 0; v < 3; ++v) {
            const bool swap = v == 1, inv = v == 2;
            char key[32];
            snprintf(key, sizeof(key), "\"%s|%d|%d\": \"", dvbs_fec_name[f], swap, inv);
            const char *k = strstr(js, key);
            CHECK(k, "no golden for %s", key);
            if (!k) continue;
            char want[65];
            memcpy(want, k + strlen(key), 64);
            want[64] = 0;
            dvbs_enc_t e;
            dvbs_enc_init(&e, (dvbs_fec_t)f, swap, inv);
            size_t n = dvbs_enc(&e, ts, 7, out);              /* split like the Dart test */
            n += dvbs_enc(&e, ts + 7 * 188, npk - 7, out + n);
            char got[65];
            sha256_hex(out, n, got);
            CHECK(!strcmp(got, want), "DVB-S %s swap %d invert %d: %s != %s", dvbs_fec_name[f], swap, inv, got, want);
            ++checked;
        }
    printf("goldens: %d DVB-S modes checked\n", checked);
    free(out);
    free(ts);
    free(js);
}

static void test_rs(void) {
    int ok = 0;
    for (int trial = 0; trial < 2000; ++trial) {
        uint8_t cw[204], orig[204];
        for (int i = 0; i < 188; ++i) cw[i] = (uint8_t)xr();
        rs_parity(cw, cw + 188);
        memcpy(orig, cw, sizeof(cw));
        const int ne = trial % 9;                          /* 0..8 errors */
        int pos[8];
        for (int e = 0; e < ne; ++e) {
            int p, dup;
            do {
                p = (int)(xr() % 204);
                dup = 0;
                for (int j = 0; j < e; ++j) dup |= pos[j] == p;
            } while (dup);
            pos[e] = p;
            cw[p] ^= (uint8_t)(1 + xr() % 255);
        }
        const int c = rs_decode(cw);
        if (c == ne && !memcmp(cw, orig, sizeof(cw))) ++ok;
        else CHECK(0, "RS trial %d: %d errors, decoder said %d", trial, ne, c);
    }
    /* 9 errors must not be reported as a clean correction of the original */
    int detected = 0;
    for (int trial = 0; trial < 200; ++trial) {
        uint8_t cw[204], orig[204];
        for (int i = 0; i < 188; ++i) cw[i] = (uint8_t)xr();
        rs_parity(cw, cw + 188);
        memcpy(orig, cw, sizeof(cw));
        for (int e = 0; e < 9; ++e) cw[(e * 22 + trial) % 204] ^= (uint8_t)(1 + xr() % 255);
        if (rs_decode(cw) < 0) ++detected;
        else CHECK(memcmp(cw, orig, sizeof(cw)), "RS: 9 errors 'corrected' to the original");
    }
    printf("rs: %d/2000 corrected, 9 errors detected in %d/200\n", ok, detected);
}

typedef struct {
    const uint8_t *ts;
    int npk;
    int first;               /* index of the first received packet in ts, -1 before */
    int next, good, bad, tei;
} sink_t;

static void on_pkt(void *ctx, const uint8_t *p) {
    sink_t *s = ctx;
    if (p[1] & 0x80) { s->tei++; s->next++; return; }
    if (s->first < 0) {
        for (int k = 0; k < s->npk; ++k)
            if (!memcmp(s->ts + 188 * k, p, 188)) { s->first = k; s->next = k; break; }
        if (s->first < 0) { s->bad++; return; }
    }
    if (s->next < s->npk && !memcmp(s->ts + 188 * s->next, p, 188)) s->good++;
    else s->bad++;
    s->next++;
}

static void loopback(dvbs_fec_t fec, double esn0_db, int rot, bool conj, int fixed, int *good, int *bad, int *tei, dvbs_rx_t *rx) {
    const int npk = 160;
    uint8_t *ts = malloc(188 * npk);
    for (int k = 0; k < npk; ++k) {
        ts[188 * k] = 0x47;
        for (int i = 1; i < 188; ++i) ts[188 * k + i] = (uint8_t)xr();
        ts[188 * k + 1] &= 0x1F;                           /* no transport_error_indicator */
    }
    dvbs_enc_t e;
    dvbs_enc_init(&e, fec, false, false);
    uint8_t *sym = malloc(dvbs_enc_max_out(npk));
    const size_t nb = dvbs_enc(&e, ts, npk, sym);
    const size_t nsym = nb * 4;
    const size_t start = xr() % 2000;                     /* the receiver tunes in mid-stream */
    dvbs_soft_t *soft = malloc(sizeof(dvbs_soft_t) * nsym);
    const double sigma = sqrt(1.0 / pow(10, esn0_db / 10));          /* per component: Es = 2 (levels +-1), N0 / 2 */
    size_t n = 0;
    for (size_t m = start; m < nsym; ++m) {
        const uint32_t s = (sym[m / 4] >> (2 * (m % 4))) & 3u;
        double i = (s & 1) ? 1 : -1, q = (s & 2) ? 1 : -1;
        for (int k = 0; k < rot; ++k) { const double t = i; i = -q; q = t; }   /* multiply by j */
        if (conj) q = -q;
        i += sigma * gauss();
        q += sigma * gauss();
        double a = i * 40, b = q * 40;
        a = a > 127 ? 127 : a < -127 ? -127 : a;
        b = b > 127 ? 127 : b < -127 ? -127 : b;
        soft[n++] = (dvbs_soft_t){(int8_t)lrint(a), (int8_t)lrint(b)};
    }
    sink_t sk = {ts, npk, -1, 0, 0, 0, 0};
    dvbs_rx_init(rx, fixed, on_pkt, &sk);
    for (size_t k = 0; k < n; k += 1000) dvbs_rx_push(rx, soft + k, (uint32_t)(n - k < 1000 ? n - k : 1000));
    *good = sk.good; *bad = sk.bad; *tei = sk.tei;
    free(soft); free(sym); free(ts);
}

static void test_loopback(void) {
    static dvbs_rx_t rx;
    for (int f = 0; f < DVBS_FEC_COUNT; ++f)
        for (int rot = 0; rot < 4; ++rot)
            for (int cj = 0; cj < 2; ++cj) {
                const double esn0 = 3.0 + 2.0 * f + 3.0;       /* a few dB above the threshold of each rate */
                int g, b, t;
                loopback((dvbs_fec_t)f, esn0, rot, cj, -1, &g, &b, &t, &rx);
                const int expect = 160 - 30;                     /* acquisition, sync and the interleaver delay cost packets */
                const bool ok = g >= expect - 15 && b == 0;
                CHECK(ok, "loopback %s rot %d conj %d EsN0 %.0f dB: good %d bad %d tei %d (fec %s rot %u swap %d q %.2f)",
                      dvbs_fec_name[f], rot, cj, esn0, g, b, t, dvbs_fec_name[rx.fec], rx.rot, rx.swap, rx.quality);
                if (rot == 0 && cj == 0)
                    printf("loopback %s at %.0f dB: %d packets ok, %d bad, %d with TEI, RS corrected %u, q %.2f\n",
                           dvbs_fec_name[f], esn0, g, b, t, rx.rs_corrected, rx.quality);
            }
}

static float rrc_t(float t, float b) {
    if (fabsf(t) < 1e-6f) return 1.0f - b + 4.0f * b / (float)M_PI;
    if (fabsf(fabsf(t) - 1.0f / (4.0f * b)) < 1e-4f)
        return b / 1.41421356f * ((1.0f + 2.0f / (float)M_PI) * sinf((float)M_PI / (4.0f * b)) + (1.0f - 2.0f / (float)M_PI) * cosf((float)M_PI / (4.0f * b)));
    return (sinf((float)M_PI * t * (1.0f - b)) + 4.0f * b * t * cosf((float)M_PI * t * (1.0f + b))) / ((float)M_PI * t * (1.0f - (4.0f * b * t) * (4.0f * b * t)));
}

/* DVB-S at baud * (1 + ppm) through a channel with a carrier offset and noise, sampled at fs, into the demodulator. */
static void demod_case(double fs, double baud, double ppm, double df, double esn0, dvbs_fec_t fec, int *good, int *bad, float *mer, float *fhat) {
    const int npk = 120;
    uint8_t *ts = malloc(188 * npk);
    for (int k = 0; k < npk; ++k) { ts[188 * k] = 0x47; for (int i = 1; i < 188; ++i) ts[188 * k + i] = (uint8_t)xr(); ts[188 * k + 1] &= 0x1F; }
    dvbs_enc_t e;
    dvbs_enc_init(&e, fec, false, false);
    uint8_t *sym = malloc(dvbs_enc_max_out(npk));
    const size_t nsym = dvbs_enc(&e, ts, npk, sym) * 4;
    const double rb = baud * (1 + ppm * 1e-6), sps = fs / rb, t0 = (xr() % 1000) / 1000.0;
    const size_t ns = (size_t)((nsym - 10) * sps);
    int16_t *iq = malloc(4 * ns);
    const double sigma = sqrt(1.0 / pow(10, esn0 / 10)) * sqrt(sps);   /* per component, signal +-1 per symbol */
    double ph = 2 * M_PI * (xr() % 1000) / 1000.0;
    for (size_t n = 0; n < ns; ++n) {
        const double t = n / sps + t0;                                   /* in symbols */
        double si = 0, sq = 0;
        for (long k = (long)t - 5; k <= (long)t + 5; ++k) {
            if (k < 0 || (size_t)k >= nsym) continue;
            const uint32_t s = (sym[k / 4] >> (2 * (k % 4))) & 3u;
            const double h = rrc_t((float)(t - k), 0.35f);
            si += ((s & 1) ? 1 : -1) * h;
            sq += ((s & 2) ? 1 : -1) * h;
        }
        si += sigma * gauss(); sq += sigma * gauss();
        const double c = cos(ph), s_ = sin(ph);
        ph += 2 * M_PI * df / fs;
        iq[2 * n] = (int16_t)lrint(1500 * (si * c - sq * s_));
        iq[2 * n + 1] = (int16_t)lrint(1500 * (si * s_ + sq * c));
    }
    static demod_t d;
    static dvbs_rx_t rx;
    void *work = malloc(demod_work_bytes());
    demod_init(&d, (float)fs, (float)baud, 110e3f, work);
    sink_t sk = {ts, npk, -1, 0, 0, 0, 0};
    dvbs_rx_init(&rx, -1, on_pkt, &sk);
    dvbs_soft_t out[600];
    for (size_t k = 0; k < ns; k += 1000) {
        const uint32_t m = (uint32_t)(ns - k < 1000 ? ns - k : 1000);
        const uint32_t no = demod_push(&d, iq + 2 * k, m, out);
        dvbs_rx_push(&rx, out, no);
    }
    *good = sk.good; *bad = sk.bad; *mer = d.mer_db; *fhat = d.coarse_hz + d.fine_hz;
    free(work); free(iq); free(sym); free(ts);
}

static void test_demod(void) {
    struct { double baud, ppm, df, esn0; dvbs_fec_t fec; } cases[] = {
        {66000, 0, 61300, 12, DVBS_FEC_1_2}, {66000, 40, -58000, 12, DVBS_FEC_1_2}, {66000, -40, 3000, 8, DVBS_FEC_1_2},
        {33000, 25, 45000, 10, DVBS_FEC_1_2}, {66000, 30, 61300, 14, DVBS_FEC_3_4},
    };
    for (size_t c = 0; c < sizeof(cases) / sizeof(cases[0]); ++c) {
        int g, b;
        float mer, fh;
        demod_case(250000, cases[c].baud, cases[c].ppm, cases[c].df, cases[c].esn0, cases[c].fec, &g, &b, &mer, &fh);
        printf("demod %.0f Bd %+.0f ppm offset %+.0f Hz EsN0 %.0f dB FEC %s: %d packets ok, %d bad, MER %.1f dB, offset found %+.0f Hz\n",
               cases[c].baud, cases[c].ppm, cases[c].df, cases[c].esn0, dvbs_fec_name[cases[c].fec], g, b, mer, fh);
        CHECK(g > 60 && b == 0, "demod case %zu", c);
    }
}

typedef struct {
    uint8_t *au[64];
    uint32_t len[64];
    int n, got, bad, last;
    int64_t pts[64];
} au_check_t;

static void on_pes_check(void *ctx, int kind, const uint8_t *pl, uint32_t len, int64_t pts, bool damaged) {
    au_check_t *c = ctx;
    if (kind != 0) return;
    for (int k = 0; k < c->n; ++k)
        if (!damaged && len == c->len[k] && !memcmp(pl, c->au[k], len)) { c->got++; c->last = k; return; }
    c->bad++;
    (void)pts;
}

static void *xalloc(size_t n) { return malloc(n); }
static void ts_demux_push_adapter(void *ctx, const uint8_t *p) { ts_demux_push(ctx, p); }

/* access units -> mux (CBR at the DVB-S rate) -> DVB-S encoder -> soft symbols -> receiver -> demux */
static void test_ts(void) {
    static ts_mux_t m;
    const double rate = dvbs_ts_rate(66000, DVBS_FEC_1_2);
    ts_mux_init(&m, (uint32_t)rate, "SP8ESA", "T-Deck", false, xalloc, free);
    au_check_t c = {0};
    c.n = 40;
    for (int k = 0; k < c.n; ++k) {
        c.len[k] = 100 + xr() % (k % 20 == 0 ? 3000 : 600);
        c.au[k] = malloc(c.len[k]);
        for (uint32_t i = 0; i < c.len[k]; ++i) c.au[k][i] = (uint8_t)xr();
    }
    int queued = 0;
    static ts_demux_t dm;
    static uint8_t vbuf[65536];
    ts_demux_init(&dm, vbuf, sizeof(vbuf), NULL, 0, on_pes_check, &c);
    static dvbs_rx_t rx;
    dvbs_enc_t e;
    dvbs_enc_init(&e, DVBS_FEC_1_2, false, false);
    dvbs_rx_init(&rx, -1, (dvbs_rx_packet_fn)ts_demux_push_adapter, &dm);
    uint8_t pkt[188], sym[512];
    dvbs_soft_t soft[2048];
    int npk = 0;
    while (npk < 6000 && c.last < c.n - 1) {
        while (queued < c.n && m.es[0].qn < 8) { CHECK(ts_mux_add_video(&m, c.au[queued], c.len[queued], queued * 100000LL), "mux queue"); ++queued; }
        ts_mux_next(&m, pkt);
        ++npk;
        const size_t nb = dvbs_enc(&e, pkt, 1, sym);
        uint32_t ns = 0;
        for (size_t b = 0; b < nb; ++b)
            for (int k = 0; k < 4; ++k) {
                const uint32_t s2 = (sym[b] >> (2 * k)) & 3u;
                soft[ns++] = (dvbs_soft_t){(int8_t)((s2 & 1) ? 40 : -40), (int8_t)((s2 & 2) ? 40 : -40)};
            }
        dvbs_rx_push(&rx, soft, ns);
    }
    printf("ts: %d packets, %d of %d access units back intact, %d bad, service '%s' provider '%s', null %u psi %u\n", npk, c.got, c.n, c.bad,
           dm.service, dm.provider, m.null_packets, m.psi_packets);
    CHECK(c.got >= c.n - 6 && c.last == c.n - 1 && c.bad == 0 && !strcmp(dm.service, "SP8ESA"), "ts round trip");
    for (int k = 0; k < c.n; ++k) free(c.au[k]);
}

#define MP2ENC_IS_FLOAT (sizeof(mp2_real_t) == sizeof(float))

/* the same signal as gen() in the Dart reference script: three tones under a ramp envelope, xorshift
 * noise, and frames 5 to 7 silent */
static void mp2_signal(int fs, int ch, int frames, int16_t *out) {
    uint32_t x = 0x12345678u;
    for (int i = 0; i < frames * MP2_FRAME_SAMPLES; ++i)
        for (int c = 0; c < ch; ++c) {
            x ^= x << 13; x ^= x >> 17; x ^= x << 5;
            const double noise = ((int)(x & 0xffff) - 32768) / 16.0;
            const double env = 0.35 + 0.65 * (i % 9000) / 9000;
            double v = env * (9000 * sin(2 * M_PI * 440 * i / fs) + 6000 * sin(2 * M_PI * (1250 + 300 * c) * i / fs) +
                              2500 * sin(2 * M_PI * (fs * 0.31) * i / fs)) + noise;
            if (i >= 5 * MP2_FRAME_SAMPLES && i < 8 * MP2_FRAME_SAMPLES) v = 0;
            v = round(v);
            out[i * ch + c] = (int16_t)(v < -32768 ? -32768 : v > 32767 ? 32767 : v);
        }
}

/* encodes frames of pcm plus one frame of silence (the Dart flush()); returns the stream length */
static size_t mp2_encode_all(mp2enc_t *e, const int16_t *pcm, int frames, uint8_t *out, int *bad_len, double *us_per_frame) {
    static const int16_t zero[MP2_FRAME_SAMPLES * 2];
    size_t n = 0;
    const size_t max = mp2enc_frame_bytes_max(e);
    const clock_t t0 = clock();
    for (int f = 0; f <= frames; ++f) {
        const size_t len = mp2enc_encode(e, f < frames ? pcm + (size_t)f * MP2_FRAME_SAMPLES * e->channels : zero, out + n);
        if (len != (size_t)e->slots && len != max) ++*bad_len;
        if (out[n] != 0xff || (out[n + 1] & 0xe0) != 0xe0) ++*bad_len;
        n += len;
    }
    *us_per_frame = (double)(clock() - t0) * 1e6 / CLOCKS_PER_SEC / (frames + 1);
    return n;
}

/* decodes a stream frame by frame; returns interleaved samples written */
static size_t mp2_decode_all(const uint8_t *in, size_t n, int16_t *pcm, int want_ch, int want_rate, int *bad) {
    static mp2dec_t d;
    mp2dec_init(&d);
    size_t pos = 0, out = 0;
    while (pos + 4 <= n) {
        /* frame length from the header, so each call sees exactly one frame */
        static const int br[2][15] = {{0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160},
                                      {0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384}};
        const int lsf = !(in[pos + 1] & 0x08);
        const size_t len = (size_t)(144000 * br[!lsf][in[pos + 2] >> 4] / want_rate + ((in[pos + 2] >> 1) & 1));
        int ch = 0, rate = 0;
        const int ns = mp2dec_decode(&d, in + pos, len, pcm + out, &ch, &rate);
        if (ns != MP2_FRAME_SAMPLES || ch != want_ch || rate != want_rate) ++*bad;
        out += (size_t)ns * (size_t)ch;
        pos += len;
    }
    return out;
}

/* lag of b behind a (channel 0) by cross-correlation */
static int best_lag(const int16_t *a, const int16_t *b, int ch, int n, int max_lag) {
    int lag = 0;
    double best = -1e300;
    for (int l = 0; l <= max_lag; ++l) {
        double s = 0;
        for (int i = 0; i < n; ++i) s += (double)a[i * ch] * b[(i + l) * ch];
        if (s > best) { best = s; lag = l; }
    }
    return lag;
}

/* SNR of b delayed by lag against a (channel 0), over [skip, n - tail) */
static double snr_db(const int16_t *a, const int16_t *b, int ch, int n, int lag, int skip, int tail) {
    double s = 0, e = 0;
    for (int i = skip; i < n - tail; ++i) {
        const double x = a[i * ch], y = b[(i + lag) * ch];
        s += x * x;
        e += (x - y) * (x - y);
    }
    return 10 * log10(s / (e + 1e-9));
}

static void test_mp2(void) {
    CHECK(!mp2enc_valid(48000, 2, 48) && !mp2enc_valid(48000, 1, 256) && !mp2enc_valid(16000, 1, 192) &&
              !mp2enc_valid(8000, 1, 8) && !mp2enc_valid(16000, 3, 16) && mp2enc_valid(16000, 1, 16) &&
              mp2enc_valid(48000, 2, 192) && mp2enc_valid(44100, 1, 192),
          "mp2 bitrate validation");
    static mp2enc_t e;
    CHECK(!mp2enc_init(&e, 48000, 2, 48), "mp2 init rejects 48k stereo 48 kbit/s");
    CHECK(mp2enc_init(&e, 48000, 2, 96) && e.slots == 288 && mp2enc_frame_bytes_max(&e) == 288, "mp2 48k/96 frame size");
    CHECK(mp2enc_init(&e, 16000, 1, 8) && e.slots == 72, "mp2 16k/8 frame size");
    CHECK(mp2enc_init(&e, 24000, 1, 32) && e.slots == 192, "mp2 24k/32 frame size");

    static int16_t pcm[48 * MP2_FRAME_SAMPLES * 2], dec[50 * MP2_FRAME_SAMPLES * 2];
    static uint8_t bits[50 * MP2_FRAME_BYTES_MAX];
    /* 44.1 kHz padding: the average frame length matches the bitrate, frames are 417 or 418 bytes */
    memset(pcm, 0, sizeof(pcm));
    mp2enc_init(&e, 44100, 2, 128);
    int bad = 0;
    double us;
    size_t n = mp2_encode_all(&e, pcm, 48, bits, &bad, &us);
    CHECK(bad == 0 && fabs(n - 49.0 * 1152 * 128000 / 8 / 44100) < 1.0 && mp2enc_frame_bytes_max(&e) == 418, "mp2 44.1k padding: %zu bytes", n);

    /* bit-exactness against the Dart encoder; the PCM hash checks the signal generator itself */
    static const struct { int rate, ch, kbps; const char *pcm, *mp2; } ref[] = {
        {16000, 1, 16, "9b89e6b1809e949574ce01819469bec8292918f572ef03d46ace958fb0502d2b",
         "6e84b9d0c0d774d69c2f4d3fdf38909cc0cca1e11b5bb192df10795f272e8497"},
        {24000, 1, 32, "584373de893fc4c7324815ced06a30e44cc752e3d290fbd447f3d2081ba58d98",
         "412a94b80a537917db24e7a08c7c35196bc2d30ecaf9c1c1864dadf898011126"},
        {48000, 2, 192, "52e84f9acae205ebd1f3718bf90c038fc06866407ebedb11ab5fdf5e6300a044",
         "ba9854cff1a4c732140dbc1e04e9bb7e3b57200cadd3e0f3ab3348c2b428eab2"},
    };
    for (size_t r = 0; r < sizeof(ref) / sizeof(ref[0]); ++r) {
        const int frames = 24;
        mp2_signal(ref[r].rate, ref[r].ch, frames, pcm);
        char hp[65], hm[65];
        sha256_hex((const uint8_t *)pcm, (size_t)frames * MP2_FRAME_SAMPLES * ref[r].ch * 2, hp);
        CHECK(mp2enc_init(&e, ref[r].rate, ref[r].ch, ref[r].kbps), "mp2 init");
        bad = 0;
        n = mp2_encode_all(&e, pcm, frames, bits, &bad, &us);
        sha256_hex(bits, n, hm);
        int dbad = 0;
        const size_t nd = mp2_decode_all(bits, n, dec, ref[r].ch, ref[r].rate, &dbad);
        const double snr = snr_db(pcm, dec, ref[r].ch, (frames - 1) * MP2_FRAME_SAMPLES, MP2_CODEC_DELAY, 2000, 0);
        const int lag = best_lag(pcm, dec, ref[r].ch, 10000, 1500);
#if defined(MP2ENC_FLOAT) && MP2ENC_FLOAT
        const bool exact = true; /* single precision: not bit-identical to the Dart, checked by SNR only */
#else
        const bool exact = !strcmp(hm, ref[r].mp2);
#endif
        printf("mp2 %d Hz %d ch %d kbit/s: %zu bytes, %s, lag %d, decoded SNR %.1f dB, %.0f us/frame native\n", ref[r].rate,
               ref[r].ch, ref[r].kbps, n, MP2ENC_IS_FLOAT ? "float build" : exact ? "bit-identical to Dart" : "DIFFERS from Dart", lag, snr, us);
        CHECK(!strcmp(hp, ref[r].pcm), "mp2 test signal differs from the Dart generator");
        CHECK(exact, "mp2 %d/%d/%d sha %s", ref[r].rate, ref[r].ch, ref[r].kbps, hm);
        CHECK(bad == 0 && n == (size_t)(frames + 1) * e.slots, "mp2 frame sizes");
        CHECK(lag == MP2_CODEC_DELAY, "mp2 codec delay %d", lag);
        CHECK(dbad == 0 && nd == (size_t)(frames + 1) * MP2_FRAME_SAMPLES * ref[r].ch && snr > 10, "mp2 decode %d/%d/%d", ref[r].rate,
              ref[r].ch, ref[r].kbps);
    }

    /* round trip: 1 kHz tone at 16 kHz mono 16 kbit/s through mp2dec */
    const int frames = 28, fs = 16000;
    for (int i = 0; i < frames * MP2_FRAME_SAMPLES; ++i) pcm[i] = (int16_t)lround(16000 * sin(2 * M_PI * 1000 * i / fs));
    mp2enc_init(&e, fs, 1, 16);
    bad = 0;
    n = mp2_encode_all(&e, pcm, frames, bits, &bad, &us);
    int dbad = 0;
    const size_t nd = mp2_decode_all(bits, n, dec, 1, fs, &dbad);
    const int len = (frames - 1) * MP2_FRAME_SAMPLES;
    const double snr = snr_db(pcm, dec, 1, len, MP2_CODEC_DELAY, 2000, 0);
    /* frequency from upward zero crossings (linear interpolation) of the decoded signal */
    double first = -1, last = -1;
    int crossings = 0;
    for (int i = 2000 + MP2_CODEC_DELAY; i < len + MP2_CODEC_DELAY; ++i)
        if (dec[i - 1] < 0 && dec[i] >= 0) {
            const double t = i - 1 + (double)-dec[i - 1] / (dec[i] - dec[i - 1]);
            if (first < 0) first = t; else ++crossings;
            last = t;
        }
    const double freq = crossings * fs / (last - first);
    const double kbps = n * 8.0 * fs / ((frames + 1) * MP2_FRAME_SAMPLES) / 1000;
    printf("mp2 round trip 1 kHz tone, 16 kHz mono 16 kbit/s: %zu bytes (%.2f kbit/s), decoded %.2f Hz, SNR %.1f dB, %.0f us/frame native\n",
           n, kbps, freq, snr, us);
    CHECK(bad == 0 && n == (size_t)(frames + 1) * 144 && fabs(kbps - 16) < 1e-9, "mp2 round trip frame sizes");
    CHECK(dbad == 0 && nd == (size_t)(frames + 1) * MP2_FRAME_SAMPLES, "mp2 round trip decode");
    CHECK(fabs(freq - 1000) < 0.5, "mp2 decoded frequency %.3f", freq);
    CHECK(snr > 20, "mp2 round trip SNR %.1f dB", snr);
}

int main(int argc, char **argv) {
#if defined(MP2ENC_FLOAT) && MP2ENC_FLOAT
    test_mp2();
    printf(failures ? "%d FAILURES\n" : "all passed\n", failures);
    return failures != 0;
#endif
    test_goldens(argc > 1 ? argv[1] : "../../app/test/fixtures/dvb_goldens.json");
    test_rs();
    test_loopback();
    test_demod();
    test_ts();
    test_mp2();
    printf(failures ? "%d FAILURES\n" : "all passed\n", failures);
    return failures != 0;
}
