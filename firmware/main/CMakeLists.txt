idf_component_register(SRCS "main.c" "lut8.S" "lutg.S" "lutg_psk8.S" "lutg_p8s8.S" "lutg_a16.S" "lutg_a16s8.S"
                       REQUIRES esp_phy esp_wifi nvs_flash esp_timer esp_driver_usb_serial_jtag)
# Build-time check that static data stays below the RF dump bank (see bss_guard.ld).
target_link_libraries(${COMPONENT_LIB} INTERFACE "${CMAKE_CURRENT_LIST_DIR}/bss_guard.ld")
