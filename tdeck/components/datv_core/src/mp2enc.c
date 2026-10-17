/* MPEG audio Layer II encoder (ISO/IEC 11172-3 and the 13818-3 LSF extension), port of
 * app/lib/core/codec/audio/mp2_encoder.dart. Bit allocation is driven by a simplified psychoacoustic
 * model (FFT, Bark spreading, tonality dependent masking offset, absolute threshold), similar to ISO
 * model 1. The numeric tables are the normative ones from 11172-3 / 13818-3.
 *
 * Bit-exactness with the Dart: every double expression keeps the Dart's operand order, and init uses the
 * same libm functions (cos, sin, atan, pow, exp, log). Do not build with -ffast-math or FMA contraction.
 *
 * Cost per frame and channel (dominant terms, independent of the bitrate):
 *   analysis filterbank 36 * (64 * 8 + 16 * 32) = 37k multiply-adds
 *   1024 point FFT      5120 butterflies = 20k multiplies + 31k adds
 *   spreading           npart^2 (64 at 16 kHz, 75 at 48 kHz) = 4k to 6k multiply-adds
 *   about 250 log/pow, plus the greedy allocator (a few hundred passes over sblimit subbands)
 * so roughly 150k floating point operations. With MP2ENC_FLOAT on the ESP32-S3 FPU that is about 0.5M
 * cycles (2 ms at 240 MHz, under 3% of the 72 ms frame at 16 kHz mono). With software doubles (50 to 100
 * cycles per operation) it is 8M to 15M cycles, 35 to 60 ms, most of one core: use MP2ENC_FLOAT there. */
#include "datv/mp2enc.h"
#include <math.h>
#include <string.h>

#if defined(MP2ENC_FLOAT) && MP2ENC_FLOAT
#define RLOG logf
#define RPOW powf
#define RFLOOR floorf
#define RFABS fabsf
#else
#define RLOG log
#define RPOW pow
#define RFLOOR floor
#define RFABS fabs
#endif
#define R(x) ((mp2_real_t)(x))

static const int bitrates_mpeg1[15] = {0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384};
static const int bitrates_lsf[15] = {0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160};

static const int sblimit_table[5] = {27, 30, 8, 12, 30};
static const int quant_steps[17] = {3, 5, 7, 9, 15, 31, 63, 127, 255, 511, 1023, 2047, 4095, 8191, 16383, 32767, 65535};
/* bits per sample; negative means three samples grouped in that many bits */
static const int quant_bits[17] = {-5, -7, 3, -10, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};
/* SNR in dB for each quantizer class (11172-3 table C.5) */
static const mp2_real_t quant_snr[17] = {R(7.00),  R(11.00), R(16.00), R(20.84), R(25.28), R(31.59),
                                         R(37.75), R(43.84), R(49.89), R(55.93), R(61.96), R(67.98),
                                         R(74.01), R(80.03), R(86.05), R(92.01), R(98.01)};
static const int nb_scf[4] = {3, 2, 1, 2}; /* transmitted scale factors per scfsi code */

/* Allocation tables in compact form: per subband the number of allocation bits nb followed by
 * 2^nb - 1 quantizer class indexes (one per nonzero allocation value). */
