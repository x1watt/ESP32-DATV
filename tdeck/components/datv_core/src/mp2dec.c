/* The minimp3 implementation, compiled once. Layer I/II stays enabled (no MINIMP3_ONLY_MP3) and SIMD is
 * off so the same code builds natively and for the ESP32-S3. */
#include "datv/mp2dec.h"

#define MINIMP3_IMPLEMENTATION
#define MINIMP3_NO_SIMD
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wsign-compare"
#pragma GCC diagnostic ignored "-Wunused-function"
#pragma GCC diagnostic ignored "-Wunused-parameter"
#pragma GCC diagnostic ignored "-Wmissing-field-initializers"
#pragma GCC diagnostic ignored "-Wimplicit-fallthrough"
#pragma GCC diagnostic ignored "-Wshadow"
#pragma GCC diagnostic ignored "-Wmaybe-uninitialized"
#include "minimp3.h"
#pragma GCC diagnostic pop

_Static_assert(sizeof(mp2dec_t) == sizeof(mp3dec_t), "mp2dec_t must mirror mp3dec_t");
_Static_assert(_Alignof(mp2dec_t) == _Alignof(mp3dec_t), "mp2dec_t must mirror mp3dec_t");

void mp2dec_init(mp2dec_t *d) { mp3dec_init((mp3dec_t *)d); }

int mp2dec_decode(mp2dec_t *d, const uint8_t *frame, size_t len, int16_t *pcm, int *channels, int *rate) {
    mp3dec_frame_info_t info;
    const int n = mp3dec_decode_frame((mp3dec_t *)d, frame, (int)len, pcm, &info);
    if (channels) *channels = n ? info.channels : 0;
    if (rate) *rate = n ? info.hz : 0;
    return n;
}
