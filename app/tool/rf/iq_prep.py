#!/usr/bin/env python3
"""Dev-only (needs numpy): HackRF s8 IQ -> leandvb u8 IQ. Moves the signal to 0 Hz (coarse
shift plus a measured offset, since the HackRF and ESP crystals differ by tens of kHz) and
decimates to about 4 samples per symbol.

    iq_prep.py in.s8 out.u8 <sample rate> <shift Hz> <symbol rate>   -> prints the output rate
"""
import sys
import numpy as np

src, dst, fs, shift, baud = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
d = np.fromfile(src, dtype=np.int8).astype(np.float32)
z = d[0::2] + 1j * d[1::2]
z *= np.exp(2j * np.pi * shift / fs * np.arange(len(z)))
n = 8192
p = np.mean([np.abs(np.fft.fftshift(np.fft.fft(z[i:i + n]))) ** 2 for i in range(0, min(len(z), 4_000_000) - n, n)], axis=0)
f = (np.arange(n) - n / 2) * fs / n
m = np.abs(f) < 0.8 * baud
w = p[m] - np.median(p)
w[w < 0] = 0
off = float(np.sum(f[m] * w) / np.sum(w))
z *= np.exp(-2j * np.pi * off / fs * np.arange(len(z)))
dec = max(1, int(fs / (4 * baud)))
if dec > 1:
    h = np.sinc(np.arange(-64, 65) / dec) * np.hamming(129)
    z = np.convolve(z, h / h.sum(), "same")[::dec]
g = 40 / np.sqrt(np.mean(np.abs(z) ** 2))
np.clip(np.round(np.stack([z.real, z.imag], 1).ravel() * g + 128), 0, 255).astype(np.uint8).tofile(dst)
print(fs / dec)
sys.stderr.write("offset %.1f kHz, decimation %d\n" % (off / 1e3, dec))