static const uint8_t alloc1[] = {
    4, 0, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
    4, 0, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
    4, 0, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
    4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16,
    4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16,
    4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16,
    4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16,
    4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16,
    4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16,
    4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16,
    4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16,
    3, 0, 1, 2, 3, 4, 5, 16,
    3, 0, 1, 2, 3, 4, 5, 16,
    3, 0, 1, 2, 3, 4, 5, 16,
    3, 0, 1, 2, 3, 4, 5, 16,
    3, 0, 1, 2, 3, 4, 5, 16,
    3, 0, 1, 2, 3, 4, 5, 16,
    3, 0, 1, 2, 3, 4, 5, 16,
    3, 0, 1, 2, 3, 4, 5, 16,
    3, 0, 1, 2, 3, 4, 5, 16,
    3, 0, 1, 2, 3, 4, 5, 16,
    3, 0, 1, 2, 3, 4, 5, 16,
    3, 0, 1, 2, 3, 4, 5, 16,
    2, 0, 1, 16,
    2, 0, 1, 16,
    2, 0, 1, 16,
    2, 0, 1, 16,
    2, 0, 1, 16,
    2, 0, 1, 16,
    2, 0, 1, 16,
};
static const uint8_t alloc3[] = {
    4, 0, 1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    4, 0, 1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    3, 0, 1, 3, 4, 5, 6, 7,
    3, 0, 1, 3, 4, 5, 6, 7,
    3, 0, 1, 3, 4, 5, 6, 7,
    3, 0, 1, 3, 4, 5, 6, 7,
    3, 0, 1, 3, 4, 5, 6, 7,
    3, 0, 1, 3, 4, 5, 6, 7,
    3, 0, 1, 3, 4, 5, 6, 7,
    3, 0, 1, 3, 4, 5, 6, 7,
    3, 0, 1, 3, 4, 5, 6, 7,
    3, 0, 1, 3, 4, 5, 6, 7,
};
static const uint8_t alloc4[] = {
    4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
    4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
    4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
    4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
    3, 0, 1, 3, 4, 5, 6, 7,
    3, 0, 1, 3, 4, 5, 6, 7,
    3, 0, 1, 3, 4, 5, 6, 7,
    3, 0, 1, 3, 4, 5, 6, 7,
    3, 0, 1, 3, 4, 5, 6, 7,
    3, 0, 1, 3, 4, 5, 6, 7,
    3, 0, 1, 3, 4, 5, 6, 7,
    2, 0, 1, 3,
    2, 0, 1, 3,
    2, 0, 1, 3,
    2, 0, 1, 3,
    2, 0, 1, 3,
    2, 0, 1, 3,
    2, 0, 1, 3,
    2, 0, 1, 3,
    2, 0, 1, 3,
    2, 0, 1, 3,
    2, 0, 1, 3,
    2, 0, 1, 3,
    2, 0, 1, 3,
    2, 0, 1, 3,
    2, 0, 1, 3,
    2, 0, 1, 3,
    2, 0, 1, 3,
    2, 0, 1, 3,
    2, 0, 1, 3,
};
static const uint8_t *const alloc_tables[5] = {alloc1, alloc1, alloc3, alloc3, alloc4};

/* first half (257 values) of the window D[i] = 32 * C[i], scaled by 2^16 */
static const int32_t half_window[257] = {
    0, -1, -1, -1, -1, -1, -1, -2,
    -2, -2, -2, -3, -3, -4, -4, -5,
    -5, -6, -7, -7, -8, -9, -10, -11,
    -13, -14, -16, -17, -19, -21, -24, -26,
    -29, -31, -35, -38, -41, -45, -49, -53,
    -58, -63, -68, -73, -79, -85, -91, -97,
    -104, -111, -117, -125, -132, -139, -147, -154,
    -161, -169, -176, -183, -190, -196, -202, -208,
    213, 218, 222, 225, 227, 228, 228, 227,
    224, 221, 215, 208, 200, 189, 177, 163,
    146, 127, 106, 83, 57, 29, -2, -36,
    -72, -111, -153, -197, -244, -294, -347, -401,
    -459, -519, -581, -645, -711, -779, -848, -919,
    -991, -1064, -1137, -1210, -1283, -1356, -1428, -1498,
    -1567, -1634, -1698, -1759, -1817, -1870, -1919, -1962,
    -2001, -2032, -2057, -2075, -2085, -2087, -2080, -2063,
    2037, 2000, 1952, 1893, 1822, 1739, 1644, 1535,
    1414, 1280, 1131, 970, 794, 605, 402, 185,
    -45, -288, -545, -814, -1095, -1388, -1692, -2006,
    -2330, -2663, -3004, -3351, -3705, -4063, -4425, -4788,
    -5153, -5517, -5879, -6237, -6589, -6935, -7271, -7597,
    -7910, -8209, -8491, -8755, -8998, -9219, -9416, -9585,
    -9727, -9838, -9916, -9959, -9966, -9935, -9863, -9750,
    -9592, -9389, -9139, -8840, -8492, -8092, -7640, -7134,
    6574, 5959, 5288, 4561, 3776, 2935, 2037, 1082,
    70, -998, -2122, -3300, -4533, -5818, -7154, -8540,
    -9975, -11455, -12980, -14548, -16155, -17799, -19478, -21189,
    -22929, -24694, -26482, -28289, -30112, -31947, -33791, -35640,
    -37489, -39336, -41176, -43006, -44821, -46617, -48390, -50137,
    -51853, -53534, -55178, -56778, -58333, -59838, -61289, -62684,
    -64019, -65290, -66494, -67629, -68692, -69679, -70590, -71420,
    -72169, -72835, -73415, -73908, -74313, -74630, -74856, -74992,
    75038,
};

