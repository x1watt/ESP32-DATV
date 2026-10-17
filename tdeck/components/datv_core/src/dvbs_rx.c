#include "datv/dvbs_rx.h"
#include <string.h>
#include "datv/rs.h"

/* Coded bits of a puncturing pattern in the order they are sent: X then Y of each input bit. */
typedef struct {
    uint8_t n;
    uint8_t cpos[16], is_y[16];
} pat_seq_t;

static void pat_seq(dvbs_fec_t f, pat_seq_t *q) {
    const dvbs_punct_t *p = &dvbs_punct[f];
    q->n = 0;
    for (uint8_t c = 0; c < p->len; ++c) {
        if (p->x[c]) { q->cpos[q->n] = c; q->is_y[q->n++] = 0; }
        if (p->y[c]) { q->cpos[q->n] = c; q->is_y[q->n++] = 1; }
    }
}

static inline void map_sym(const dvbs_soft_t *s, uint32_t rot, bool swap, int *a, int *b) {
    int i = s->i, q = s->q;
    if (swap) { const int t = i; i = q; q = t; }
    if (rot) { const int t = i; i = q; q = -t; }   /* undo a quarter turn */
    *a = i;
    *b = q;
}

static void on_bits(dvbs_rx_t *r, const uint8_t *bits, uint32_t n);

#define HYP(f, k, rot, sw) ((uint32_t)(f) << 8 | (uint32_t)(k) << 2 | (uint32_t)(rot) << 1 | (uint32_t)(sw))

static bool banned(const dvbs_rx_t *r, uint32_t h) {
    for (uint32_t k = 0; k < r->nbanned; ++k) if (r->banned[k] == h) return true;
    return false;
}

/* One coded soft value into the depuncturer; decoded bits go to on_bits when out is NULL. */
static inline void feed(dvbs_rx_t *r, vit_t *v, const pat_seq_t *q, const dvbs_punct_t *p, uint32_t *k, int *sx, int val, bool decode) {
    uint8_t bits[VIT_OUT];
    const uint32_t e = *k;
    *k = e + 1u == q->n ? 0u : e + 1u;
    uint32_t got = 0;
    if (!q->is_y[e]) {
        if (p->y[q->cpos[e]]) { *sx = val; return; }
        got = vit_step(v, val, 0, bits);
    } else {
        got = vit_step(v, p->x[q->cpos[e]] ? *sx : 0, val, bits);
        *sx = 0;
    }
    if (decode && got) on_bits(r, bits, got);
}

void dvbs_rx_init(dvbs_rx_t *r, int fec_fixed, dvbs_rx_packet_fn fn, void *ctx) {
    memset(r, 0, sizeof(*r));
    r->fec_fixed = fec_fixed;
    r->on_packet = fn;
    r->ctx = ctx;
    r->group = 8;
}

static void lose_byte_sync(dvbs_rx_t *r) {
    r->byte_sync = false;
    r->bits_unsynced = 0;
    r->bitpos = 0;
    memset(r->cnt, 0, sizeof(r->cnt));
    memset(r->n47, 0, sizeof(r->n47));
    r->group = 8;
    r->resyncs++;
}

void dvbs_rx_reset(dvbs_rx_t *r) {
    r->locked = false;
    r->nacq = 0;
    lose_byte_sync(r);
}

static void deliver_cw(dvbs_rx_t *r) {
    uint8_t *cw = r->cw;
    const int c = rs_decode(cw);
    bool bad = c < 0;
    if (bad) r->rs_failed++;
    else r->rs_corrected += (uint32_t)c;
    if (cw[0] == 0xB8) r->group = 0;
    else if (r->group < 8) r->group = (r->group + 1u) & 7u;
    if (r->group >= 8) return;                       /* no group start seen yet */
    const uint8_t *prbs = dvbs_prbs();
    uint8_t pkt[DVBS_PKT];
    pkt[0] = 0x47;
    for (int j = 1; j < DVBS_PKT; ++j) pkt[j] = cw[j] ^ prbs[188u * r->group + (uint32_t)j - 1u];
    if (bad) pkt[1] |= 0x80;
    r->packets++;
    if (r->on_packet) r->on_packet(r->ctx, pkt);
}

static void on_byte(dvbs_rx_t *r, uint8_t byte) {
    if (r->inverted) byte = (uint8_t)~byte;
    const uint32_t t = r->t++;
    if (t % DVBS_CW == 0) {
        if (byte == 0x47 || byte == 0xB8) r->sync_miss = 0;
        else if (++r->sync_miss >= 6) { lose_byte_sync(r); return; }
    }
    r->ring[t & 4095u] = byte;
    /* in(u) = r(u + 204 * (u mod 12)) */
    while (r->u + DVBS_CW * (r->u % DVBS_IL_I) < r->t) {
        const uint32_t u = r->u++;
        r->cw[u % DVBS_CW] = r->ring[(u + DVBS_CW * (u % DVBS_IL_I)) & 4095u];
        if (u % DVBS_CW == DVBS_CW - 1u) deliver_cw(r);
    }
}

