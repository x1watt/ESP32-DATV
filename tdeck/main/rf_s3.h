/* ESP32-S3 radio access for the T-Deck DATV firmware: PHY bring-up, tuning, receive gain and the
 * RF sample engine registers (found by disassembling librftest adctrig / dactrig of ESP-IDF 6.1). */
#pragma once
#include <stdbool.h>
#include <stdint.h>

#define RF_CAP_CTRL   0x60033D5Cu   /* capture: bit 31 run, 19 trigger, 18 done, 17 circular, 16 16 MS/s, 15 40 MS/s, low bits length */
#define RF_CAP_INDEX  0x60033D60u   /* capture write index (mod 16384 in circular mode) */
#define RF_CAP_CONFIG 0x60033D90u
#define RF_CAP_CONFIG_IQ 0x000C2040u /* complex samples: one 32-bit word per pair, two signed 10-bit fields, gain index in 27..20 */
#define RF_DAC_CTRL   0x60033D64u   /* playback: 13..0 words - 1, 15 80 MS/s (else 40), 18 done, 19 hold, 31 run */
#define RF_BANK_OWNER 0x600C101Cu   /* bits 3..0: bank k (0x3FCB0000 + k * 64 KiB) belongs to the RF block */
#define RF_BANK(k)    ((volatile uint32_t *)(0x3FCB0000u + 0x10000u * (k)))
#define RF_BANK_WORDS 16384u

static inline uint32_t rf_rd(uint32_t a) { return *(volatile uint32_t *)a; }
static inline void rf_wr(uint32_t a, uint32_t v) { *(volatile uint32_t *)a = v; }

void rf_s3_init(void);                       /* Wi-Fi driver start (PHY calibration), promiscuous, parked */
bool rf_tune(uint32_t fkhz);              /* receive mode at fkhz (2200..2800 MHz); false outside */
double rf_lo_hz(void);                    /* exact LO after the last tune */
void rf_gain(int index);                  /* -1: hardware AGC, else a fixed gain table index */
unsigned rf_gain_max(void);
bool rf_parse_freq(const char *s, uint32_t *khz);   /* "2370", "2370.25" -> kHz */