/* Tables shared by all instances, built once (idempotent, so a racing second init is harmless). */
static mp2_real_t scale_tab[64], scale_inv[64]; /* 2^(1 - i/3) and its inverse */
static mp2_real_t dct[32 * 32];                 /* cos((2k+1) i pi / 64) */
static mp2_real_t window[512];                  /* analysis window C[i] */
static bool tables_ready;

static void build_tables(void) {
    if (tables_ready) return;
    for (int i = 0; i < 64; ++i) {
        const double s = pow(2.0, 1.0 - i / 3.0);
        scale_tab[i] = R(s);
        scale_inv[i] = R(1.0 / s);
    }
    for (int k = 0; k < 32; ++k)
        for (int i = 0; i < 32; ++i) dct[k * 32 + i] = R(cos((2 * k + 1) * i * M_PI / 64));
    for (int i = 0; i < 257; ++i) {
        double v = half_window[i] / (65536.0 * 32.0);
        window[i] = R(v);
        if (i & 63) v = -v;
        if (i != 0) window[512 - i] = R(v);
    }
    tables_ready = true;
}

/* ---------------------------------------------------------------- psychoacoustic model */

static bool psy_init(mp2_psy_t *p, int fs) {
    const int n = MP2_FFT_N;
    for (int i = 0; i < n; ++i) p->hann[i] = R(0.5 - 0.5 * cos(2 * M_PI * (i + 0.5) / n));
    for (int i = 0; i < n / 2; ++i) {
        p->cosv[i] = R(cos(2 * M_PI * i / n));
        p->sinv[i] = R(-sin(2 * M_PI * i / n));
    }
    for (int i = 0, j = 0; i < n; ++i) {
        p->rev[i] = (int16_t)j;
        int bit = n >> 1;
        while (j & bit) { j ^= bit; bit >>= 1; }
        j |= bit;
    }
    /* full scale sine peak at about 96 dB: |X|^2 for amplitude 1 with Hann is (N/4)^2 */
    const double norm = 20 * log(n / 4) / M_LN10;
    mp2_real_t *line_bark = p->thr; /* scratch until the first frame */
    int max_part = 0;
    for (int k = 0; k < MP2_LINES; ++k) {
        const double f = (double)(k * fs) / n;
        const double z = 13 * atan(0.00076 * f) + 3.5 * atan(pow(f / 7500, 2));
        line_bark[k] = R(z);
        const int pi = (int)floor(z * 3);
        if (pi >= MP2_MAX_PART) return false;
        p->part[k] = (uint8_t)pi;
        if (pi > max_part) max_part = pi;
        /* absolute threshold of hearing (Terhardt), clamped so extreme highs do not dominate */
        const double fk = (f > 20.0 ? f : 20.0) / 1000.0;
        double ath = 3.64 * pow(fk, -0.8) - 6.5 * exp(-0.6 * pow(fk - 3.3, 2)) + 1e-3 * pow(fk, 4);
        if (ath > 90) ath = 90;
        p->ath[k] = R(pow(10, (ath - 96 + norm) / 10));
    }
    const int np = p->npart = max_part + 1;
    for (int k = 0; k < MP2_LINES; ++k) {
        p->pcnt[p->part[k]]++;
        p->pbark[p->part[k]] += line_bark[k];
    }
    for (int i = 0; i < np; ++i)
        if (p->pcnt[i] > 0) p->pbark[i] /= p->pcnt[i];
    /* spreading matrix (Schroeder), linear power */
    for (int i = 0; i < np; ++i)
        for (int j = 0; j < np; ++j) {
            const double x = (double)p->pbark[i] - p->pbark[j] + 0.474; /* maskee - masker */
            double db = 15.81 + 7.5 * x - 17.5 * sqrt(1 + x * x);
            if (db < -100) db = -100;
            p->spread[i * np + j] = R(pow(10, db / 10));
        }
    for (int i = 0; i < np; ++i) {
        mp2_real_t s = R(0.0);
        for (int j = 0; j < np; ++j)
            if (p->pcnt[j] > 0) s += p->spread[i * np + j];
        p->spr_norm[i] = 1 / s;
    }
    return true;
}

