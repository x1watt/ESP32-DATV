#include "rf_s3.h"
#include <math.h>
#include <stdlib.h>
#include "esp_event.h"
#include "esp_wifi.h"
#include "heap_memory_layout.h"
#include "nvs_flash.h"

/* Sample banks 0..2 of the RF block (64 KiB each). Bank 3 at 0x3FCE0000 overlaps the ROM's PHY data. */
SOC_RESERVE_MEMORY_REGION(0x3fcb0000, 0x3fce0000, s3_rf_banks);

extern void stop_tx_tone(unsigned);
extern void rom_pbus_workmode(void);
extern void rom_pbus_xpd_rx_on(unsigned);
extern void rom_pbus_xpd_tx_off(void);
extern void rom_set_rxclk_en(unsigned);
extern void set_chanfreq(unsigned, unsigned);
extern void phy_set_freq(unsigned, int);
extern void force_rx_gain(unsigned, unsigned, unsigned);

static double lo_hz;

static unsigned chan_mhz(unsigned ch) { return ch == 14 ? 2484 : 2407 + 5 * ch; }

/* Same integer arithmetic as libphy rfpll_set_freq, 40 MHz crystal (as in firmware/main/main.c). */
static double pll_hz(unsigned mhz, int khz) {
    const int32_t d = 120000;
    int32_t a = 4 * (int32_t)(1000 * mhz + khz) - 32 * d;
    int32_t o0 = a / d;
    a -= o0 * d;
    a <<= 8;
    int32_t o1 = a / d;
    a -= o1 * d;
    a <<= 8;
    int32_t o2 = a / d;
    return 30e6 * ((o0 & 255) + 32 + ((o1 & 255) * 256 + (o2 & 255)) / 65536.0);
}

void rf_s3_init(void) {
    esp_err_t e = nvs_flash_init();
    if (e == ESP_ERR_NVS_NO_FREE_PAGES || e == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        e = nvs_flash_init();
    }
    ESP_ERROR_CHECK(e);
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));
    ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_RAM));
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_NULL));
    ESP_ERROR_CHECK(esp_wifi_start());
    ESP_ERROR_CHECK(esp_wifi_set_ps(WIFI_PS_NONE));
    ESP_ERROR_CHECK(esp_wifi_set_promiscuous(true));
    ESP_ERROR_CHECK(esp_wifi_set_channel(1, WIFI_SECOND_CHAN_NONE));
    rf_tune(2412000);
}

bool rf_tune(uint32_t fkhz) {
    if (fkhz < 2200000 || fkhz > 2800000) return false;
    int ch = ((int)fkhz - 2407000 + 2500) / 5000;
    ch = ch < 1 ? 1 : ch > 13 ? 13 : ch;
    const unsigned mhz = fkhz / 1000;
    const int khz = (int)(fkhz % 1000);
    set_chanfreq(chan_mhz(ch), 0);
    if (fkhz != chan_mhz(ch) * 1000u) phy_set_freq(mhz, khz);
    stop_tx_tone(1);
    rom_pbus_workmode();
    rom_pbus_xpd_tx_off();
    rom_pbus_xpd_rx_on(1);
    rom_set_rxclk_en(1);
    force_rx_gain(0, 40, 0);
    lo_hz = pll_hz(mhz, khz);
    return true;
}

double rf_lo_hz(void) { return lo_hz; }

unsigned rf_gain_max(void) {
    const unsigned m = (rf_rd(0x6001C02Cu) >> 8) & 127u;
    return m < 80u ? m : 0u;
}

void rf_gain(int index) {
    if (index < 0) force_rx_gain(0, 40, 0);
    else force_rx_gain(1, (unsigned)index, 0);
}

bool rf_parse_freq(const char *s, uint32_t *khz) {
    char *e;
    const unsigned long whole = strtoul(s, &e, 10);
    if (e == s) return false;
    uint32_t frac = 0, scale = 100;
    if (*e == '.') {
        for (++e; *e >= '0' && *e <= '9'; ++e) {
            frac += (*e - '0') * scale;
            scale /= 10;
            if (!scale && e[1] >= '0' && e[1] <= '9') return false;
        }
    }
    if (*e) return false;
    *khz = whole * 1000 + frac;
    return true;
}
