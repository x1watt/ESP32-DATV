#include "board.h"
#include <string.h>
#include "driver/gpio.h"
#include "driver/i2c_master.h"
#include "driver/spi_master.h"
#include "esp_heap_caps.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_panel_vendor.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

/* T-Deck pins (Xinyuan-LilyGO/T-Deck utilities.h) */
#define PIN_POWER_ON 10
#define PIN_LCD_CS 12
#define PIN_LCD_DC 11
#define PIN_LCD_BL 42
#define PIN_SPI_MOSI 41
#define PIN_SPI_MISO 38
#define PIN_SPI_SCK 40
#define PIN_SD_CS 39
#define PIN_LORA_CS 9
#define PIN_I2C_SDA 18
#define PIN_I2C_SCL 8
#define KB_ADDR 0x55
#define PIN_TB_UP 3
#define PIN_TB_DOWN 15
#define PIN_TB_LEFT 1
#define PIN_TB_RIGHT 2
#define PIN_TB_CLICK 0

#define STRIP 12                                  /* rows per DMA transfer (internal RAM is short) */

static esp_lcd_panel_handle_t panel;
static i2c_master_dev_handle_t kb;
static i2c_master_bus_handle_t i2c_bus;
static uint16_t *dma_buf;
static SemaphoreHandle_t flush_done;
static volatile uint32_t tb_count[4];
static uint32_t tb_seen[4];
static bool click_prev;
static int64_t kb_next_poll;

static bool IRAM_ATTR on_flush_done(esp_lcd_panel_io_handle_t io, esp_lcd_panel_io_event_data_t *e, void *ctx) {
    BaseType_t woken = pdFALSE;
    xSemaphoreGiveFromISR(flush_done, &woken);
    return woken == pdTRUE;
}

static void IRAM_ATTR tb_isr(void *arg) { tb_count[(uint32_t)arg]++; }

void board_lcd_flags(uint32_t f) {
    if (!panel) return;
    esp_lcd_panel_swap_xy(panel, (f & LCD_SWAP_XY) != 0);
    esp_lcd_panel_mirror(panel, (f & LCD_MIRROR_X) != 0, (f & LCD_MIRROR_Y) != 0);
    esp_lcd_panel_invert_color(panel, (f & LCD_INVERT) != 0);
}