static void fft(mp2_psy_t *p) {
    const int n = MP2_FFT_N;
    mp2_real_t *re = p->re, *im = p->im;
    for (int size = 2; size <= n; size <<= 1) {
        const int half = size >> 1, step = n / size;
        for (int i = 0; i < n; i += size)
            for (int j = 0; j < half; ++j) {
                const mp2_real_t wr = p->cosv[j * step], wi = p->sinv[j * step];
                const int a = i + j, b = a + half;
                const mp2_real_t tr = re[b] * wr - im[b] * wi;
                const mp2_real_t ti = re[b] * wi + im[b] * wr;
                re[b] = re[a] - tr;
                im[b] = im[a] - ti;
                re[a] += tr;
                im[a] += ti;
            }
    }
}

/* per subband signal-to-mask ratios in dB */
static void psy_compute(mp2_psy_t *p, const mp2_real_t *h, const uint8_t *scf, int sblimit, mp2_real_t *smr) {
    const int n = MP2_FFT_N, np = p->npart;
    /* the subband frame is the input delayed by about 256 samples: center the FFT on that */
    const int start = 480 + 576 - 256 - n / 2;
    for (int i = 0; i < n; ++i) {
        p->re[p->rev[i]] = h[start + i] * p->hann[i];
        p->im[p->rev[i]] = R(0.0);
    }
    fft(p);
    for (int k = 0; k < MP2_LINES; ++k) p->power[k] = p->re[k] * p->re[k] + p->im[k] * p->im[k] + R(1e-20);
    /* partition energies and tonality */
    for (int i = 0; i < np; ++i) p->pe[i] = p->pmax[i] = R(0.0);
    for (int k = 1; k < MP2_LINES; ++k) {
        const int q = p->part[k];
        const mp2_real_t e = p->power[k];
        p->pe[q] += e;
        if (e > p->pmax[q]) p->pmax[q] = e;
    }
    for (int i = 0; i < np; ++i) {
        /* peakiness over neighbouring partitions: tonal if one line dominates the local mean */
        mp2_real_t e = R(0.0), mx = R(0.0);
        int c = 0;
        for (int q = i > 0 ? i - 1 : 0; q <= (i + 1 < np ? i + 1 : np - 1); ++q) {
            e += p->pe[q];
            c += p->pcnt[q];
            if (p->pmax[q] > mx) mx = p->pmax[q];
        }
        mp2_real_t tonal;
        if (c < 4 || e <= 0) {
            tonal = R(0.5);
        } else {
            const mp2_real_t r = 10 * RLOG(mx / (e / c)) / R(M_LN10);
            tonal = (r - 3) / 12;
            if (tonal < 0) tonal = R(0.0);
            if (tonal > 1) tonal = R(1.0);
        }
        const mp2_real_t off_db = tonal * (R(14.5) + p->pbark[i]) + (1 - tonal) * R(5.5);
        p->poff[i] = RPOW(10, -off_db / 10);
    }
    for (int i = 0; i < np; ++i) {
        mp2_real_t s = R(0.0);
        const mp2_real_t *row = p->spread + i * np;
        for (int j = 0; j < np; ++j) {
            const mp2_real_t e = p->pe[j];
            if (e > 0) s += e * p->poff[j] * row[j];
        }
        /* normalized by the spreading sum so a flat spectrum is masked at its level minus the offset,
         * then per line */
        p->pthr[i] = p->pcnt[i] > 0 ? s * p->spr_norm[i] / p->pcnt[i] : R(0.0);
    }
    for (int k = 0; k < MP2_LINES; ++k) {
        const mp2_real_t t = p->pthr[p->part[k]];
        p->thr[k] = t > p->ath[k] ? t : p->ath[k];
    }
    const int lines_per_sb = n / 64;
    for (int sb = 0; sb < 32; ++sb) {
        if (sb >= sblimit) { smr[sb] = R(-1000); continue; }
        mp2_real_t max_p = R(0.0), min_t = R(1e30);
        const int k0 = sb * lines_per_sb, k1 = k0 + lines_per_sb;
        for (int k = k0; k < k1 && k < MP2_LINES; ++k) {
            if (p->power[k] > max_p) max_p = p->power[k];
            if (p->thr[k] < min_t) min_t = p->thr[k];
        }
        /* level from the scale factor (largest of the three), as in model 1 */
        int idx = scf[sb * 3];
        if (scf[sb * 3 + 1] < idx) idx = scf[sb * 3 + 1];
        if (scf[sb * 3 + 2] < idx) idx = scf[sb * 3 + 2];
        const mp2_real_t scf_db = 20 * RLOG(scale_tab[idx] * n / 4) / R(M_LN10) - 10;
        const mp2_real_t fft_db = 10 * RLOG(max_p) / R(M_LN10);
        const mp2_real_t lsb = fft_db > scf_db ? fft_db : scf_db;
        smr[sb] = lsb - 10 * RLOG(min_t) / R(M_LN10);
        p->lsb[sb] = lsb;
    }
    /* energy weighting: bias bits toward the strongest subbands (pure NMR allocation spreads bits over
     * weak high bands, which at low bitrates costs more low band precision than it gains) */
    mp2_real_t lmax = R(-1e9);
    for (int sb = 0; sb < sblimit; ++sb)
        if (p->lsb[sb] > lmax) lmax = p->lsb[sb];
    for (int sb = 0; sb < sblimit; ++sb) smr[sb] += R(0.5) * (p->lsb[sb] - lmax);
}

