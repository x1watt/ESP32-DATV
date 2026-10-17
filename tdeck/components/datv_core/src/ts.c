#include "datv/ts.h"
#include <stdio.h>
#include <string.h>

uint32_t crc32_mpeg(const uint8_t *d, size_t n) {
    static uint32_t tab[256];
    static bool ready;
    if (!ready) {
        for (uint32_t i = 0; i < 256; ++i) {
            uint32_t c = i << 24;
            for (int k = 0; k < 8; ++k) c = (c & 0x80000000u) ? (c << 1) ^ 0x04C11DB7u : c << 1;
            tab[i] = c;
        }
        ready = true;
    }
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; ++i) c = (c << 8) ^ tab[((c >> 24) ^ d[i]) & 0xFFu];
    return c;
}

/* ---------------------------------------------------------------- multiplexer */

static const uint8_t null_pkt_hdr[4] = {0x47, 0x1F, 0xFF, 0x10};

void ts_mux_init(ts_mux_t *m, uint32_t mux_rate, const char *service, const char *provider, bool audio,
                 void *(*alloc)(size_t), void (*free_fn)(void *)) {
    memset(m, 0, sizeof(*m));
    m->mux_rate = mux_rate;
    snprintf(m->service, sizeof(m->service), "%s", service);
    snprintf(m->provider, sizeof(m->provider), "%s", provider);
    m->pat_period_ms = 200;
    m->pcr_period_ms = 100;
    m->delay_ms = 700;
    m->service_id = 1;
    m->pmt_pid = 0x1000;
    m->es[0] = (ts_es_t){.pid = 0x100, .type = TS_ES_H264, .stream_id = 0xE0};
    m->nes = 1;
    if (audio) { m->es[1] = (ts_es_t){.pid = 0x101, .type = TS_ES_MP2, .stream_id = 0xC0}; m->nes = 2; }
    m->alloc = alloc;
    m->free_fn = free_fn;
}

static void put_ts(uint8_t *b, int marker, int64_t t) {
    b[0] = (uint8_t)((marker << 4) | (((t >> 30) & 7) << 1) | 1);
    b[1] = (uint8_t)(t >> 22);
    b[2] = (uint8_t)((((t >> 15) & 0x7F) << 1) | 1);
    b[3] = (uint8_t)(t >> 7);
    b[4] = (uint8_t)(((t & 0x7F) << 1) | 1);
}

static bool add_pes(ts_mux_t *m, ts_es_t *es, const uint8_t *payload, uint32_t len, int64_t pts_us, bool video) {
    if (es->qn == TS_MUX_QUEUE) { m->dropped++; return false; }
    const int64_t pts = pts_us * 9 / 100;
    if (!m->have_offset) {
        m->offset90k = m->clock27 / 300 + (int64_t)m->delay_ms * 90 - pts;
        m->have_offset = true;
    }
    const int64_t t = (pts + m->offset90k) & 0x1FFFFFFFFLL;
    const uint32_t total = 9 + 5 + len;
    uint8_t *o = m->alloc(total);
    if (!o) { m->dropped++; return false; }
    o[0] = 0; o[1] = 0; o[2] = 1; o[3] = es->stream_id;
    const uint32_t plen = 3 + 5 + len;
    const uint32_t pl = (video && plen > 0xFFFF) ? 0 : plen;
    o[4] = (uint8_t)(pl >> 8); o[5] = (uint8_t)pl;
    o[6] = 0x80 | (video ? 0x04 : 0x00);
    o[7] = 0x80;
    o[8] = 5;
    put_ts(o + 9, 2, t);
    memcpy(o + 14, payload, len);
    ts_pes_t *p = &es->q[(es->qh + es->qn) % TS_MUX_QUEUE];
    *p = (ts_pes_t){.data = o, .len = total, .off = 0, .dts90k = pts + m->offset90k};
    es->qn++;
    es->queued_bytes += total;
    return true;
}

