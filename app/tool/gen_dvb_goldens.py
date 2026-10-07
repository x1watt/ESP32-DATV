#!/usr/bin/env python3
"""Dev-only: writes test/fixtures/dvb_goldens.json with sha256 hashes of the reference Python
encoders (host/dvbs.py, host/dvbs2.py) for every mode. Needs numpy. The app never runs this.

    python3 tool/gen_dvb_goldens.py        (from app/)
"""
import hashlib, json, os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "host"))
import dvbs, dvbs2  # noqa: E402


def golden_ts(n):
    x = 0x2545F491
    out = bytearray()
    for _ in range(n):
        out.append(0x47)
        for _ in range(187):
            x ^= (x << 13) & 0xFFFFFFFF
            x ^= x >> 17
            x ^= (x << 5) & 0xFFFFFFFF
            out.append(x >> 11 & 255)
    return bytes(out)


def h(b):
    return hashlib.sha256(b).hexdigest()


ts = golden_ts(400)
res = {"packets": 400, "dvbs": {}, "dvbs2": []}
for fec in dvbs.PUNCT:
    for swap, inv in ((False, False), (True, False), (False, True)):
        e = dvbs.Encoder(fec, swap_iq=swap, invert=inv)
        out = e.encode(ts[:188 * 7]) + e.encode(ts[188 * 7:])
        res["dvbs"][f"{fec}|{int(swap)}|{int(inv)}"] = h(out)
for mod in ("qpsk", "8psk", "16apsk"):
    for frame in ("normal", "short"):
        for fec in dvbs2.rates(mod, frame):
            for pil in (False, True):
                variants = [(False, False, False)]
                if fec == dvbs2.rates(mod, frame)[0]:
                    variants += [(True, False, False), (False, True, False)]
                if mod == "8psk":
                    variants += [(False, False, True)]
                for swap, inv, b3 in variants:
                    e = dvbs2.Encoder(fec, frame, pil, swap_iq=swap, invert=inv, mod=mod, bits3=b3)
                    out = e.frames(ts)
                    res["dvbs2"].append(dict(mod=mod, frame=frame, fec=fec, pilots=pil, swap=swap,
                                             invert=inv, bits3=b3, len=len(out), sha256=h(out)))
json.dump(res, open(os.path.join(os.path.dirname(__file__), "..", "test", "fixtures", "dvb_goldens.json"), "w"), indent=1)
print(len(res["dvbs2"]), "dvbs2 goldens")