/* ---------------------------------------------------------------- encoder */

bool mp2enc_valid(int sample_rate, int channels, int bitrate_kbps) {
    if (channels != 1 && channels != 2) return false;
    const bool lsf = sample_rate == 16000 || sample_rate == 22050 || sample_rate == 24000;
    if (!lsf && sample_rate != 32000 && sample_rate != 44100 && sample_rate != 48000) return false;
    const int *t = lsf ? bitrates_lsf : bitrates_mpeg1;
    int i = 1;
    while (i < 15 && t[i] != bitrate_kbps) ++i;
    if (i == 15) return false;
    if (lsf) return true;
    if (channels == 1) return bitrate_kbps <= 192;
    return bitrate_kbps != 32 && bitrate_kbps != 48 && bitrate_kbps != 56 && bitrate_kbps != 80;
}

bool mp2enc_init(mp2enc_t *e, int sample_rate, int channels, int bitrate_kbps) {
    if (!mp2enc_valid(sample_rate, channels, bitrate_kbps)) return false;
    memset(e, 0, sizeof(*e));
    build_tables();
    e->sample_rate = sample_rate;
    e->channels = channels;
    e->bitrate_kbps = bitrate_kbps;
    switch (sample_rate) {
    case 44100: e->freq_index = 0; break;
    case 48000: e->freq_index = 1; break;
    case 32000: e->freq_index = 2; break;
    case 22050: e->lsf = true; e->freq_index = 0; break;
    case 24000: e->lsf = true; e->freq_index = 1; break;
    default: e->lsf = true; e->freq_index = 2; break; /* 16000 */
    }
    const int *rates = e->lsf ? bitrates_lsf : bitrates_mpeg1;
    while (rates[e->bitrate_index] != bitrate_kbps) e->bitrate_index++;
    /* frame size 144 * bitrate / fs, the fractional part handled by the padding slot */
    const int num = 144000 * bitrate_kbps;
    e->slots = num / sample_rate;
    e->pad_incr = num % sample_rate;

    int table;
    if (e->lsf) {
        table = 4;
    } else {
        const int ch_rate = bitrate_kbps / channels;
        if ((sample_rate == 48000 && ch_rate >= 56) || (ch_rate >= 56 && ch_rate <= 80)) table = 0;
        else if (sample_rate != 48000 && ch_rate >= 96) table = 1;
        else if (sample_rate != 32000 && ch_rate <= 48) table = 2;
        else table = 3;
    }
    e->sblimit = sblimit_table[table];
    const uint8_t *alloc = alloc_tables[table];
    for (int sb = 0, j = 0; sb < e->sblimit; ++sb) {
        const int nb = alloc[j];
        e->nbal[sb] = (uint8_t)nb;
        for (int b = 1; b < (1 << nb); ++b) e->alloc_q[sb][b] = alloc[j + b];
        j += 1 << nb;
    }
    /* soft bandwidth target: with few bits per channel it is better to code fewer subbands with more
     * precision than many with 3-level quantizers; subbands above it get their SMR lowered */
    int side = 32;
    for (int sb = 0; sb < e->sblimit; ++sb) side += e->nbal[sb] * channels;
    const double per_ch = (double)(e->slots * 8 - side) / channels;
    double bw = floor(per_ch / 90.0);
    if (bw < 4) bw = 4;
    if (bw > e->sblimit) bw = e->sblimit;
    e->bw_target = (int)bw;
    return psy_init(&e->psy, sample_rate);
}

