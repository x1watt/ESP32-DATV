/* MPEG transport stream: a constant-rate multiplexer (port of app/lib/core/ts/mux.dart) and a
 * small demultiplexer for one service (PAT, PMT, SDT, PES reassembly). */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define TS_PKT 188

uint32_t crc32_mpeg(const uint8_t *d, size_t n);

/* ---------------------------------------------------------------- multiplexer
 * Pull model: every ts_mux_next() advances the mux clock by one packet at mux_rate, PCR is that
 * clock, so the stream is CBR by construction; null packets fill the gaps. Access units are queued
 * with source timestamps; the first one fixes the offset to mux time (delay_ms of buffering). */

typedef enum { TS_ES_H264 = 0x1B, TS_ES_MP2 = 0x04 } ts_es_type_t;

#define TS_MUX_QUEUE 32

typedef struct {
    uint8_t *data;            /* complete PES packet (malloc) */
    uint32_t len, off;
    int64_t dts90k;           /* mux time */
} ts_pes_t;

typedef struct {
    uint16_t pid;
    uint8_t type, stream_id;
    uint8_t cc;
    ts_pes_t q[TS_MUX_QUEUE];
    uint32_t qh, qn;          /* queue head and count */
    uint32_t queued_bytes;
} ts_es_t;

typedef struct {
    uint32_t mux_rate;
    char service[32], provider[32];
    uint32_t pat_period_ms, pcr_period_ms, delay_ms;
    uint16_t service_id, pmt_pid;
    ts_es_t es[2];            /* [0] video, [1] audio (pid 0: none) */
    int nes;
    int64_t clock27;
    bool have_offset;
    int64_t offset90k;
    int64_t next_psi, next_pcr;
    uint8_t pat_cc, pmt_cc, sdt_cc;
    uint8_t psi[3][TS_PKT];
    int npsi, psi_pos;
    uint32_t data_packets, null_packets, psi_packets, late_packets, dropped;
    void *(*alloc)(size_t);
    void (*free_fn)(void *);
} ts_mux_t;

void ts_mux_init(ts_mux_t *m, uint32_t mux_rate, const char *service, const char *provider, bool audio,
                 void *(*alloc)(size_t), void (*free_fn)(void *));
/* source times in microseconds; false if the queue is full (the unit is dropped) */
bool ts_mux_add_video(ts_mux_t *m, const uint8_t *au, uint32_t len, int64_t pts_us);
bool ts_mux_add_audio(ts_mux_t *m, const uint8_t *frame, uint32_t len, int64_t pts_us);
void ts_mux_next(ts_mux_t *m, uint8_t *pkt);
/* seconds of data queued ahead of the mux clock */
double ts_mux_buffered(const ts_mux_t *m);
/* how far ahead of the mux clock a unit with this source time would be (0 before the first unit) */
double ts_mux_ahead(const ts_mux_t *m, int64_t pts_us);

/* ---------------------------------------------------------------- demultiplexer */

typedef void (*ts_pes_fn)(void *ctx, int kind /* 0 video, 1 audio */, const uint8_t *payload, uint32_t len, int64_t pts90k, bool damaged);

typedef struct {
    uint16_t pid;
    uint8_t type;
    uint8_t cc;
    bool have_cc, damaged, started;
    uint8_t *buf;             /* reassembly buffer */
    uint32_t len, cap;
} ts_dpid_t;

typedef struct {
    uint16_t pmt_pid;
    ts_dpid_t v, a;
    char service[32], provider[32];
    ts_pes_fn on_pes;
    void *ctx;
    uint32_t packets, cc_errors, tei, pes_ok, pes_damaged;
} ts_demux_t;

/* buffers: video up to vcap bytes per access unit, audio up to acap */
void ts_demux_init(ts_demux_t *d, uint8_t *vbuf, uint32_t vcap, uint8_t *abuf, uint32_t acap, ts_pes_fn fn, void *ctx);
void ts_demux_push(ts_demux_t *d, const uint8_t *pkt);