bool ts_mux_add_video(ts_mux_t *m, const uint8_t *au, uint32_t len, int64_t pts_us) { return add_pes(m, &m->es[0], au, len, pts_us, true); }
bool ts_mux_add_audio(ts_mux_t *m, const uint8_t *frame, uint32_t len, int64_t pts_us) {
    return m->nes > 1 && add_pes(m, &m->es[1], frame, len, pts_us, false);
}

double ts_mux_buffered(const ts_mux_t *m) {
    bool any = false;
    int64_t last = 0;
    for (int k = 0; k < m->nes; ++k) {
        const ts_es_t *es = &m->es[k];
        if (!es->qn) continue;
        const int64_t d = es->q[(es->qh + es->qn - 1) % TS_MUX_QUEUE].dts90k;
        if (!any || d > last) last = d;
        any = true;
    }
    return any ? (double)(last - m->clock27 / 300) / 90000.0 : 0.0;
}

double ts_mux_ahead(const ts_mux_t *m, int64_t pts_us) {
    if (!m->have_offset) return 0.0;
    return (double)(pts_us * 9 / 100 + m->offset90k - m->clock27 / 300) / 90000.0;
}

static uint32_t section(uint8_t *s, uint8_t table_id, uint16_t ext, const uint8_t *body, uint32_t blen) {
    const uint32_t len = 5 + blen + 4;
    s[0] = table_id;
    s[1] = (uint8_t)(0xB0 | ((len >> 8) & 0x0F));
    s[2] = (uint8_t)len;
    s[3] = (uint8_t)(ext >> 8);
    s[4] = (uint8_t)ext;
    s[5] = 0xC1;
    s[6] = 0;
    s[7] = 0;
    memcpy(s + 8, body, blen);
    const uint32_t crc = crc32_mpeg(s, 8 + blen);
    s[8 + blen] = (uint8_t)(crc >> 24); s[9 + blen] = (uint8_t)(crc >> 16);
    s[10 + blen] = (uint8_t)(crc >> 8); s[11 + blen] = (uint8_t)crc;
    return 12 + blen;
}

static void psi_packet(uint8_t *p, uint16_t pid, const uint8_t *sec, uint32_t slen, uint8_t cc) {
    memset(p, 0xFF, TS_PKT);
    p[0] = 0x47;
    p[1] = (uint8_t)(0x40 | ((pid >> 8) & 0x1F));
    p[2] = (uint8_t)pid;
    p[3] = (uint8_t)(0x10 | (cc & 0x0F));
    p[4] = 0;
    memcpy(p + 5, sec, slen);
}

static void queue_psi(ts_mux_t *m) {
    uint8_t body[160], sec[184];
    uint32_t n = 0;
    body[n++] = (uint8_t)(m->service_id >> 8); body[n++] = (uint8_t)m->service_id;
    body[n++] = (uint8_t)(0xE0 | (m->pmt_pid >> 8)); body[n++] = (uint8_t)m->pmt_pid;
    psi_packet(m->psi[0], 0x0000, sec, section(sec, 0x00, 1, body, n), m->pat_cc++);
    n = 0;
    body[n++] = (uint8_t)(0xE0 | (m->es[0].pid >> 8)); body[n++] = (uint8_t)m->es[0].pid;   /* PCR PID */
    body[n++] = 0xF0; body[n++] = 0x00;
    for (int k = 0; k < m->nes; ++k) {
        body[n++] = m->es[k].type;
        body[n++] = (uint8_t)(0xE0 | (m->es[k].pid >> 8)); body[n++] = (uint8_t)m->es[k].pid;
        body[n++] = 0xF0; body[n++] = 0x00;
    }
    psi_packet(m->psi[1], m->pmt_pid, sec, section(sec, 0x02, m->service_id, body, n), m->pmt_cc++);
    const uint32_t pl = (uint32_t)strlen(m->provider), sl = (uint32_t)strlen(m->service);
    n = 0;
    body[n++] = 0x00; body[n++] = 0x01;                   /* original network id */
    body[n++] = 0xFF;
    body[n++] = (uint8_t)(m->service_id >> 8); body[n++] = (uint8_t)m->service_id;
    body[n++] = 0xFC;                                     /* EIT flags off */
    const uint32_t dl = 2 + 3 + pl + sl;
    body[n++] = (uint8_t)(0x80 | ((dl >> 8) & 0x0F)); body[n++] = (uint8_t)dl;   /* running, not scrambled */
    body[n++] = 0x48; body[n++] = (uint8_t)(3 + pl + sl); body[n++] = 0x01;
    body[n++] = (uint8_t)pl; memcpy(body + n, m->provider, pl); n += pl;
    body[n++] = (uint8_t)sl; memcpy(body + n, m->service, sl); n += sl;
    psi_packet(m->psi[2], 0x0011, sec, section(sec, 0x42, 1, body, n), m->sdt_cc++);
    m->npsi = 3;
    m->psi_pos = 0;
}

