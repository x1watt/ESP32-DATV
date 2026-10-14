/* Burst receiver (included by main.c after tune() and the USB helpers).
 *
 * The radio's sample-dump engine (librftest adctrig) writes complex samples into the RF dump
 * bank at 0x3FCB0000: one 32-bit word per pair, I in bits 0..9 and Q in bits 10..19 (signed
 * 10 bit), the receiver gain index in bits 20..27 (format register 0x60033D90 = 0x000C2040, as
 * found by eSpDR and ESP-SDR). The CPU cannot read the bank while the engine writes it without
 * losing samples, so reception is a series of bursts:
 *   80 MS/s  one snapshot of up to 16380 pairs (205 us)
 *   16 MS/s  the circular mode runs for a little more than one ring (16383 pairs, 1.02 ms) and
 *            is stopped; the ring is sent oldest pair first
 * Each burst is sent as  RXDATA n rate lo_hz gain crc32\r\n  followed by n pairs packed in
 * 20 bits each (two pairs in five bytes, little-endian: I0 Q0 I1 Q1), crc32 over the packed bytes.
 */

#define DUMP_CTRL   0x60033D5Cu   /* bit 31 run, 19 trigger, 18 done, 17 circular, 16 16 MS/s, low bits length */
#define DUMP_INDEX  0x60033D60u   /* write index */
#define DUMP_CONFIG 0x60033D90u
#define DUMP_CONFIG_IQ 0x000C2040u
#define RX_RING 16383u
#define RX_MAX_SNAPSHOT 16380u

extern uint32_t esp_rom_crc32_le(uint32_t crc, const uint8_t *buf, uint32_t len);

static uint32_t rx_tuned_khz;
static int rx_gain = -1;            /* -1: hardware AGC, else a fixed gain table index */

/* Highest calibrated receive gain table index (AGC power control register, bits 8..14). */
static unsigned rx_gain_max(void) {
    const unsigned m = (rd(0x6001C02Cu) >> 8) & 127u;
    return m < 80u ? m : 0u;
}

static void rx_gain_apply(void) {
    if (rx_gain < 0) force_rx_gain(0, 40, 0);
    else force_rx_gain(1, (unsigned)rx_gain, 0);
}

/* Tunes before every burst: between bursts the Wi-Fi driver may run and move the radio back to
   its own channel (the transmit loops never yield, so they are not affected). */
static bool rx_prepare(uint32_t fkhz) {
    tune_quiet = fkhz == rx_tuned_khz;
    const bool ok = tune(fkhz);
    tune_quiet = false;
    if (!ok) return false;
    rx_tuned_khz = fkhz;
    rx_gain_apply();
    return true;
}

/* One burst into the bank; returns the number of pairs, 0 on failure. *first is the ring index of the oldest pair. */
static uint32_t rx_capture(unsigned rate, uint32_t n, uint32_t *first) {
    volatile uint32_t *const bank = DAC_BUF;           /* the same 0x3FCB0000 bank as the DAC replay */
    taskENTER_CRITICAL(&stream_mux);
    const uint32_t owner0 = rd(SRAM_OWNER), config0 = rd(DUMP_CONFIG);
    wr(DUMP_CTRL, 0);
    wr(DUMP_CONFIG, DUMP_CONFIG_IQ);
    wr(SRAM_OWNER, (owner0 & ~7u) | 2u | 8u);
    __asm__ volatile("fence rw,rw" ::: "memory");
    uint32_t got = 0;
    const uint32_t t0 = ccount();
    if (rate == 80) {
        const uint32_t ctrl = n;
        wr(DUMP_CTRL, ctrl | (1u << 31));
        wr(DUMP_CTRL, ctrl | (1u << 31) | (1u << 19));
        wr(DUMP_CTRL, ctrl | (1u << 31));
        while (!(rd(DUMP_CTRL) & (1u << 18)) && ccount() - t0 < CPU_HZ / 50) {}
        if (rd(DUMP_CTRL) & (1u << 18)) got = n;
        *first = 0;
    } else {
        const uint32_t ctrl = (1u << 17) | (1u << 16) | RX_RING;
        wr(DUMP_CTRL, ctrl);
        wr(DUMP_CTRL, ctrl | (1u << 31));
        /* a little more than one ring: 1.02 ms of pairs plus a margin */
        while (ccount() - t0 < CPU_HZ / 1000u * 12u / 10u) {}
        const uint32_t w = rd(DUMP_INDEX) & 0x7fffu;
        wr(DUMP_CTRL, ctrl);
        got = RX_RING;
        *first = w % RX_RING;                              /* the next slot to write holds the oldest pair */
    }
    wr(DUMP_CTRL, 0);
    wr(DUMP_CONFIG, config0);
    wr(SRAM_OWNER, owner0);
    __asm__ volatile("fence rw,rw" ::: "memory");
    taskEXIT_CRITICAL(&stream_mux);
    (void)bank;
    return got;
}

