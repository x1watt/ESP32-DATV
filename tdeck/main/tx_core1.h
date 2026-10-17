/* QPSK transmitter: core 1 turns packed symbols (4 per byte, first in the low bits; bit 0 = I level,
 * bit 1 = Q level, 1 = +1, the format of the DVB-S encoder) into RRC-filtered I/Q on the RF block. */
#pragma once
#include <stdbool.h>
#include <stdint.h>

#define TX_RING 8192u                      /* symbol bytes: 32 Ki symbols, 0.5 s at 66 kBd */

typedef struct {
    uint32_t fkhz, baud;
    int amp;                               /* peak DAC code of the filtered signal (linear up to about 200) */
    double ppm;                            /* crystal correction of the symbol rate */
    float dci, dcq, gain, phase_deg;       /* carrier leak and image calibration (0, 0, 1, 0: none) */
} tx_params_t;

typedef struct {
    uint32_t buffers, underruns, late, hole_max, fill_cycles, ring_fill;
} tx_status_t;

bool tx_start(const tx_params_t *p);       /* tune, key the transmitter and start core 1 */
void tx_stop(void);
uint32_t tx_room(void);                    /* free bytes in the symbol ring */
void tx_push(const uint8_t *sym_bytes, uint32_t n);
const tx_status_t *tx_status(void);