static void put_pcr(uint8_t *p, int64_t pcr27) {
    const int64_t base = (pcr27 / 300) & 0x1FFFFFFFFLL;
    const int ext = (int)(pcr27 % 300);
    p[0] = (uint8_t)(base >> 25); p[1] = (uint8_t)(base >> 17); p[2] = (uint8_t)(base >> 9); p[3] = (uint8_t)(base >> 1);
    p[4] = (uint8_t)(((base & 1) << 7) | 0x7E | ((ext >> 8) & 1));
    p[5] = (uint8_t)ext;
}

static void pcr_only(ts_mux_t *m, uint8_t *p, int64_t pcr27) {
    memset(p, 0xFF, TS_PKT);
    p[0] = 0x47;
    p[1] = (uint8_t)((m->es[0].pid >> 8) & 0x1F);
    p[2] = (uint8_t)m->es[0].pid;
    p[3] = (uint8_t)(0x20 | (m->es[0].cc & 0x0F));       /* adaptation only: CC does not advance */
    p[4] = 183;
    p[5] = 0x10;
    put_pcr(p + 6, pcr27);
}

static void data_packet(ts_mux_t *m, ts_es_t *es, uint8_t *p, int64_t pcr27) {
    ts_pes_t *pes = &es->q[es->qh];
    const bool first = pes->off == 0, with_pcr = pcr27 >= 0;
    p[0] = 0x47;
    p[1] = (uint8_t)((first ? 0x40 : 0) | ((es->pid >> 8) & 0x1F));
    p[2] = (uint8_t)es->pid;
    int af_len = with_pcr ? 7 : 0;
    const uint32_t remaining = pes->len - pes->off;
    uint32_t room = 184 - (with_pcr ? 1 + (uint32_t)af_len : 0);
    if (remaining < room) {
        const uint32_t need = room - remaining;
        if (with_pcr) af_len += (int)need;
        else af_len = (int)need - 1;
        room = remaining;
    }
    const bool has_af = with_pcr || remaining < 184;
    p[3] = (uint8_t)((has_af ? 0x30 : 0x10) | (es->cc & 0x0F));
    es->cc = (es->cc + 1) & 0x0F;
    int o = 4;
    if (has_af) {
        p[o++] = (uint8_t)af_len;
        if (af_len > 0) {
            p[o++] = with_pcr ? 0x10 : 0x00;
            if (with_pcr) { put_pcr(p + o, pcr27); o += 6; }
            const int stuff_end = 5 + af_len;
            while (o < stuff_end) p[o++] = 0xFF;
        }
    }
    const uint32_t n = TS_PKT - (uint32_t)o;
    memcpy(p + o, pes->data + pes->off, n);
    pes->off += n;
    es->queued_bytes -= n;
    if (pes->off >= pes->len) {
        m->free_fn(pes->data);
        es->qh = (es->qh + 1) % TS_MUX_QUEUE;
        es->qn--;
    }
}

