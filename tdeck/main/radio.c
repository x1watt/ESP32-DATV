#include "radio.h"
#include "esp_heap_caps.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "rf_s3.h"

static SemaphoreHandle_t mtx;
static rx_stream_t rxs;
static uint32_t rate;

bool radio_lock(void) {
    if (!mtx) mtx = xSemaphoreCreateMutex();
    return xSemaphoreTake(mtx, 0) == pdTRUE;
}

void radio_unlock(void) { xSemaphoreGive(mtx); }

rx_stream_t *radio_stream(void) { return &rxs; }
uint32_t radio_rx_rate(void) { return rate; }

bool radio_rx_start(uint32_t fkhz, uint32_t cic, int gain) {
    if (!rxs.buf) {
        rxs.size = 65536;                        /* 262 ms at 250 kS/s in PSRAM: slack for the DVB-S acquisition */
        rxs.buf = heap_caps_malloc(rxs.size * sizeof(iq16_t), MALLOC_CAP_SPIRAM);
        if (!rxs.buf) return false;
    }
    if (!rf_tune(fkhz - 4000u)) return false;
    rf_gain(gain);
    int shift = 0;                               /* CIC gain cic^3, boxcar 4, 10-bit input: about 12 bits out */
    for (uint32_t g = cic * cic * cic * 4u; g > 8u; g >>= 1) ++shift;
    /* the capture words carry I in bits 19..10 (swap) and the LO is below the signal (dir 1) */
    const rx_config_t cfg = {.cic_r = cic, .shift = shift, .dir = 1, .swap = true};
    rate = 4000000u / cic;
    return rx_start(&cfg, &rxs);
}

void radio_rx_stop(void) { rx_stop(); }
