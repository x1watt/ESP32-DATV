#!/bin/sh
# Dev-only: generates H.264 test streams with system ffmpeg + libx264 from
# the sintel trailer into the directory given as $1 (not committed).
set -e
OUT=${1:?output dir}
SRC=${2:-$(dirname "$0")/../../../media/sintel_trailer.mp4}
mkdir -p "$OUT"
enc() {
  name=$1; shift
  ffmpeg -v error -y -ss 20 -i "$SRC" -t 3 -an "$@" -f h264 "$OUT/$name.h264"
}
enc baseline_cavlc   -vf scale=320:180 -c:v libx264 -profile:v baseline -x264-params keyint=30:ref=3
enc main_cabac_b     -vf scale=320:180 -c:v libx264 -profile:v main -x264-params bframes=3:b-pyramid=none:weightb=1:weightp=2:ref=3:keyint=40
enc main_cavlc_b     -vf scale=320:180 -c:v libx264 -profile:v main -x264-params cabac=0:bframes=2:weightb=1:weightp=1:ref=2
enc high_8x8_cqm     -vf scale=320:180 -c:v libx264 -profile:v high -x264-params 8x8dct=1:cqm=jvt:bframes=3:ref=4
enc high_slices      -vf scale=320:180 -c:v libx264 -profile:v high -x264-params slices=4:bframes=2:ref=2
enc odd_202x118      -vf scale=202:118 -c:v libx264 -profile:v high -x264-params bframes=3:ref=3
enc bpyramid_spatial -vf scale=320:180 -c:v libx264 -profile:v high -x264-params bframes=5:b-pyramid=normal:direct=spatial:ref=5:weightb=1
enc bpyramid_temporal -vf scale=320:180 -c:v libx264 -profile:v high -x264-params bframes=4:b-pyramid=normal:direct=temporal:ref=4
enc constrained_intra -vf scale=320:180 -c:v libx264 -profile:v main -x264-params constrained-intra=1:bframes=2
enc high_cqm_cavlc   -vf scale=320:180 -c:v libx264 -profile:v high -x264-params cabac=0:8x8dct=1:cqm=jvt:bframes=2
enc no_deblock_cabac -vf scale=320:180 -c:v libx264 -profile:v high -x264-params no-deblock=1:bframes=2
enc deblock_offsets  -vf scale=320:180 -c:v libx264 -profile:v high -x264-params deblock=-3,3:bframes=2
enc lowqp_cabac      -vf scale=320:180 -c:v libx264 -profile:v high -qp 2 -x264-params bframes=2
enc highqp_cabac     -vf scale=320:180 -c:v libx264 -profile:v high -qp 51 -x264-params bframes=2
enc baseline_slices_dbidc2 -vf scale=320:180 -c:v libx264 -profile:v baseline -x264-params slices=3:no-deblock=0
enc interlaced_tff   -vf scale=320:240 -c:v libx264 -profile:v high -x264-params tff=1
ls -la "$OUT"
