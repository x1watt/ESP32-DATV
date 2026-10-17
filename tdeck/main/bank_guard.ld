/* Linked as an implicit linker script (see main/CMakeLists.txt). The RF block reads and writes
   its sample banks at 0x3FCB0000..0x3FCDFFFF (SOC_RESERVE_MEMORY_REGION in rf_s3.c). IRAM and
   DRAM share the same SRAM on the ESP32-S3 (IRAM address = DRAM address + 0x6F0000), so neither
   static data nor IRAM code may reach it. Fail the build instead of corrupting samples. */
ASSERT(_bss_end <= 0x3FCB0000, "TDECK-DATV: .bss reaches the RF sample banks at 0x3FCB0000")
ASSERT(_iram_end <= 0x403A0000, "TDECK-DATV: IRAM reaches the RF sample banks at 0x403A0000")