static void on_bits(dvbs_rx_t *r, const uint8_t *bits, uint32_t n) {
    for (uint32_t k = 0; k < n; ++k) {
        r->sreg = ((r->sreg << 1) | bits[k]) & 0xFFu;
        if (r->byte_sync) {
            if (++r->nbits == 8u) { r->nbits = 0; on_byte(r, (uint8_t)r->sreg); }
            continue;
        }
        /* look for sync-like bytes repeating every 204 bytes at the same bit phase */
        const uint32_t ph = r->bitpos;
        r->bitpos = ph + 1u == DVBS_CW * 8u ? 0u : ph + 1u;
        const uint8_t b = (uint8_t)r->sreg;
        if (b == 0x47 || b == 0xB8) {
            if (b == 0x47) r->n47[ph]++;
            if (++r->cnt[ph] >= 4) {
                r->inverted = r->n47[ph] * 2u < r->cnt[ph];   /* mostly 0xB8: inverted stream */
                r->byte_sync = true;
                r->nbanned = 0;
                r->nbits = 0;
                r->t = r->u = 0;
                r->sync_miss = 0;
                r->group = 8;
                on_byte(r, b);
                continue;
            }
        } else {
            r->cnt[ph] = 0;
            r->n47[ph] = 0;
        }
        if (++r->bits_unsynced > 12u * DVBS_CW * 8u) {   /* wrong hypothesis after all (some puncturing phases look like valid code) */
            if (r->nbanned < 16) r->banned[r->nbanned++] = HYP(r->fec, r->cpos_bit, r->rot, r->swap);
            dvbs_rx_reset(r);
            return;
        }
    }
}

static void acquire(dvbs_rx_t *r) {
    double best = -1, second = -1;
    dvbs_fec_t bf = DVBS_FEC_1_2;
    uint32_t brot = 0, bk = 0;
    bool bswap = false;
    static vit_t v;
    for (int f = 0; f < DVBS_FEC_COUNT; ++f) {
        if (r->fec_fixed >= 0 && f != r->fec_fixed) continue;
        pat_seq_t q;
        pat_seq((dvbs_fec_t)f, &q);
        const dvbs_punct_t *p = &dvbs_punct[f];
        for (uint32_t k0 = 0; k0 < q.n; ++k0) {
            if (!(q.n & 1u) && (k0 & 1u)) continue;    /* symbols start on even coded bits */
            for (uint32_t rot = 0; rot < 2; ++rot)
                for (int sw = 0; sw < 2; ++sw) {
                    if (banned(r, HYP(f, k0, rot, sw))) continue;
                    vit_init(&v);
                    uint32_t k = k0;
                    int sx = 0;
                    for (uint32_t m = 0; m < r->nacq; ++m) {
                        int a, b;
                        map_sym(&r->acq[m], rot, sw, &a, &b);
                        feed(r, &v, &q, p, &k, &sx, a, false);
                        feed(r, &v, &q, p, &k, &sx, b, false);
                    }
                    const double qv = vit_quality(&v);
                    if (qv > best) {
                        if (f != (int)bf || best < 0) second = best;
                        best = qv; bf = (dvbs_fec_t)f; brot = rot; bswap = sw; bk = k0;
                    } else if (qv > second && f != (int)bf) second = qv;
                }
        }
    }
    r->quality = best;
    (void)second;
    if (best < 0.55) {                                /* no DVB-S here (noise, or a wrong rate) */
        r->nacq = 0;
        r->nbanned = 0;
        return;
    }
    r->fec = bf; r->rot = brot; r->swap = bswap; r->cpos_bit = bk;
    r->locked = true;
    vit_init(&r->vit);
    r->pat_k = bk;
    r->sx = 0;
    lose_byte_sync(r);
    r->resyncs--;
    /* decode the acquisition block too */
    pat_seq_t q;
    pat_seq(bf, &q);
    for (uint32_t m = 0; m < r->nacq && r->locked; ++m) {
        int a, b;
        map_sym(&r->acq[m], brot, bswap, &a, &b);
        feed(r, &r->vit, &q, &dvbs_punct[bf], &r->pat_k, &r->sx, a, true);
        feed(r, &r->vit, &q, &dvbs_punct[bf], &r->pat_k, &r->sx, b, true);
    }
    r->nacq = 0;
}

void dvbs_rx_push(dvbs_rx_t *r, const dvbs_soft_t *s, uint32_t n) {
    pat_seq_t q;
    int qf = -1;
    for (uint32_t m = 0; m < n; ++m) {
        if (!r->locked) {
            r->acq[r->nacq++] = s[m];
            if (r->nacq == DVBS_RX_ACQ) acquire(r);
            continue;
        }
        if (qf != (int)r->fec) { pat_seq(r->fec, &q); qf = (int)r->fec; }
        int a, b;
        map_sym(&s[m], r->rot, r->swap, &a, &b);
        feed(r, &r->vit, &q, &dvbs_punct[r->fec], &r->pat_k, &r->sx, a, true);
        if (!r->locked) continue;
        feed(r, &r->vit, &q, &dvbs_punct[r->fec], &r->pat_k, &r->sx, b, true);
    }
}