bool board_init(uint32_t lcd_flags) {
    gpio_config_t out = {.pin_bit_mask = (1ull << PIN_POWER_ON) | (1ull << PIN_SD_CS) | (1ull << PIN_LORA_CS), .mode = GPIO_MODE_OUTPUT};
    gpio_config(&out);
    gpio_set_level(PIN_POWER_ON, 1);
    gpio_set_level(PIN_SD_CS, 1);                  /* keep the other SPI devices off the bus */
    gpio_set_level(PIN_LORA_CS, 1);
    vTaskDelay(pdMS_TO_TICKS(200));                /* the keyboard controller boots */

    spi_bus_config_t bus = {.mosi_io_num = PIN_SPI_MOSI, .miso_io_num = PIN_SPI_MISO, .sclk_io_num = PIN_SPI_SCK,
                            .quadwp_io_num = -1, .quadhd_io_num = -1, .max_transfer_sz = LCD_W * STRIP * 2};
    if (spi_bus_initialize(SPI2_HOST, &bus, SPI_DMA_CH_AUTO) != ESP_OK) return false;
    flush_done = xSemaphoreCreateBinary();
    esp_lcd_panel_io_handle_t io;
    esp_lcd_panel_io_spi_config_t ioc = {.cs_gpio_num = PIN_LCD_CS, .dc_gpio_num = PIN_LCD_DC, .spi_mode = 0, .pclk_hz = 40000000,
                                         .trans_queue_depth = 2, .on_color_trans_done = on_flush_done, .lcd_cmd_bits = 8, .lcd_param_bits = 8};
    if (esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)SPI2_HOST, &ioc, &io) != ESP_OK) return false;
    esp_lcd_panel_dev_config_t pc = {.reset_gpio_num = -1, .rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB, .bits_per_pixel = 16};
    if (esp_lcd_new_panel_st7789(io, &pc, &panel) != ESP_OK) return false;
    esp_lcd_panel_reset(panel);
    esp_lcd_panel_init(panel);
    board_lcd_flags(lcd_flags);
    esp_lcd_panel_disp_on_off(panel, true);
    dma_buf = heap_caps_malloc(LCD_W * STRIP * 2, MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
    if (!dma_buf) return false;
    gpio_config_t bl = {.pin_bit_mask = 1ull << PIN_LCD_BL, .mode = GPIO_MODE_OUTPUT};
    gpio_config(&bl);
    gpio_set_level(PIN_LCD_BL, 1);

    i2c_master_bus_handle_t i2c = NULL;
    i2c_master_bus_config_t ib = {.i2c_port = 0, .sda_io_num = PIN_I2C_SDA, .scl_io_num = PIN_I2C_SCL, .clk_source = I2C_CLK_SRC_DEFAULT,
                                  .glitch_ignore_cnt = 7, .flags.enable_internal_pullup = true};
    if (i2c_new_master_bus(&ib, &i2c) == ESP_OK) {
        i2c_bus = i2c;
        i2c_device_config_t dc = {.dev_addr_length = I2C_ADDR_BIT_LEN_7, .device_address = KB_ADDR, .scl_speed_hz = 100000};
        i2c_master_bus_add_device(i2c, &dc, &kb);
    }

    const int tb[4] = {PIN_TB_UP, PIN_TB_DOWN, PIN_TB_LEFT, PIN_TB_RIGHT};
    gpio_config_t in = {.mode = GPIO_MODE_INPUT, .pull_up_en = GPIO_PULLUP_ENABLE, .intr_type = GPIO_INTR_ANYEDGE};
    for (int k = 0; k < 4; ++k) in.pin_bit_mask |= 1ull << tb[k];
    gpio_config(&in);
    gpio_config_t ck = {.pin_bit_mask = 1ull << PIN_TB_CLICK, .mode = GPIO_MODE_INPUT, .pull_up_en = GPIO_PULLUP_ENABLE};
    gpio_config(&ck);
    gpio_install_isr_service(0);
    for (int k = 0; k < 4; ++k) gpio_isr_handler_add(tb[k], tb_isr, (void *)(uintptr_t)k);
    return true;
}

void board_lcd_flush(const uint16_t *fb, int y0, int y1) {
    if (!panel) return;
    for (int y = y0; y < y1; y += STRIP) {
        const int h = y1 - y < STRIP ? y1 - y : STRIP;
        const uint16_t *src = fb + y * LCD_W;
        for (int k = 0; k < h * LCD_W; ++k) dma_buf[k] = (uint16_t)(src[k] << 8 | src[k] >> 8);   /* the panel takes big-endian RGB565 */
        esp_lcd_panel_draw_bitmap(panel, 0, y, LCD_W, y + h, dma_buf);
        xSemaphoreTake(flush_done, portMAX_DELAY);
    }
}

void *board_i2c_bus(void) { return i2c_bus; }

int board_key(void) {
    /* trackball: two edges per detent */
    static const int dirs[4] = {KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT};
    for (int k = 0; k < 4; ++k) {
        const uint32_t c = tb_count[k];
        if (c - tb_seen[k] >= 2) { tb_seen[k] += 2; return dirs[k]; }
    }
    const bool click = gpio_get_level(PIN_TB_CLICK) == 0;
    if (click && !click_prev) { click_prev = true; return KEY_CLICK; }
    click_prev = click;
    const int64_t now = esp_timer_get_time();
    if (kb && now >= kb_next_poll) {
        kb_next_poll = now + 20000;
        uint8_t c = 0;
        if (i2c_master_receive(kb, &c, 1, 20) == ESP_OK && c) return c;
    }
    return KEY_NONE;
}