size_t mp2enc_frame_bytes_max(const mp2enc_t *e) { return (size_t)e->slots + (e->pad_incr ? 1 : 0); }

/* polyphase analysis filterbank: 36 blocks of 32 subband samples */
static void analysis(const mp2_real_t *h, mp2_real_t *out) {
    mp2_real_t y[64], t[32];
    for (int blk = 0; blk < 36; ++blk) {
        /* X[n] = h[newest - n]; newest - 511 >= 0 for every block */
        const int newest = 480 + blk * 32 + 31;
        for (int i = 0; i < 64; ++i) {
            const mp2_real_t *x = h + newest - i;
            const mp2_real_t *w = window + i;
            y[i] = x[0] * w[0] + x[-64] * w[64] + x[-128] * w[128] + x[-192] * w[192] + x[-256] * w[256] +
                   x[-320] * w[320] + x[-384] * w[384] + x[-448] * w[448];
        }
        t[0] = y[16];
        for (int i = 1; i <= 16; ++i) t[i] = y[i + 16] + y[16 - i];
        for (int i = 17; i < 32; ++i) t[i] = y[i + 16] - y[80 - i];
        /* the cosine row for 31-k is the row for k with odd terms negated: even and odd halves */
        mp2_real_t *o = out + blk * 32;
        for (int k = 0; k < 16; ++k) {
            mp2_real_t ev = R(0.0), od = R(0.0);
            const mp2_real_t *row = dct + k * 32;
            for (int i = 0; i < 32; i += 2) {
                ev += row[i] * t[i];
                od += row[i + 1] * t[i + 1];
            }
            o[k] = ev + od;
            o[31 - k] = ev - od;
        }
    }
}

static int diff_class(int d) {
    if (d <= -3) return 0;
    if (d < 0) return 1;
    if (d == 0) return 2;
    if (d < 3) return 3;
    return 4;
}

