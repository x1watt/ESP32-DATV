/* Gapless receive on the ESP32-S3: the RF block's circular capture runs at 16 MS/s, core 1 rotates
 * it through three sample banks and decimates to a narrow complex stream for core 0. */
#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef struct { int16_t i, q; } iq16_t;

typedef struct {
    /* consumer side (core 0) */
    iq16_t *buf;                  /* power-of-two ring of decimated pairs */
    uint32_t size;
    volatile uint32_t r;          /* pairs read (free running), written by core 0 */
    /* producer side (core 1) */
    volatile uint32_t w;          /* pairs written (free running) */
    volatile uint32_t units;      /* banks processed */
    volatile uint32_t gaps;       /* discontinuities in the 16 MS/s input (lost samples) */
    volatile uint32_t overruns;   /* output pairs dropped because core 0 did not read */
    volatile uint32_t late;       /* switches with no free bank (core 1 too slow) */
    volatile uint32_t scan_fail;  /* unit boundaries not found by the sentinel scan */
    volatile uint32_t start_fail, end_fail;
    uint32_t diag[4][6];          /* first failures: bank, unit, start target, end target, start scan, end scan */
    volatile uint32_t ndiag;
    volatile uint32_t last_gap_w; /* output index at the last gap */
    volatile uint32_t sw_max;     /* largest index advance during a bank switch */
    volatile uint32_t unit_min, unit_max;
    volatile uint32_t busy, total; /* core 1 cycles spent processing / elapsed (since start) */
    volatile uint64_t in_pairs;   /* 16 MS/s pairs consumed */
} rx_stream_t;

typedef struct {
    uint32_t cic_r;      /* 4 MS/s -> 4 MHz / cic_r (16: 250 kS/s, 32: 125 kS/s, 64, 128) */
    int shift;           /* right shift of the CIC output to int16 */
    int dir;             /* +1: the signal is fs/4 (4 MHz) above the LO, -1: below */
    bool swap;           /* swap the two 10-bit fields (I/Q order) */
} rx_config_t;

void rx_core1_init(void);                                 /* creates the core 1 task (idle until started) */
bool rx_start(const rx_config_t *cfg, rx_stream_t *s);    /* tune first; s->buf / s->size set by the caller */
void rx_stop(void);                                       /* blocks until core 1 has left the loop */
bool rx_running(void);

/* Core 1 runs one loop at a time with interrupts masked (the receive capture or the transmitter). */
bool core1_launch(void (*fn)(void));
bool core1_want(void);                                   /* the loop keeps running while this is true */
void core1_stop(void);                                   /* asks the loop to end and waits */
