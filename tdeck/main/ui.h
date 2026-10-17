#pragma once
#include <stdbool.h>
#include <stdint.h>

bool ui_start(void);              /* T-Deck only: display, input and the UI task */
void ui_lcd_flags(uint32_t f);    /* change the panel orientation flags and redraw */
void ui_inject(int key);          /* queue an input event as if typed (console tests) */