static void scale_factors(const mp2_real_t *sbs, int sblimit, uint8_t *scf, uint8_t *scfsi) {
    for (int sb = 0; sb < sblimit; ++sb) {
        for (int part = 0; part < 3; ++part) {
            mp2_real_t vmax = R(0.0);
            for (int k = 0; k < 12; ++k) {
                const mp2_real_t v = RFABS(sbs[(part * 12 + k) * 32 + sb]);
                if (v > vmax) vmax = v;
            }
            int idx;
            if (vmax < R(1e-9)) {
                idx = 62;
            } else {
                const mp2_real_t f = RFLOOR(3 * (1 - RLOG(vmax) / R(M_LN2)));
                idx = f < 0 ? 0 : f > 62 ? 62 : (int)f;
                while (idx > 0 && scale_tab[idx] < vmax) --idx;
                while (idx < 62 && scale_tab[idx + 1] >= vmax) ++idx;
            }
            scf[sb * 3 + part] = (uint8_t)idx;
        }
        /* transmission pattern selection (11172-3 table C.4) */
        int a = scf[sb * 3], b = scf[sb * 3 + 1], c = scf[sb * 3 + 2], code;
        switch (diff_class(a - b) * 5 + diff_class(b - c)) {
        case 1: case 2: case 21: case 22: code = 3; c = b; break;
        case 3: case 23: code = 3; b = c; break;
        case 5: case 9: case 14: code = 1; b = a; break;
        case 6: case 7: case 10: case 11: case 12: code = 2; b = a; c = a; break;
        case 13: case 18: code = 2; a = c; b = c; break;
        case 15: case 16: case 17: code = 2; a = b; c = b; break;
        case 8: code = 2; if (a > c) a = c; b = a; c = a; break;
        default: code = 0; break; /* 0, 4, 19, 20, 24 */
        }
        scf[sb * 3] = (uint8_t)a;
        scf[sb * 3 + 1] = (uint8_t)b;
        scf[sb * 3 + 2] = (uint8_t)c;
        scfsi[sb] = (uint8_t)code;
    }
}

static int group_bits(int qi) {
    const int b = quant_bits[qi];
    return 12 * (b < 0 ? -b : 3 * b);
}

/* greedy allocation: give one more step to the subband with the worst mask-to-noise ratio until full */
static void allocate(mp2enc_t *e, int max_bits) {
    const int nch = e->channels, sbl = e->sblimit;
    int used = 32; /* header */
    for (int sb = 0; sb < sbl; ++sb) used += e->nbal[sb] * nch;
    bool done[64];
    for (int ch = 0; ch < nch; ++ch)
        for (int sb = 0; sb < 32; ++sb) {
            e->alloc[ch][sb] = 0;
            /* bands with no signal at all are never coded */
            const uint8_t *s = e->scf[ch] + sb * 3;
            done[ch * 32 + sb] = !(sb < sbl && (s[0] < 62 || s[1] < 62 || s[2] < 62));
        }
    for (;;) {
        int best = -1;
        mp2_real_t best_val = R(-1e30);
        for (int ch = 0; ch < nch; ++ch)
            for (int sb = 0; sb < sbl; ++sb) {
                if (done[ch * 32 + sb]) continue;
                const int b = e->alloc[ch][sb];
                const mp2_real_t nmr = e->smr[ch][sb] - (b == 0 ? R(0.0) : quant_snr[e->alloc_q[sb][b]]);
                if (nmr > best_val) { best_val = nmr; best = ch * 32 + sb; }
            }
        if (best < 0) break;
        const int ch = best >> 5, sb = best & 31, b = e->alloc[ch][sb];
        const int incr = b == 0 ? 2 + nb_scf[e->scfsi[ch][sb]] * 6 + group_bits(e->alloc_q[sb][1])
                                : group_bits(e->alloc_q[sb][b + 1]) - group_bits(e->alloc_q[sb][b]);
        if (used + incr <= max_bits) {
            used += incr;
            e->alloc[ch][sb] = (uint8_t)(b + 1);
            if (b + 1 == (1 << e->nbal[sb]) - 1) done[best] = true;
        } else {
            done[best] = true;
        }
    }
}

typedef struct {
    uint8_t *p;
    uint32_t acc; /* pending bits, at most 7 + 16 */
    int n;
} bitw_t;

static void put(bitw_t *w, uint32_t v, int nbits) {
    w->acc = (w->acc << nbits) | (v & ((1u << nbits) - 1));
    w->n += nbits;
    while (w->n >= 8) {
        w->n -= 8;
        *w->p++ = (uint8_t)(w->acc >> w->n);
    }
    w->acc &= (1u << w->n) - 1;
}

