#include "datv/rs.h"
#include <string.h>

static uint8_t gexp[512];
static uint8_t glog[256];
static uint8_t gen[17];          /* highest power first */
static uint8_t multab[256][16];  /* feedback byte times gen[1..16] */
static int ready;

static uint8_t mul(uint8_t a, uint8_t b) { return a && b ? gexp[glog[a] + glog[b]] : 0; }

static void init(void) {
    unsigned x = 1;
    for (int i = 0; i < 255; ++i) {
        gexp[i] = (uint8_t)x;
        glog[x] = (uint8_t)i;
        x <<= 1;
        if (x & 0x100u) x ^= 0x11Du;
    }
    for (int i = 255; i < 512; ++i) gexp[i] = gexp[i - 255];
    uint8_t g[17] = {1};
    int len = 1;
    for (int i = 0; i < 16; ++i) {
        uint8_t ng[17] = {0};
        for (int k = 0; k < len; ++k) {
            ng[k] ^= g[k];
            ng[k + 1] ^= mul(g[k], gexp[i]);
        }
        ++len;
        memcpy(g, ng, sizeof(g));
    }
    memcpy(gen, g, sizeof(gen));
    for (int fb = 0; fb < 256; ++fb)
        for (int j = 0; j < 16; ++j) multab[fb][j] = mul((uint8_t)fb, gen[j + 1]);
    ready = 1;
}

void rs_parity(const uint8_t *d, uint8_t *par) {
    if (!ready) init();
    uint8_t r[16] = {0};
    for (int i = 0; i < 188; ++i) {
        const uint8_t *m = multab[d[i] ^ r[0]];
        for (int j = 0; j < 15; ++j) r[j] = r[j + 1] ^ m[j];
        r[15] = m[15];
    }
    memcpy(par, r, 16);
}

/* Codeword c(x) = cw[0] x^203 + ... + cw[203] (the shortened code: 51 leading zeros dropped). */
int rs_decode(uint8_t *cw) {
    if (!ready) init();
    uint8_t s[16];
    int nz = 0;
    for (int j = 0; j < 16; ++j) {          /* S_j = c(a^j) by Horner */
        uint8_t v = 0;
        const unsigned lj = (unsigned)j;
        for (int i = 0; i < 204; ++i) v = (uint8_t)((v ? gexp[glog[v] + lj] : 0) ^ cw[i]);
        s[j] = v;
        nz |= v;
    }
    if (!nz) return 0;
    /* Berlekamp-Massey: error locator L(x) */
    uint8_t L[17] = {1}, B[17] = {1}, T[17];
    int l = 0, m = 1;
    uint8_t b = 1;
    for (int n = 0; n < 16; ++n) {
        uint8_t d = s[n];
        for (int i = 1; i <= l; ++i) d ^= mul(L[i], s[n - i]);
        if (!d) { ++m; continue; }
        const uint8_t coef = gexp[glog[d] + 255 - glog[b]];
        memcpy(T, L, sizeof(T));
        for (int i = 0; i + m <= 16; ++i) L[i + m] ^= mul(coef, B[i]);
        if (2 * l <= n) {
            l = n + 1 - l;
            memcpy(B, T, sizeof(B));
            b = d;
            m = 1;
        } else ++m;
    }
    if (l > 8) return -1;
    /* Chien search over the 204 used positions: position i (from the start) has degree 203 - i,
       locator root X^-1 with X = a^(203 - i) */
    int pos[8], nfound = 0;
    for (int i = 0; i < 204; ++i) {
        const unsigned e = 203u - (unsigned)i;
        const unsigned xinv = (255u - e) % 255u;
        uint8_t v = L[0];
        for (int k = 1; k <= l; ++k) if (L[k]) v ^= gexp[(glog[L[k]] + xinv * (unsigned)k) % 255u];
        if (!v) {
            if (nfound == 8) return -1;
            pos[nfound++] = i;
        }
    }
    if (nfound != l) return -1;
    /* Forney: Omega(x) = S(x) L(x) mod x^16, e = X^(1 - fcr) Omega(X^-1) / L'(X^-1), fcr = 0 */
    uint8_t om[16] = {0};
    for (int i = 0; i < 16; ++i)
        for (int k = 0; k <= l && k <= i; ++k) om[i] ^= mul(L[k], s[i - k]);
    for (int f = 0; f < nfound; ++f) {
        const unsigned e = 203u - (unsigned)pos[f];
        const unsigned xinv = (255u - e) % 255u;
        uint8_t num = 0, den = 0;
        for (int i = 0; i < 16; ++i) if (om[i]) num ^= gexp[(glog[om[i]] + xinv * (unsigned)i) % 255u];
        for (int k = 1; k <= l; k += 2) if (L[k]) den ^= gexp[(glog[L[k]] + xinv * (unsigned)(k - 1)) % 255u];
        if (!den) return -1;
        /* X^(1 - fcr) = X */
        uint8_t mag = num ? gexp[(glog[num] + 255u - glog[den] + e) % 255u] : 0;
        cw[pos[f]] ^= mag;
    }
    return nfound;
}
