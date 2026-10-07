import 'package:esp32_datv/core/codec/image/convert.dart';
import 'package:esp32_datv/core/codec/image/font5x7.dart';
import 'package:test/test.dart';

void main() {
  test('accented letters use the base letter, others become ?', () {
    expect(glyph5x7('á'), glyph5x7('a'));
    expect(glyph5x7('Ł'), glyph5x7('L'));
    expect(glyph5x7('中'), glyph5x7('?'));
  });

  test('the text changes the picture only in the bar area, and empty text changes nothing', () {
    final plain = testPattern(320, 180, 7, 15);
    final empty = testPattern(320, 180, 7, 15, text: '   ');
    final withText = testPattern(320, 180, 7, 15, text: 'CT1ABC');
    expect(empty.y, plain.y);
    var changed = 0, below = 0;
    for (var i = 0; i < plain.y.length; i++) {
      if (plain.y[i] != withText.y[i]) {
        changed++;
        if (i ~/ 320 >= 120) below++;
      }
    }
    expect(changed, greaterThan(500));
    expect(below, 0);
  });
}
