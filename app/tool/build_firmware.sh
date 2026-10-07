#!/usr/bin/env bash
# Builds ../firmware with ESP-IDF and installs the images into an app firmware bundle
# (default assets/firmware), writing manifest.json with offsets and MD5 sums.
#
#   tool/build_firmware.sh [IDF_PATH] [OUT_DIR]
# IDF_PATH defaults to $IDF_PATH (ESP-IDF 5.5 or later; the app bundle is built with 6.1).
set -euo pipefail
APP=$(cd "$(dirname "$0")/.." && pwd)
FW=$(cd "$APP/../firmware" && pwd)
IDF=${1:-${IDF_PATH:?set IDF_PATH or pass the ESP-IDF directory}}
OUT=${2:-$APP/assets/firmware}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp -r "$FW/CMakeLists.txt" "$FW/main" "$FW/sdkconfig.defaults" "$WORK/"
(
  cd "$WORK"
  # shellcheck disable=SC1091
  . "$IDF/export.sh" > /dev/null
  idf.py set-target esp32c3 > /dev/null
  idf.py build > build.log 2>&1 || { tail -30 build.log; exit 1; }
)
IDF_VER=$(cd "$IDF" && git describe --tags 2>/dev/null || cat "$IDF/version.txt")
COMMIT=$(git -C "$FW" rev-parse --short HEAD)$(git -C "$FW" diff --quiet -- . || echo "-dirty")
mkdir -p "$OUT"
B=$WORK/build
cp "$B/bootloader/bootloader.bin" "$B/partition_table/partition-table.bin" "$B/esp32_datv.bin" "$OUT/"
INFO=$(grep -o 'ESP32DATV [0-9]*' "$FW/main/main.c" | head -1)
VER=${INFO#ESP32DATV }
md5() { md5sum "$OUT/$1" | cut -d' ' -f1; }
cat > "$OUT/manifest.json" <<JSON
{
  "chip": "esp32c3",
  "info": "$INFO",
  "version": $VER,
  "source_commit": "$COMMIT",
  "idf": "$IDF_VER",
  "flash_mode": "dio",
  "flash_freq": "80m",
  "flash_size": "4MB",
  "images": [
    {"file": "bootloader.bin", "offset": 0, "md5": "$(md5 bootloader.bin)"},
    {"file": "partition-table.bin", "offset": 32768, "md5": "$(md5 partition-table.bin)"},
    {"file": "esp32_datv.bin", "offset": 65536, "md5": "$(md5 esp32_datv.bin)"}
  ]
}
JSON
echo "Firmware $INFO from $COMMIT built with ESP-IDF $IDF_VER into $OUT"
