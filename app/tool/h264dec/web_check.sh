#!/bin/sh
# Dev-only: checks that the decoder gives identical output when compiled to
# JavaScript (dart2js integer semantics differ from native). Decodes the
# committed fixtures under node and compares a hash with the native run.
# Requires node. Run from app/: tool/h264dec/web_check.sh
set -e
cd "$(dirname "$0")/../.."
ENTRY=tool/h264dec/_web_check_entry.dart
TMP=$(mktemp -d)
trap 'rm -rf "$TMP" "$ENTRY"' EXIT
{
  echo "import 'dart:convert';"
  echo "import 'package:esp32_datv/core/codec/h264dec/h264dec.dart';"
  echo "const streams = <String>["
  for f in test/h264dec/fixtures/*.h264; do echo "  '$(base64 -w0 "$f")',"; done
  echo "];"
  cat <<'DART'
void main() {
  for (final s in streams) {
    final d = H264Decoder();
    final fr = d.decode(base64Decode(s)) + d.flush();
    var h = 0;
    for (final f in fr) {
      for (final p in [f.y, f.u, f.v]) {
        for (final v in p) {
          h = (h * 31 + v) & 0xFFFFFF;
        }
      }
    }
    print('${fr.length} frames, errors ${d.errorCount}, hash $h');
  }
}
DART
} > "$ENTRY"
dart run "$ENTRY" 2>/dev/null | grep frames > "$TMP/native.txt"
dart compile js -O2 "$ENTRY" -o "$TMP/out.js" > /dev/null
(echo "var self = globalThis;"; cat "$TMP/out.js") > "$TMP/run.js"
node "$TMP/run.js" > "$TMP/js.txt"
cat "$TMP/native.txt"
if cmp -s "$TMP/native.txt" "$TMP/js.txt"; then echo "WEB OK: JavaScript output identical"; else echo "WEB MISMATCH:"; cat "$TMP/js.txt"; exit 1; fi
