/* Receive pipeline on core 0: samples from core 1 -> QPSK demodulator -> DVB-S back end -> TS packets. */
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "datv/demod.h"

typedef void (*rx_ts_fn)(const uint8_t *pkt188);

typedef struct {
    int state;                    /* demod_state_t */
    bool locked;                  /* DVB-S byte sync */
    float offset_hz, mer_db;
    int fec;                      /* found code rate, -1 none */
    uint32_t packets, rs_corrected, rs_failed, resyncs, symbols, overruns, gaps;
    float load_demod, load_dvbs;  /* % of core 0 since the last call */
} rx_pipe_stat_t;

bool rx_pipe_start(uint32_t fkhz, uint32_t baud, int fec_fixed, rx_ts_fn on_ts);   /* takes the radio lock */
void rx_pipe_stop(void);
bool rx_pipe_running(void);
void rx_pipe_stats(rx_pipe_stat_t *s);
/* newest 256 input pairs for a spectrum display; false if none since the last call */
bool rx_pipe_snapshot(int16_t *iq512);
uint32_t rx_pipe_rate(void);
extern const char *rx_pipe_err;      /* why rx_pipe_start failed */
