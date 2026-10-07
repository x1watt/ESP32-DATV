/// True when compiled to JavaScript, where ints are doubles and the bitwise
/// operators work on unsigned 32-bit values (so `-2 >> 1` is 2147483647).
const bool kIsJs = identical(0, 0.0);

/// Arithmetic shift right (floor division by 2^n) that is also correct for
/// negative values when compiled to JavaScript. On native platforms this is
/// a plain `>>`. Valid for x >= -2^30.
@pragma('vm:prefer-inline')
@pragma('dart2js:prefer-inline')
int asr(int x, int n) => kIsJs ? ((x + 0x40000000) >> n) - (0x40000000 >> n) : x >> n;
