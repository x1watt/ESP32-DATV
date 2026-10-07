/* Linked as an implicit linker script (see main/CMakeLists.txt). The RF block writes its
   DAC/dump bank at 0x3FCA0000..0x3FCBFFFF (SOC_RESERVE_MEMORY_REGION in main.c), so no
   static data may reach it: with ESP-IDF 5.x and default IRAM placement .bss used to end
   inside it and the board aborted at boot. Fail the build instead. */
ASSERT(_bss_end <= 0x3FCA0000, "ESP32-DATV: .bss reaches the RF dump bank at 0x3FCA0000; move code out of IRAM (sdkconfig.defaults) or shrink static data")
