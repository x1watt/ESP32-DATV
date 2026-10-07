#!/usr/bin/env python3
"""Dev-only: test/fixtures/plan_goldens.json from host/tx_dvbs.py (sps, actual baud, capacity, budget)."""
import json, os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "host"))
import dvbs, dvbs2, tx_dvbs as t  # noqa: E402

out = []
rates = [2000, 10000, 33000, 50000, 66000, 100000, 125000, 200000, 250000, 300000, 333000, 400000, 500000, 750000, 1000000]
for mod in ("qpsk", "8psk", "16apsk"):
    for baud in rates:
        try:
            sps = t.auto_sps_16apsk(baud) if mod == "16apsk" else t.auto_sps_8psk(baud) if mod == "8psk" else t.auto_sps(baud)
        except SystemExit:
            out.append(dict(mod=mod, baud=baud, error=True)); continue
        ba = t.output_baud(baud, sps, mod)
        fec = {"qpsk": "1/2", "8psk": "3/5", "16apsk": "2/3"}[mod]
        cap = dvbs2.ts_rate(ba, fec, "normal", False, mod)
        capS = dvbs.ts_rate(ba, "1/2") if mod == "qpsk" else None
        mux = int(cap * 0.965)
        if mux >= 600_000: aud, fps, w, pat = 96, 25, 640, 0.2
        elif mux >= 200_000: aud, fps, w, pat = 32, 15, 320, 0.5
        else: aud, fps, w, pat = (8 if mux < 40_000 else 16), 10, 160, 1.0
        psi = int(3 * 188 * 8 / pat)
        vb = int((mux - aud * 1000 - psi) * 0.88)
        out.append(dict(mod=mod, baud=baud, fec=fec, sps=sps, baud_act=ba, cap=cap, cap_dvbs=capS, mux=mux, aud=aud, fps=fps, w=w, vb=vb))
json.dump(out, open(os.path.join(os.path.dirname(__file__), "..", "test", "fixtures", "plan_goldens.json"), "w"), indent=1)
print(len(out))
