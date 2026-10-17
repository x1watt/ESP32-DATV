# Portable DATV code (no ESP-IDF dependencies): also built natively by tdeck/test.
idf_component_register(SRCS "src/dvbs_tx.c" "src/dvbs_common.c" "src/rs.c" "src/viterbi.c" "src/dvbs_rx.c" "src/font5x7.c" "src/frame.c" "src/demod.c" "src/ts.c" "src/mp2enc.c" "src/mp2dec.c"
                       INCLUDE_DIRS "include"
                       PRIV_INCLUDE_DIRS "third_party/minimp3")
# The S3 has no double FPU: run the MP2 encoder in single precision there (the native tests cover both).
target_compile_definitions(${COMPONENT_LIB} PUBLIC MP2ENC_FLOAT=1)