size_t mp2enc_encode(mp2enc_t *e, const int16_t *pcm, uint8_t *out) {
    const int nch = e->channels, sbl = e->sblimit;
    for (int ch = 0; ch < nch; ++ch) {
        mp2_real_t *h = e->hist[ch];
        memmove(h, h + MP2_FRAME_SAMPLES, 480 * sizeof(*h));
        for (int i = 0; i < MP2_FRAME_SAMPLES; ++i) h[480 + i] = pcm[i * nch + ch] * R(1.0 / 32768.0);
        analysis(h, e->sb[ch]);
        scale_factors(e->sb[ch], sbl, e->scf[ch], e->scfsi[ch]);
        psy_compute(&e->psy, h, e->scf[ch], sbl, e->smr[ch]);
        for (int sb = e->bw_target; sb < sbl; ++sb) e->smr[ch][sb] -= R(6.0) * (sb - e->bw_target + 1);
    }
    int padding = 0;
    e->pad_acc += e->pad_incr;
    if (e->pad_acc >= e->sample_rate) { e->pad_acc -= e->sample_rate; padding = 1; }
    const int len = e->slots + padding;
    allocate(e, len * 8);

    memset(out, 0, (size_t)len); /* bits after the audio data are zero (ancillary) */
    bitw_t w = {out, 0, 0};
    put(&w, 0xfff, 12);
    put(&w, e->lsf ? 0 : 1, 1);
    put(&w, 2, 2); /* layer II */
    put(&w, 1, 1); /* no CRC */
    put(&w, (uint32_t)e->bitrate_index, 4);
    put(&w, (uint32_t)e->freq_index, 2);
    put(&w, (uint32_t)padding, 1);
    put(&w, 0, 1);                /* private */
    put(&w, nch == 2 ? 0 : 3, 2); /* stereo or single channel */
    put(&w, 0, 2);                /* mode extension */
    put(&w, 0, 1);                /* copyright */
    put(&w, 1, 1);                /* original */
    put(&w, 0, 2);                /* emphasis */
    for (int sb = 0; sb < sbl; ++sb)
        for (int ch = 0; ch < nch; ++ch) put(&w, e->alloc[ch][sb], e->nbal[sb]);
    for (int sb = 0; sb < sbl; ++sb)
        for (int ch = 0; ch < nch; ++ch)
            if (e->alloc[ch][sb]) put(&w, e->scfsi[ch][sb], 2);
    for (int sb = 0; sb < sbl; ++sb)
        for (int ch = 0; ch < nch; ++ch) {
            if (!e->alloc[ch][sb]) continue;
            const uint8_t *s = e->scf[ch] + sb * 3;
            switch (e->scfsi[ch][sb]) {
            case 0: put(&w, s[0], 6); put(&w, s[1], 6); put(&w, s[2], 6); break;
            case 1: case 3: put(&w, s[0], 6); put(&w, s[2], 6); break;
            default: put(&w, s[0], 6); break;
            }
        }
    /* samples: 3 parts x 4 granules x 3 samples */
    for (int part = 0; part < 3; ++part)
        for (int gr = 0; gr < 4; ++gr) {
            const int t0 = part * 12 + gr * 3;
            for (int sb = 0; sb < sbl; ++sb)
                for (int ch = 0; ch < nch; ++ch) {
                    const int b = e->alloc[ch][sb];
                    if (!b) continue;
                    const int qi = e->alloc_q[sb][b], steps = quant_steps[qi];
                    const mp2_real_t inv = scale_inv[e->scf[ch][sb * 3 + part]];
                    uint32_t q[3];
                    for (int m = 0; m < 3; ++m) {
                        const mp2_real_t x = e->sb[ch][(t0 + m) * 32 + sb] * inv;
                        const mp2_real_t v = RFLOOR((x + 1) * steps * R(0.5));
                        q[m] = v < 0 ? 0 : v >= steps ? (uint32_t)(steps - 1) : (uint32_t)v;
                    }
                    const int bits = quant_bits[qi];
                    if (bits < 0) {
                        put(&w, q[0] + (uint32_t)steps * (q[1] + (uint32_t)steps * q[2]), -bits);
                    } else {
                        put(&w, q[0], bits);
                        put(&w, q[1], bits);
                        put(&w, q[2], bits);
                    }
                }
        }
    if (w.n > 0) *w.p++ = (uint8_t)(w.acc << (8 - w.n));
    e->frames++;
    return (size_t)len;
}
