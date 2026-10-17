#include "settings.h"
#include <string.h>
#include "board.h"
#include "nvs.h"

settings_t settings;

static const settings_t defaults = {
    .freq_khz = 2370000, .baud = 66000, .fec = 0, .audio = 1, .amp = 150, .rx_gain = 30, .ppm_x10 = 0,
    .lcd = LCD_SWAP_XY | LCD_MIRROR_X | LCD_INVERT, .call = "NOCALL", .text = "", .board = "",
};

void settings_load(void) {
    settings = defaults;
    nvs_handle_t h;
    if (nvs_open("tdeck", NVS_READONLY, &h) != ESP_OK) return;
    /* new fields are appended at the end: an older, shorter blob keeps its values and the new fields their defaults */
    size_t n = 0;
    if (nvs_get_blob(h, "settings", NULL, &n) == ESP_OK && n && n <= 4096) {
        uint8_t buf[4096];
        if (nvs_get_blob(h, "settings", buf, &n) == ESP_OK) memcpy(&settings, buf, n < sizeof(settings) ? n : sizeof(settings));
    }
    nvs_close(h);
    settings.call[sizeof(settings.call) - 1] = 0;
    settings.text[sizeof(settings.text) - 1] = 0;
    settings.board[sizeof(settings.board) - 1] = 0;
}

void settings_save(void) {
    nvs_handle_t h;
    if (nvs_open("tdeck", NVS_READWRITE, &h) != ESP_OK) return;
    nvs_set_blob(h, "settings", &settings, sizeof(settings));
    nvs_commit(h);
    nvs_close(h);
}