void ts_mux_next(ts_mux_t *m, uint8_t *p) {
    const int64_t now = m->clock27;
    m->clock27 += (int64_t)TS_PKT * 8 * 27000000 / m->mux_rate;
    if (now >= m->next_psi) {
        queue_psi(m);
        m->next_psi = now + (int64_t)m->pat_period_ms * 27000;
    }
    if (m->psi_pos < m->npsi) {
        memcpy(p, m->psi[m->psi_pos++], TS_PKT);
        m->psi_packets++;
        return;
    }
    const bool pcr_due = now >= m->next_pcr;
    ts_es_t *es = NULL;
    for (int k = 0; k < m->nes; ++k) {
        ts_es_t *e = &m->es[k];
        if (!e->qn) continue;
        if (!es || e->q[e->qh].dts90k < es->q[es->qh].dts90k) es = e;
    }
    if (pcr_due) m->next_pcr = now + (int64_t)m->pcr_period_ms * 27000;
    if (!es) {
        if (pcr_due) { pcr_only(m, p, now); return; }
        memset(p, 0xFF, TS_PKT);
        memcpy(p, null_pkt_hdr, 4);
        m->null_packets++;
        return;
    }
    if (pcr_due && es != &m->es[0]) { pcr_only(m, p, now); return; }
    m->data_packets++;
    if (es->q[es->qh].dts90k * 300 < now) m->late_packets++;
    data_packet(m, es, p, pcr_due ? now : -1);
}

/* ---------------------------------------------------------------- demultiplexer */

void ts_demux_init(ts_demux_t *d, uint8_t *vbuf, uint32_t vcap, uint8_t *abuf, uint32_t acap, ts_pes_fn fn, void *ctx) {
    memset(d, 0, sizeof(*d));
    d->pmt_pid = 0xFFFF;
    d->v.pid = d->a.pid = 0xFFFF;
    d->v.buf = vbuf; d->v.cap = vcap;
    d->a.buf = abuf; d->a.cap = acap;
    d->on_pes = fn;
    d->ctx = ctx;
}

static void flush_pes(ts_demux_t *d, ts_dpid_t *s, int kind) {
    if (!s->started || s->len < 9) { s->started = false; s->len = 0; return; }
    const uint8_t *b = s->buf;
    if (b[0] || b[1] || b[2] != 1) { s->started = false; s->len = 0; return; }
    const uint32_t hl = 9u + b[8];
    int64_t pts = -1;
    if ((b[7] & 0x80) && s->len >= 14)
        pts = ((int64_t)(b[9] >> 1 & 7) << 30) | ((int64_t)b[10] << 22) | ((int64_t)(b[11] >> 1) << 15) | ((int64_t)b[12] << 7) | (b[13] >> 1);
    if (hl <= s->len) {
        if (s->damaged) d->pes_damaged++;
        else d->pes_ok++;
        if (d->on_pes) d->on_pes(d->ctx, kind, b + hl, s->len - hl, pts, s->damaged);
    }
    s->started = false;
    s->len = 0;
}

