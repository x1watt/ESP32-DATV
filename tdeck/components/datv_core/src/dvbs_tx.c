#include "datv/dvbs_tx.h"
#include <string.h>
#include "datv/rs.h"

void dvbs_enc_init(dvbs_enc_t *e, dvbs_fec_t fec, bool swap_iq, bool invert) {
    memset(e, 0, sizeof(*e));
    e->p = &dvbs_punct[fec];
    e->swap_iq = swap_iq;
    e->invert = invert;
    e->pend_bit = -1;
}

static inline void put_bit(dvbs_enc_t *e, uint32_t b, uint8_t *out, size_t *ob) {
    if (e->pend_bit < 0) { e->pend_bit = (int)b; return; }
    uint32_t li = 1u - (uint32_t)e->pend_bit, lq = 1u - b;
    e->pend_bit = -1;
    if (e->invert) lq ^= 1u;
    if (e->swap_iq) { const uint32_t t = li; li = lq; lq = t; }
    e->pend_sym |= (li | (lq << 1)) << (2u * e->pend_n);
    if (++e->pend_n == 4u) {
        out[(*ob)++] = (uint8_t)e->pend_sym;
        e->pend_sym = 0;
        e->pend_n = 0;
    }
}

size_t dvbs_enc(dvbs_enc_t *e, const uint8_t *ts, size_t npkt, uint8_t *out) {
    const uint8_t *prbs = dvbs_prbs();
    const dvbs_punct_t *p = e->p;
    size_t ob = 0;
    uint8_t cw[DVBS_CW];
    for (size_t n = 0; n < npkt; ++n, ts += DVBS_PKT) {
        const uint32_t k = e->pkt++ & 7u;
        cw[0] = k == 0 ? 0xB8 : 0x47;
        for (int j = 1; j < DVBS_PKT; ++j) cw[j] = ts[j] ^ prbs[188u * k + (uint32_t)j - 1u];
        rs_parity(cw, cw + DVBS_PKT);
        for (int j = 0; j < DVBS_CW; ++j) {
            /* Forney interleaver: out(t) = in(t - 204 * (t mod 12)) */
            const uint32_t t = e->t++;
            e->ring[t & 4095u] = cw[j];
            const uint32_t back = DVBS_CW * (t % DVBS_IL_I);
            const uint8_t byte = back <= t ? e->ring[(t - back) & 4095u] : 0;
            for (int bi = 7; bi >= 0; --bi) {
                const uint32_t b = (byte >> bi) & 1u, st = e->cstate;
                const uint32_t x = b ^ (st & 1u) ^ ((st >> 1) & 1u) ^ ((st >> 2) & 1u) ^ ((st >> 5) & 1u);
                const uint32_t y = b ^ ((st >> 1) & 1u) ^ ((st >> 2) & 1u) ^ ((st >> 4) & 1u) ^ ((st >> 5) & 1u);
                e->cstate = ((st << 1) | b) & 0x3Fu;
                if (p->x[e->cpos]) put_bit(e, x, out, &ob);
                if (p->y[e->cpos]) put_bit(e, y, out, &ob);
                if (++e->cpos == p->len) e->cpos = 0;
            }
        }
    }
    return ob;
}
