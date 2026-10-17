/* LilyGO T-Deck peripherals: ST7789 320x240 display, keyboard (ESP32-C3 at I2C 0x55), trackball. */
#pragma once
#include <stdbool.h>
#include <stdint.h>

#define LCD_W 320
#define LCD_H 240

/* Display orientation / colour bits (adjustable from the console until confirmed on the panel). */
#define LCD_SWAP_XY 1u
#define LCD_MIRROR_X 2u
#define LCD_MIRROR_Y 4u
#define LCD_INVERT 8u

bool board_init(uint32_t lcd_flags);          /* power, display, keyboard, trackball; false if absent */
void board_lcd_flags(uint32_t lcd_flags);
/* Sends rows [y0, y1) of a 320-wide RGB565 frame (native byte order) to the panel. */
void board_lcd_flush(const uint16_t *fb, int y0, int y1);

enum {
    KEY_NONE = 0,
    KEY_UP = 0x101, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_CLICK,   /* trackball */
    KEY_ENTER = '\r', KEY_BACKSPACE = 8,
};
void *board_i2c_bus(void);                 /* i2c_master_bus_handle_t of SDA 18 / SCL 8, NULL before board_init */
/* Next input event: a keyboard character, a trackball step or click; KEY_NONE if none. */
int board_key(void);