static void parse_section(ts_demux_t *d, uint16_t pid, const uint8_t *p, int n) {
    if (n < 1) return;
    const int ptr = p[0];
    p += 1 + ptr;
    n -= 1 + ptr;
    if (n < 8) return;
    const int slen = ((p[1] & 0x0F) << 8) | p[2];
    if (slen + 3 > n || slen < 9) return;
    if (crc32_mpeg(p, (size_t)slen + 3) != 0) return;     /* CRC over the section including its CRC is 0 */
    const uint8_t *body = p + 8;
    const int blen = slen - 9;
    if (pid == 0 && p[0] == 0x00) {
        for (int k = 0; k + 4 <= blen; k += 4) {
            const uint16_t prog = (uint16_t)(body[k] << 8 | body[k + 1]);
            if (prog) { d->pmt_pid = (uint16_t)((body[k + 2] & 0x1F) << 8 | body[k + 3]); break; }
        }
    } else if (pid == d->pmt_pid && p[0] == 0x02 && blen >= 4) {
        int k = 4 + (((body[2] & 0x0F) << 8) | body[3]);
        while (k + 5 <= blen) {
            const uint8_t type = body[k];
            const uint16_t epid = (uint16_t)((body[k + 1] & 0x1F) << 8 | body[k + 2]);
            const int il = ((body[k + 3] & 0x0F) << 8) | body[k + 4];
            if ((type == 0x1B) && d->v.pid != epid) { d->v.pid = epid; d->v.type = type; d->v.have_cc = false; }
            if ((type == 0x03 || type == 0x04 || type == 0x0F) && d->a.pid != epid) { d->a.pid = epid; d->a.type = type; d->a.have_cc = false; }
            k += 5 + il;
        }
    } else if (pid == 0x11 && p[0] == 0x42 && blen >= 3) {
        int k = 3;
        while (k + 5 <= blen) {
            const int dl = ((body[k + 3] & 0x0F) << 8) | body[k + 4];
            int j = k + 5;
            while (j + 2 <= k + 5 + dl && j + 2 <= blen) {
                const int tag = body[j], len = body[j + 1];
                if (tag == 0x48 && j + 2 + len <= blen && len >= 3) {
                    const int pl = body[j + 3];
                    if (4 + pl < len + 2) {
                        const int sl = body[j + 4 + pl];
                        snprintf(d->provider, sizeof(d->provider), "%.*s", pl < 31 ? pl : 31, (const char *)body + j + 4);
                        if (j + 5 + pl + sl <= blen) snprintf(d->service, sizeof(d->service), "%.*s", sl < 31 ? sl : 31, (const char *)body + j + 5 + pl);
                    }
                }
                j += 2 + len;
            }
            k += 5 + dl;
            break;                                         /* one service */
        }
    }
}

void ts_demux_push(ts_demux_t *d, const uint8_t *p) {
    d->packets++;
    if (p[0] != 0x47) return;
    const bool tei = p[1] & 0x80, pusi = p[1] & 0x40;
    const uint16_t pid = (uint16_t)((p[1] & 0x1F) << 8 | p[2]);
    if (tei) {
        d->tei++;
        if (pid == d->v.pid || d->v.started) d->v.damaged = true;
        if (pid == d->a.pid || d->a.started) d->a.damaged = true;
        return;
    }
    const int afc = (p[3] >> 4) & 3, cc = p[3] & 0x0F;
    int o = 4;
    if (afc & 2) o += 1 + p[4];
    if (!(afc & 1) || o >= TS_PKT) return;
    if (pid == 0 || pid == d->pmt_pid || pid == 0x11) {
        if (pusi) parse_section(d, pid, p + o, TS_PKT - o);
        return;
    }
    ts_dpid_t *s = pid == d->v.pid ? &d->v : pid == d->a.pid ? &d->a : NULL;
    if (!s) return;
    const int kind = s == &d->v ? 0 : 1;
    if (s->have_cc && cc != ((s->cc + 1) & 0x0F)) { d->cc_errors++; s->damaged = true; }
    s->cc = (uint8_t)cc;
    s->have_cc = true;
    if (pusi) {
        flush_pes(d, s, kind);
        s->started = true;
        s->damaged = false;
    }
    if (!s->started) return;
    const uint32_t n = (uint32_t)(TS_PKT - o);
    if (s->len + n > s->cap) { s->damaged = true; return; }
    memcpy(s->buf + s->len, p + o, n);
    s->len += n;
    if (s->len >= 6) {                                     /* a PES with a length is complete without waiting for the next one */
        const uint32_t pl = (uint32_t)s->buf[4] << 8 | s->buf[5];
        if (pl && s->len >= 6 + pl) { s->len = 6 + pl; flush_pes(d, s, kind); }
    }
}
