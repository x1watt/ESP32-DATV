#include "datv/dvbs.h"

const dvbs_punct_t dvbs_punct[DVBS_FEC_COUNT] = {
    {1, {1}, {1}, 1, 2},
    {2, {1, 0}, {1, 1}, 2, 3},
    {3, {1, 0, 1}, {1, 1, 0}, 3, 4},
    {5, {1, 0, 1, 0, 1}, {1, 1, 0, 1, 0}, 5, 6},
    {7, {1, 0, 0, 0, 1, 0, 1}, {1, 1, 1, 1, 0, 1, 0}, 7, 8},
};

const char *const dvbs_fec_name[DVBS_FEC_COUNT] = {"1/2", "2/3", "3/4", "5/6", "7/8"};

double dvbs_ts_rate(double baud, dvbs_fec_t fec) {
    return baud * 2.0 * dvbs_punct[fec].num / dvbs_punct[fec].den * DVBS_PKT / DVBS_CW;
}

const uint8_t *dvbs_prbs(void) {
    static uint8_t out[1503];
    static bool done;
    if (!done) {
        uint32_t reg = 0;              /* bit k = stage k + 1 */
        static const uint8_t init[15] = {1, 0, 0, 1, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0};
        for (int k = 0; k < 15; ++k) reg |= (uint32_t)init[k] << k;
        for (int i = 0; i < 1503 * 8; ++i) {
            const uint32_t o = ((reg >> 13) ^ (reg >> 14)) & 1u;
            reg = ((reg << 1) | o) & 0x7FFFu;
            if (o) out[i >> 3] |= 0x80u >> (i & 7);
        }
        done = true;
    }
    return out;
}
