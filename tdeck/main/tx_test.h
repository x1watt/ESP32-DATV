#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef struct {
    uint32_t triggers, timeouts, max_wait, fill_cycles, owner_cycles, trig_cycles, done_to_owner;
    double cycles_per_trigger, trig_rate, duty;
} tx_test_result_t;

bool tx_test(uint32_t fkhz, int mode, uint32_t secs, int32_t tone_hz, uint32_t n, bool rate80, int amp, tx_test_result_t *res);
