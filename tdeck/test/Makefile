# Native tests of components/datv_core: make -C tdeck/test
CORE := ../components/datv_core
CFLAGS ?= -O2 -g -Wall -Wextra -Wno-unused-parameter -std=gnu11 -I$(CORE)/include -I$(CORE)/third_party/minimp3 -fsanitize=address,undefined
SRC := $(wildcard $(CORE)/src/*.c)
test_core: test_core.c sha256.c $(SRC) $(wildcard $(CORE)/include/datv/*.h)
	$(CC) $(CFLAGS) -o $@ test_core.c sha256.c $(SRC) -lm
# the MP2 tests again with the single-precision encoder used on the ESP32-S3
test_core_f: test_core.c sha256.c $(SRC) $(wildcard $(CORE)/include/datv/*.h)
	$(CC) $(CFLAGS) -DMP2ENC_FLOAT=1 -o $@ test_core.c sha256.c $(SRC) -lm
run: test_core test_core_f
	./test_core ../../app/test/fixtures/dvb_goldens.json
	./test_core_f
clean:
	rm -f test_core test_core_f
.PHONY: run clean
