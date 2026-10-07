#!/usr/bin/env bash
# Dev-only over-the-air check (not part of the app): transmits the test pattern with an AOT
# build of tool/hw/e2e.dart, records it with a HackRF, demodulates it with leandvb and checks
# the transport stream with ffprobe/ffmpeg. Needs hackrf_transfer, python3 with numpy, ffmpeg,
# leandvb from leansdr (DVB-S: branch master; DVB-S2: branch "work" built with
# -DLEANSDR_EXTENSIONS). 16APSK cannot be checked this way: leandvb does not decode it.
#
#   LEANDVB=... LEANDVB_S2=... tool/rf/ota_check.sh <port> <dvbs|qpsk|8psk> <baud> <fec> [outdir]
set -euo pipefail
PORT=$1 MODE=$2 BAUD=$3 FEC=$4 OUT=${5:-/tmp/ota_check}
APP=$(cd "$(dirname "$0")/../.." && pwd)
FREQ=2370000000 OFF=500000 SR=4000000
mkdir -p "$OUT"
[ -x "$OUT/e2e" ] || dart compile exe "$APP/tool/hw/e2e.dart" -o "$OUT/e2e" > /dev/null
"$OUT/e2e" "$PORT" "$MODE" "$BAUD" 30 "$FEC" > "$OUT/tx.log" 2>&1 &
TX=$!
sleep 9
hackrf_transfer -r "$OUT/cap.s8" -f $((FREQ + OFF)) -s $SR -n $((SR * 6)) -l 40 -g 16 -a 0 > /dev/null 2>&1
FS=$(python3 "$APP/tool/rf/iq_prep.py" "$OUT/cap.s8" "$OUT/cap.u8" $SR $OFF "$BAUD")
if [ "$MODE" = dvbs ]; then
  "${LEANDVB:-leandvb}" --u8 -f "$FS" --sr "$BAUD" --cr "$FEC" --viterbi < "$OUT/cap.u8" > "$OUT/rx.ts" 2> /dev/null || true
else
  "${LEANDVB_S2:-leandvb}" --u8 -f "$FS" --sr "$BAUD" --fastlock --standard DVB-S2 \
    --const "$(echo "$MODE" | tr a-z A-Z)" --ldpc-bf 400 < "$OUT/cap.u8" > "$OUT/rx.ts" 2> /dev/null || true
fi
wait $TX || true
python3 - "$OUT/rx.ts" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read(); n = len(d) // 188; cc = {}; gaps = 0; bad = 0
for i in range(n):
    p = d[i*188:(i+1)*188]
    if p[0] != 0x47 or p[1] & 0x80: bad += 1; continue
    pid = (p[1] & 31) << 8 | p[2]
    if pid != 0x1FFF and p[3] & 0x10:
        c = p[3] & 15
        if pid in cc and c not in ((cc[pid] + 1) & 15, cc[pid]): gaps += 1
        cc[pid] = c
print(f"TS packets {n}, corrupted {bad}, continuity gaps {gaps}")
PY
echo "video frames: $(ffprobe -v quiet -count_frames -select_streams v -show_entries stream=nb_read_frames -of csv=p=0 "$OUT/rx.ts" | head -1)"
echo "decoder errors (frames before the first IDR excluded): $(ffmpeg -v error -i "$OUT/rx.ts" -f null - 2>&1 | grep -c -v -E 'non-existing PPS|decode_slice_header|no frame|Last message' || true)"
