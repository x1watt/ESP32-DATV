#include "audio_io.h"
#include <stdlib.h>
#include "board.h"
#include "driver/i2s_std.h"
#include "driver/i2s_tdm.h"
#include "esp_codec_dev.h"
#include "esp_codec_dev_defaults.h"
#include "es7210_adc.h"
#include "esp_heap_caps.h"

/* T-Deck pins (Xinyuan-LilyGO/T-Deck utilities.h) */
#define SPK_BCK 7
#define SPK_WS 5
#define SPK_DOUT 6
#define MIC_MCLK 48
#define MIC_SCK 47
#define MIC_LRCK 21
#define MIC_DIN 14

static i2s_chan_handle_t spk, mic;
static esp_codec_dev_handle_t mic_dev;
static int16_t *mic_buf;
static int mic_slot = 0;                     /* measured: slot 0 hears the speaker at +86 dB over silence */

void audio_in_slot(int slot) { mic_slot = slot & 3; }

bool audio_out_start(int rate) {
    if (spk) return true;
    i2s_chan_config_t cc = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_0, I2S_ROLE_MASTER);
    cc.dma_desc_num = 4;
    cc.dma_frame_num = 240;
    if (i2s_new_channel(&cc, &spk, NULL) != ESP_OK) return false;
    i2s_std_config_t sc = {
        .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG((uint32_t)rate),
        .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO),
        .gpio_cfg = {.mclk = I2S_GPIO_UNUSED, .bclk = SPK_BCK, .ws = SPK_WS, .dout = SPK_DOUT, .din = I2S_GPIO_UNUSED},
    };
    if (i2s_channel_init_std_mode(spk, &sc) != ESP_OK || i2s_channel_enable(spk) != ESP_OK) {
        i2s_del_channel(spk);
        spk = NULL;
        return false;
    }
    return true;
}

void audio_out_write(const int16_t *pcm, int n) {
    if (!spk) return;
    size_t done = 0;
    i2s_channel_write(spk, pcm, (size_t)n * 2, &done, 200);
}

void audio_out_stop(void) {
    if (!spk) return;
    i2s_channel_disable(spk);
    i2s_del_channel(spk);
    spk = NULL;
}

bool audio_in_start(int rate) {
    if (mic_dev) return true;
    if (!board_i2c_bus()) return false;
    /* The ES7210 puts all four inputs on its one data line connected to the S3 (TDM, as in the LilyGO example). */
    i2s_chan_config_t cc = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_1, I2S_ROLE_MASTER);
    cc.dma_desc_num = 4;                                   /* 4 x 128 frames x 4 slots x 2 bytes = 4 KB of internal DMA memory */
    cc.dma_frame_num = 128;
    if (i2s_new_channel(&cc, NULL, &mic) != ESP_OK) return false;
    i2s_tdm_config_t tc = {
        .clk_cfg = I2S_TDM_CLK_DEFAULT_CONFIG((uint32_t)rate),
        .slot_cfg = I2S_TDM_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO,
                                                        I2S_TDM_SLOT0 | I2S_TDM_SLOT1 | I2S_TDM_SLOT2 | I2S_TDM_SLOT3),
        .gpio_cfg = {.mclk = MIC_MCLK, .bclk = MIC_SCK, .ws = MIC_LRCK, .dout = I2S_GPIO_UNUSED, .din = MIC_DIN},
    };
    tc.clk_cfg.mclk_multiple = I2S_MCLK_MULTIPLE_256;
    if (i2s_channel_init_tdm_mode(mic, &tc) != ESP_OK || i2s_channel_enable(mic) != ESP_OK) goto fail;
    audio_codec_i2c_cfg_t ic = {.port = 0, .addr = ES7210_CODEC_DEFAULT_ADDR, .bus_handle = board_i2c_bus()};
    const audio_codec_ctrl_if_t *ctrl = audio_codec_new_i2c_ctrl(&ic);
    es7210_codec_cfg_t ec = {.ctrl_if = ctrl, .master_mode = false,
                             .mic_selected = ES7210_SEL_MIC1 | ES7210_SEL_MIC2 | ES7210_SEL_MIC3 | ES7210_SEL_MIC4};
    const audio_codec_if_t *codec = ctrl ? es7210_codec_new(&ec) : NULL;
    audio_codec_i2s_cfg_t dc = {.port = 1, .rx_handle = mic};
    const audio_codec_data_if_t *data = audio_codec_new_i2s_data(&dc);
    esp_codec_dev_cfg_t dev = {.dev_type = ESP_CODEC_DEV_TYPE_IN, .codec_if = codec, .data_if = data};
    if (!codec || !data || !(mic_dev = esp_codec_dev_new(&dev))) goto fail;
    esp_codec_dev_sample_info_t fs = {.bits_per_sample = 16, .channel = 4, .channel_mask = 0xF, .sample_rate = (uint32_t)rate};
    if (esp_codec_dev_open(mic_dev, &fs) != ESP_CODEC_DEV_OK) goto fail;
    esp_codec_dev_set_in_gain(mic_dev, 24.0f);
    if (!mic_buf) mic_buf = heap_caps_malloc(4 * 2 * 1152, MALLOC_CAP_SPIRAM);   /* a copy target only: PSRAM is fine */
    if (!mic_buf) goto fail;
    return true;
fail:
    audio_in_stop();
    return false;
}

int audio_in_read(int16_t *pcm, int n) {
    if (!mic_dev) return 0;
    if (n > 1152) n = 1152;
    if (esp_codec_dev_read(mic_dev, mic_buf, n * 8) != ESP_CODEC_DEV_OK) return 0;
    for (int k = 0; k < n; ++k) pcm[k] = mic_buf[4 * k + mic_slot];
    return n;
}

void audio_in_diag(int *id_hi, int *id_lo, int16_t *raw8) {
    *id_hi = *id_lo = -1;
    if (!mic_dev) return;
    esp_codec_dev_read_reg(mic_dev, 0x3D, id_hi);
    esp_codec_dev_read_reg(mic_dev, 0x3E, id_lo);
    for (int k = 0; k < 8; ++k) raw8[k] = mic_buf[k];
}

void audio_in_stop(void) {
    if (mic_dev) { esp_codec_dev_close(mic_dev); esp_codec_dev_delete(mic_dev); mic_dev = NULL; }
    if (mic) { i2s_channel_disable(mic); i2s_del_channel(mic); mic = NULL; }
}
