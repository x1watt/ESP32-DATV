/* The one radio, shared by the console and the UI. */
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "rx_core1.h"

bool radio_lock(void);           /* false if someone else uses the radio */
void radio_unlock(void);
/* Receive centred on fkhz (LO 4 MHz below), decimated to 4 MHz / cic. Call with the lock held. */
bool radio_rx_start(uint32_t fkhz, uint32_t cic, int gain);
void radio_rx_stop(void);
rx_stream_t *radio_stream(void);
uint32_t radio_rx_rate(void);
