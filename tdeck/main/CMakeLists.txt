idf_component_register(SRCS "main.c" "rf_s3.c" "rx_core1.c" "tx_test.c" "board.c" "gfx.c" "ui.c" "settings.c" "radio.c" "tx_core1.c" "rx_pipe.c" "av_tx.c" "av_rx.c" "audio_io.c"
                       INCLUDE_DIRS "." "../../firmware/main"
                       REQUIRES esp_phy esp_wifi nvs_flash esp_timer esp_driver_usb_serial_jtag esp_rom
                                esp_lcd esp_driver_spi esp_driver_i2c esp_driver_gpio esp_psram datv_core espressif__esp_h264 espressif__esp_codec_dev esp_driver_i2s)
# Build-time check that static data and IRAM stay below the RF sample banks (see bank_guard.ld).
target_link_libraries(${COMPONENT_LIB} INTERFACE "${CMAKE_CURRENT_LIST_DIR}/bank_guard.ld")
