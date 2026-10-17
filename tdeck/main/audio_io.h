/* T-Deck audio: MAX98357A speaker on I2S0, ES7210 microphones on I2S1 (16-bit mono PCM). */
#pragma once
#include <stdbool.h>
#include <stdint.h>

bool audio_out_start(int rate);
void audio_out_write(const int16_t *pcm, int n);   /* blocks until queued */
void audio_out_stop(void);

bool audio_in_start(int rate);                     /* T-Deck only (needs board_init) */
int audio_in_read(int16_t *pcm, int n);            /* mono samples read (blocks up to about 100 ms) */
void audio_in_stop(void);
void audio_in_diag(int *id_hi, int *id_lo, int16_t *raw8);   /* chip id registers and the first raw words of the last read */
void audio_in_slot(int slot);                                  /* which of the four TDM slots is the microphone */