/* Packs n pairs (ring order from `first`) in place into 20-bit pairs and sends the burst. */
static bool rx_send(unsigned rate, uint32_t n, uint32_t first) {
    volatile uint32_t *const bank = DAC_BUF;
    const uint32_t ring = rate == 80 ? n : RX_RING;
    const uint32_t gain = (bank[first] >> 20) & 0xffu;
    /* the packed data (2.5 bytes per pair) is written to a heap buffer in chunks and sent */
    static uint8_t chunk[2560];                         /* 1024 pairs */
    uint32_t crc = 0, sent = 0, done = 0;
    /* first pass: crc; second pass: send. Packing twice is cheaper than holding 41 KB. */
    for (int pass = 0; pass < 2; pass++) {
        if (pass == 1) say("RXDATA %u %u %.0f %u %08x\r\n", (unsigned)n, rate, lo_hz, (unsigned)gain, (unsigned)crc);
        done = 0;
        uint32_t idx = first;
        while (done < n) {
            uint32_t m = n - done > 1024u ? 1024u : n - done;
            m &= ~1u;
            if (!m) m = n - done;                          /* an odd last pair */
            uint8_t *p = chunk;
            for (uint32_t j = 0; j < m; j += 2) {
                const uint32_t a = bank[idx] & 0xfffffu;
                idx = idx + 1 == ring ? 0 : idx + 1;
                uint32_t b = 0;
                if (j + 1 < m) { b = bank[idx] & 0xfffffu; idx = idx + 1 == ring ? 0 : idx + 1; }
                p[0] = a; p[1] = a >> 8; p[2] = (a >> 16) | (b << 4);
                if (j + 1 < m) { p[3] = b >> 4; p[4] = b >> 12; p += 5; }
                else p += 3;
            }
            const uint32_t bytes = (uint32_t)(p - chunk);
            if (pass == 0) crc = esp_rom_crc32_le(crc, chunk, bytes);
            else { usb_write(chunk, bytes); sent += bytes; }
            done += m;
        }
    }
    (void)sent;
    return true;
}

static bool rx_parse(const char *args, uint32_t *fkhz, unsigned *rate, uint32_t *n) {
    char fs_[32], gs[16];
    unsigned long nn = 0, r = 0;
    const int k = sscanf(args, "%31s %lu %lu %15s", fs_, &r, &nn, gs);
    if (k < 3 || !parse_freq(fs_, fkhz) || (r != 16 && r != 80)) return false;
    if (r == 80 && (nn < 16 || nn > RX_MAX_SNAPSHOT)) return false;
    *rate = (unsigned)r;
    *n = r == 80 ? (uint32_t)nn : RX_RING;
    if (k == 4) {
        if (!strcmp(gs, "agc")) rx_gain = -1;
        else {
            char *e;
            long g = strtol(gs, &e, 10);
            if (*e || g < 0 || g > 127) return false;
            if (rx_gain_max() && g > (long)rx_gain_max()) g = rx_gain_max();
            rx_gain = (int)g;
        }
    }
    return true;
}

/* RX f_MHz rate n [agc|gain]: one burst.  RXSTREAM f_MHz rate n [agc|gain]: bursts until any byte from the host. */
static void rx_command(const char *line, bool stream) {
    uint32_t fkhz, n;
    unsigned rate;
    if (!rx_parse(line + (stream ? 9 : 3), &fkhz, &rate, &n)) {
        say("ERR RX|RXSTREAM f_MHz rate(16|80) n(16..16380 at 80; ignored at 16) [agc|gain 0..127]\r\n");
        return;
    }
    if (fkhz < 2200000 || fkhz > 2800000) { say("ERR RX 2200..2800 MHz\r\n"); return; }
    if (!rx_prepare(fkhz)) { say("ERR TUNE\r\n"); return; }
    usb_drain_rx();
    uint32_t bursts = 0;
    do {
        uint32_t first;
        if (bursts && !rx_prepare(fkhz)) { say("ERR TUNE\r\n"); return; }
        const uint32_t got = rx_capture(rate, n, &first);
        if (!got) { say("ERR RX capture timeout\r\n"); return; }
        rx_send(rate, got, first);
        bursts++;
        if (stream) {
            uint8_t c;
            if (usb_serial_jtag_ll_read_rxfifo(&c, 1)) break;
            vTaskDelay(1);
        }
    } while (stream);
    usb_drain_rx();
    if (stream) say("RX END bursts=%u\r\n", (unsigned)bursts);
}
