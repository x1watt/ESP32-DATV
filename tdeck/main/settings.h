/* Persistent user settings (NVS). */
#pragma once
#include <stdint.h>

typedef struct {
    uint32_t freq_khz;
    uint32_t baud;
    uint8_t fec;              /* dvbs_fec_t */
    uint8_t audio;            /* 0 microphone, 1 tone, 2 off */
    uint16_t amp;             /* DAC amplitude, codes */
    int16_t rx_gain;          /* -1 AGC, else the receiver gain index */
    int16_t ppm_x10;          /* crystal correction, 0.1 ppm */
    uint32_t lcd;             /* LCD_* flags */
    char call[12];
    char text[64];
    char board[8];            /* "tdeck" or "" (no display, console only) */
    uint8_t autotx;           /* 1: transmit from power-up (boards without a display) */
} settings_t;

extern settings_t settings;
void settings_load(void);
void settings_save(void);
