import 'dart:typed_data';

import 'package:esp32_datv/core/codec/mp4/mp4.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mp4_test_util.dart';

final Uint8List kSps = Uint8List.fromList([0x67, 0x64, 0x00, 0x28, 0xAC, 0xD9]);
final Uint8List kPps = Uint8List.fromList([0x68, 0xEB, 0xE3, 0xCB]);
const List<int> kAsc = [0x11, 0x90]; // AAC LC, 48000 Hz, stereo

/// AVCC sample: one NAL unit with a 4 byte length prefix.
Uint8List videoSample(int i, int size, bool key) {
  final s = Uint8List(size);
  final nal = size - 4;
  s[0] = nal >> 24;
  s[1] = nal >> 16;
  s[2] = nal >> 8;
  s[3] = nal;
  s[4] = key ? 0x65 : 0x41;
  for (var k = 5; k < size; k++) {
    s[k] = (i * 7 + k) & 0xFF;
  }
  return s;
}

Uint8List audioSample(int i, int size) =>
    Uint8List.fromList(List<int>.generate(size, (k) => 0xA0 + i + k));

const List<int> vSizes = [20, 25, 30, 18, 22, 27];
const List<int> aSizes = [9, 12, 7, 15];
const List<bool> vKey = [true, false, false, true, false, false];
const List<int> vCto = [3000, 9000, -3000, 3000, 9000, -3000];

/// A plain (non fragmented) movie split into its mdat payload and a moov
/// that depends on where the payload starts.
class PlainParts {
  PlainParts(this.payload, this.moovFor, this.video, this.audio);
  final Uint8List payload;
  final Uint8List Function(int base) moovFor;
  final List<Uint8List> video;
  final List<Uint8List> audio;
}

PlainParts plainParts({
  String videoSizeBox = 'stsz',
  bool co64 = false,
  int cttsVersion = 1,
  bool audioStz2Nibbles = false,
}) {
  final video = [
    for (var i = 0; i < 6; i++) videoSample(i, vSizes[i], vKey[i]),
  ];
  final audio = [for (var i = 0; i < 4; i++) audioSample(i, aSizes[i])];
  // Layout: v0 | a0 a1 | v1 v2 | a2 a3 | v3 v4 v5
  final payload = concat([
    video[0],
    audio[0],
    audio[1],
    video[1],
    video[2],
    audio[2],
    audio[3],
    video[3],
    video[4],
    video[5],
  ]);
  int sum(List<int> l, int n) => l.take(n).fold(0, (a, b) => a + b);
  Uint8List moovFor(int base) {
    final vChunks = [
      base,
      base + vSizes[0] + aSizes[0] + aSizes[1],
      base + sum(vSizes, 3) + sum(aSizes, 4),
    ];
    final aChunks = [base + vSizes[0], base + sum(vSizes, 3) + sum(aSizes, 2)];
    final Uint8List vSizeTable = switch (videoSizeBox) {
      'stz2_8' => stz2(vSizes, 8),
      'stz2_16' => stz2(vSizes, 16),
      _ => stsz(vSizes),
    };
    final vTrak = trak(
      id: 1,
      handler: 'vide',
      timescale: 90000,
      duration: 18000,
      width: 320,
      height: 240,
      entry: avc1Entry(320, 240, avcC(kSps, kPps)),
      edit: edts(1, [(500, -1), (200, 3000)]),
      stblTables: [
        stts([(6, 3000)]),
        ctts(cttsVersion, [for (final c in vCto) (1, c)]),
        stsc([(1, 1), (2, 2), (3, 3)]),
        vSizeTable,
        stco(vChunks, co64: co64),
        stss([1, 4]),
      ],
    );
    final aTrak = trak(
      id: 2,
      handler: 'soun',
      timescale: 48000,
      duration: 4096,
      entry: mp4aEntry(2, 48000, kAsc),
      stblTables: [
        stts([(4, 1024)]),
        stsc([(1, 2)]),
        audioStz2Nibbles ? stz2(aSizes, 4) : stsz(aSizes),
        stco(aChunks, co64: co64),
      ],
    );
    return box('moov', [mvhd(1000, 700), vTrak, aTrak]);
  }

  return PlainParts(payload, moovFor, video, audio);
}

Uint8List mdatBox(Uint8List payload) => box('mdat', [payload]);

Uint8List plainFile(PlainParts p, {bool moovFirst = false}) {
  final f = ftyp();
  if (moovFirst) {
    final moovLen = p.moovFor(0).length;
    final base = f.length + moovLen + 8;
    return concat([f, p.moovFor(base), mdatBox(p.payload)]);
  }
  final base = f.length + 8;
  return concat([f, mdatBox(p.payload), p.moovFor(base)]);
}

class FragFile {
  FragFile(this.bytes, this.video, this.audio, this.vOffsets, this.aOffsets);
  final Uint8List bytes;
  final List<Uint8List> video;
  final List<Uint8List> audio;
  final List<int> vOffsets;
  final List<int> aOffsets;
}

FragFile fragmentedFile() {
  final video = [
    for (var i = 0; i < 6; i++) videoSample(i, vSizes[i], i == 0 || i == 3),
  ];
  final audio = [for (var i = 0; i < 4; i++) audioSample(i, i < 2 ? 10 : 6)];
  final emptyTables = [stts([]), stsc([]), stsz([]), stco([])];
  final moov = box('moov', [
    mvhd(1000, 0),
    trak(
      id: 1,
      handler: 'vide',
      timescale: 90000,
      duration: 0,
      width: 320,
      height: 240,
      entry: avc1Entry(320, 240, avcC(kSps, kPps)),
      stblTables: emptyTables,
    ),
    trak(
      id: 2,
      handler: 'soun',
      timescale: 48000,
      duration: 0,
      entry: mp4aEntry(2, 48000, kAsc),
      stblTables: emptyTables,
    ),
    box('mvex', [
      fullBox('trex', 0, 0, [
        bytesOf(
          (w) => w
            ..u32(1)
            ..u32(1)
            ..u32(3000)
            ..u32(0)
            ..u32(0x01010000),
        ),
      ]),
      fullBox('trex', 0, 0, [
        bytesOf(
          (w) => w
            ..u32(2)
            ..u32(1)
            ..u32(1024)
            ..u32(10)
            ..u32(0x02000000),
        ),
      ]),
    ]),
  ]);
  final head = concat([ftyp(), moov]);

  // moof 1: video with default-base-is-moof, audio with base-data-offset.
  Uint8List moof1(int moofStart, int dataStart) {
    final vBytes = vSizes[0] + vSizes[1] + vSizes[2];
    final vTraf = box('traf', [
      fullBox('tfhd', 0, 0x20000, [bytesOf((w) => w.u32(1))]),
      fullBox('tfdt', 1, 0, [bytesOf((w) => w.u64(0))]),
      fullBox('trun', 1, 0x1 | 0x4 | 0x200 | 0x800, [
        bytesOf((w) {
          w
            ..u32(3)
            ..u32(dataStart - moofStart)
            ..u32(0x02000000);
          const cto = [6000, -3000, 0];
          for (var i = 0; i < 3; i++) {
            w
              ..u32(vSizes[i])
              ..u32(cto[i] < 0 ? cto[i] + 4294967296 : cto[i]);
          }
        }),
      ]),
    ]);
    final aTraf = box('traf', [
      fullBox('tfhd', 0, 0x1 | 0x8, [
        bytesOf(
          (w) => w
            ..u32(2)
            ..u64(dataStart)
            ..u32(1024),
        ),
      ]),
      fullBox('tfdt', 0, 0, [bytesOf((w) => w.u32(0))]),
      fullBox('trun', 0, 0x1 | 0x200, [
        bytesOf(
          (w) => w
            ..u32(2)
            ..u32(vBytes)
            ..u32(10)
            ..u32(10),
        ),
      ]),
    ]);
    return box('moof', [
      fullBox('mfhd', 0, 0, [bytesOf((w) => w.u32(1))]),
      vTraf,
      aTraf,
    ]);
  }

  // moof 2: video without base flags and without tfdt, two truns; audio
  // without base flags (continues after the video data) and tfdt v0.
  Uint8List moof2(int moofStart, int dataStart) {
    final vTraf = box('traf', [
      fullBox('tfhd', 0, 0, [bytesOf((w) => w.u32(1))]),
      fullBox('trun', 0, 0x1 | 0x200 | 0x400, [
        bytesOf(
          (w) => w
            ..u32(2)
            ..u32(dataStart - moofStart)
            ..u32(vSizes[3])
            ..u32(0x02000000)
            ..u32(vSizes[4])
            ..u32(0x01010000),
        ),
      ]),
      fullBox('trun', 0, 0x200, [
        bytesOf(
          (w) => w
            ..u32(1)
            ..u32(vSizes[5]),
        ),
      ]),
    ]);
    final aTraf = box('traf', [
      fullBox('tfhd', 0, 0x10, [
        bytesOf(
          (w) => w
            ..u32(2)
            ..u32(6),
        ),
      ]),
      fullBox('tfdt', 0, 0, [bytesOf((w) => w.u32(2048))]),
      fullBox('trun', 0, 0, [bytesOf((w) => w.u32(2))]),
    ]);
    return box('moof', [
      fullBox('mfhd', 0, 0, [bytesOf((w) => w.u32(2))]),
      vTraf,
      aTraf,
    ]);
  }

  final m1Start = head.length;
  final m1Len = moof1(0, 0).length;
  final d1 = m1Start + m1Len + 8;
  final mdat1 = mdatBox(concat([...video.take(3), ...audio.take(2)]));
  final m2Start = d1 - 8 + mdat1.length;
  final m2Len = moof2(0, 0).length;
  final d2 = m2Start + m2Len + 8;
  final mdat2 = mdatBox(concat([...video.skip(3), ...audio.skip(2)]));
  final bytes = concat([
    head,
    moof1(m1Start, d1),
    mdat1,
    moof2(m2Start, d2),
    mdat2,
  ]);
  final vOff = <int>[];
  var o = d1;
  for (var i = 0; i < 3; i++) {
    vOff.add(o);
    o += vSizes[i];
  }
  final aOff = <int>[o, o + 10];
  o = d2;
  for (var i = 3; i < 6; i++) {
    vOff.add(o);
    o += vSizes[i];
  }
  aOff.addAll([o, o + 6]);
  return FragFile(bytes, video, audio, vOff, aOff);
}

Future<List<Mp4Sample>> collect(Stream<Mp4Sample> s) => s.toList();

void checkPlain(Mp4File f, PlainParts p) {
  expect(f.majorBrand, 'isom');
  expect(f.brands, ['isom', 'iso2', 'avc1', 'mp41']);
  expect(f.tracks.length, 2);
  final v = f.firstVideoTrack!;
  final a = f.firstAudioTrack!;
  expect(v.id, 1);
  expect(v.kind, Mp4TrackKind.video);
  expect(v.handler, 'vide');
  expect(v.sampleEntry, 'avc1');
  expect(v.codec, 'avc1.640028');
  expect(v.supported, isTrue);
  expect(v.width, 320);
  expect(v.height, 240);
  expect(v.timescale, 90000);
  expect(v.sampleCount, 6);
  expect(v.durationTs, 18000);
  expect(v.durationUs, 200000);
  expect(v.frameRate, closeTo(30, 1e-9));
  expect(
    v.avgBitrate,
    (vSizes.fold<int>(0, (a, b) => a + b) * 8 / 0.2).round(),
  );
  final avc = v.avc!;
  expect(avc.profileIdc, 100);
  expect(avc.levelIdc, 40);
  expect(avc.nalLengthSize, 4);
  expect(avc.sps.single, kSps);
  expect(avc.pps.single, kPps);
  expect(avc.chromaFormat, 1);
  expect(avc.bitDepthLuma, 8);
  expect(avc.bitDepthChroma, 8);
  expect(v.codecConfig, avc.raw);
  expect(v.emptyEditDelayUs, 500000);
  expect(v.editMediaTime, 3000);
  expect(v.presentationOffsetUs, 500000 - 33333);

  expect(a.id, 2);
  expect(a.kind, Mp4TrackKind.audio);
  expect(a.sampleEntry, 'mp4a');
  expect(a.codec, 'mp4a.40.2');
  expect(a.supported, isTrue);
  expect(a.sampleRate, 48000);
  expect(a.channels, 2);
  expect(a.audioObjectType, 2);
  expect(a.objectTypeIndication, 0x40);
  expect(a.audioSpecificConfig, kAsc);
  expect(a.codecConfig, kAsc);
  expect(a.presentationOffsetUs, 0);
  expect(a.frameRate, isNull);

  final vt = f.sampleTable(1);
  expect(vt.length, 6);
  for (var i = 0; i < 6; i++) {
    expect(vt[i].index, i);
    expect(vt[i].size, vSizes[i]);
    expect(vt[i].dts, i * 3000);
    expect(vt[i].cts, i * 3000 + vCto[i]);
    expect(vt[i].duration, 3000);
    expect(vt[i].isSync, vKey[i]);
  }
  final at = f.sampleTable(2);
  expect(at.map((s) => s.size).toList(), aSizes);
  expect(at.every((s) => s.isSync), isTrue);
}

void main() {
  group('plain', () {
    for (final moovFirst in [false, true]) {
      for (final sizeBox in ['stsz', 'stz2_8', 'stz2_16']) {
        for (final co64 in [false, true]) {
          test('moovFirst=$moovFirst $sizeBox co64=$co64', () async {
            final p = plainParts(
              videoSizeBox: sizeBox,
              co64: co64,
              audioStz2Nibbles: sizeBox != 'stsz',
            );
            final bytes = plainFile(p, moovFirst: moovFirst);
            final f = await Mp4File.open(MemoryByteSource(bytes));
            checkPlain(f, p);
            final vs = await collect(f.samples(1));
            for (var i = 0; i < 6; i++) {
              expect(vs[i].data, p.video[i]);
              expect(vs[i].index, i);
              expect(vs[i].isSync, vKey[i]);
              expect(vs[i].trackId, 1);
              expect(vs[i].durationUs, 33333);
              final dtsTicks = i * 3000 - 3000;
              expect(vs[i].dtsUs, mp4TicksToUs(dtsTicks, 90000) + 500000);
              expect(
                vs[i].ptsUs,
                mp4TicksToUs(dtsTicks + vCto[i], 90000) + 500000,
              );
              expect(
                bytes.sublist(vs[i].offset, vs[i].offset + vs[i].size),
                p.video[i],
              );
            }
            expect(vs[0].ptsUs, 500000);
            expect(vs[0].dtsUs, 466666);
            final as = await collect(f.samples(2));
            for (var i = 0; i < 4; i++) {
              expect(as[i].data, p.audio[i]);
              expect(as[i].dtsUs, mp4TicksToUs(i * 1024, 48000));
              expect(as[i].ptsUs, as[i].dtsUs);
            }
          });
        }
      }
    }

    test('ctts version 0 with negative stored offsets', () async {
      final p = plainParts(cttsVersion: 0);
      final f = await Mp4File.open(MemoryByteSource(plainFile(p)));
      checkPlain(f, p);
    });

    test('startIndex, readSample and seeking', () async {
      final p = plainParts();
      final f = await Mp4File.open(MemoryByteSource(plainFile(p)));
      final tail = await collect(f.samples(1, startIndex: 4));
      expect(tail.map((s) => s.index), [4, 5]);
      expect(tail[0].data, p.video[4]);
      final s = await f.readSample(2, 3);
      expect(s.data, p.audio[3]);
      expect(() => f.readSample(2, 4), throwsRangeError);
      final v = f.track(1);
      final t = f.sampleTable(1);
      expect(f.syncSampleAtOrBefore(1, 0), 0);
      expect(f.syncSampleAtOrBefore(1, v.ptsUsOf(t[3]) - 1), 0);
      expect(f.syncSampleAtOrBefore(1, v.ptsUsOf(t[3])), 3);
      expect(f.syncSampleAtOrBefore(1, 1 << 40), 3);
      expect(f.syncSampleAtOrBefore(2, v.ptsUsOf(t[3])), 3);
    });

    test('batched reads', () async {
      final p = plainParts();
      final src = CountingSource(MemoryByteSource(plainFile(p)));
      final f = await Mp4File.open(src);
      src.reads = 0;
      await collect(f.samples(1));
      expect(src.reads, 3); // three video chunks
      src.reads = 0;
      final all = await collect(f.interleaved());
      // a0a1, a2a3 (audio first since video starts at 0.4667 s), then the
      // three video chunks.
      expect(src.reads, 5);
      expect(all.length, 10);
      for (var i = 1; i < all.length; i++) {
        expect(all[i].dtsUs, greaterThanOrEqualTo(all[i - 1].dtsUs));
      }
      final onlyVideo = await collect(f.interleaved(trackIds: {1}));
      expect(onlyVideo.length, 6);
    });

    test('64-bit mdat and co64 offsets beyond 4 GiB', () async {
      final p = plainParts(co64: true);
      final f0 = ftyp();
      const pad = 5000000000;
      final payloadStart = f0.length + 16 + pad;
      final mdatSize = 16 + pad + p.payload.length;
      final mdatHeader = bytesOf(
        (w) => w
          ..u32(1)
          ..str('mdat')
          ..u64(mdatSize),
      );
      final moov = p.moovFor(payloadStart);
      final moovStart = f0.length + mdatSize;
      final src = SparseSource(moovStart + moov.length, {
        0: concat([f0, mdatHeader]),
        payloadStart: p.payload,
        moovStart: moov,
      });
      final f = await Mp4File.open(src);
      checkPlain(f, p);
      expect(f.sampleTable(1).first.offset, payloadStart);
      final vs = await collect(f.samples(1));
      for (var i = 0; i < 6; i++) {
        expect(vs[i].data, p.video[i]);
      }
    });

    test('errors', () async {
      await expectLater(
        Mp4File.open(MemoryByteSource(Uint8List(0))),
        throwsA(isA<Mp4FormatException>()),
      );
      await expectLater(
        Mp4File.open(
          MemoryByteSource(
            Uint8List.fromList(List<int>.generate(64, (i) => i * 37 & 0xFF)),
          ),
        ),
        throwsA(isA<Mp4FormatException>()),
      );
      await expectLater(
        Mp4File.open(
          MemoryByteSource(concat([ftyp(), mdatBox(Uint8List(10))])),
        ),
        throwsA(isA<Mp4FormatException>()),
      );
      // Truncated moov.
      final full = plainFile(plainParts());
      await expectLater(
        Mp4File.open(
          MemoryByteSource(Uint8List.sublistView(full, 0, full.length - 10)),
        ),
        throwsA(isA<Mp4FormatException>()),
      );
    });

    test('truncated mdat yields short data without throwing', () async {
      final p = plainParts();
      final full = plainFile(p, moovFirst: true);
      final cut = Uint8List.sublistView(full, 0, full.length - 5);
      final f = await Mp4File.open(MemoryByteSource(cut));
      final vs = await collect(f.samples(1));
      expect(vs.length, 6);
      expect(vs.last.data.length, vSizes[5] - 5);
    });
  });

  group('fragmented', () {
    test('moof/traf/trun parsing', () async {
      final ff = fragmentedFile();
      final f = await Mp4File.open(MemoryByteSource(ff.bytes));
      expect(f.isFragmented, isTrue);
      final v = f.firstVideoTrack!;
      final a = f.firstAudioTrack!;
      expect(v.fragmented, isTrue);
      expect(v.sampleCount, 6);
      expect(a.sampleCount, 4);
      expect(v.durationTs, 18000);
      expect(a.durationTs, 4096);
      final vt = f.sampleTable(1);
      expect(vt.map((s) => s.offset).toList(), ff.vOffsets);
      expect(vt.map((s) => s.size).toList(), vSizes);
      expect(vt.map((s) => s.dts).toList(), [
        0,
        3000,
        6000,
        9000,
        12000,
        15000,
      ]);
      expect(vt.map((s) => s.cts).toList(), [
        6000,
        0,
        6000,
        9000,
        12000,
        15000,
      ]);
      expect(vt.map((s) => s.isSync).toList(), [
        true,
        false,
        false,
        true,
        false,
        false,
      ]);
      final at = f.sampleTable(2);
      expect(at.map((s) => s.offset).toList(), ff.aOffsets);
      expect(at.map((s) => s.size).toList(), [10, 10, 6, 6]);
      expect(at.map((s) => s.dts).toList(), [0, 1024, 2048, 3072]);
      expect(at.every((s) => s.isSync), isTrue);

      final vs = await collect(f.samples(1));
      for (var i = 0; i < 6; i++) {
        expect(vs[i].data, ff.video[i]);
      }
      final as = await collect(f.samples(2));
      for (var i = 0; i < 4; i++) {
        expect(as[i].data, ff.audio[i]);
      }
      final all = await collect(f.interleaved());
      expect(all.length, 10);
      for (var i = 1; i < all.length; i++) {
        final prev = all[i - 1];
        final cur = all[i];
        expect(cur.dtsUs >= prev.dtsUs, isTrue);
        if (cur.dtsUs == prev.dtsUs) {
          expect(cur.offset, greaterThan(prev.offset));
        }
      }
    });
  });

  group('avcc helpers', () {
    test('split with 1, 2 and 4 byte lengths', () {
      for (final ls in [1, 2, 4]) {
        final w = W();
        void nal(List<int> d) {
          for (var i = ls - 1; i >= 0; i--) {
            w.u8(d.length >> (8 * i));
          }
          w.bytes(d);
        }

        nal([0x67, 1, 2]);
        nal([0x68, 3]);
        nal([0x65, 4, 5, 6]);
        final s = w.take();
        final nals = splitLengthPrefixedNals(s, ls);
        expect(nals, [
          [0x67, 1, 2],
          [0x68, 3],
          [0x65, 4, 5, 6],
        ]);
        expect(nals[0].buffer, s.buffer); // views, not copies
      }
    });

    test('robust against truncation and garbage', () {
      final s = Uint8List.fromList([0, 0, 0, 2, 0x41, 1, 0, 0, 0, 9, 1, 2]);
      expect(splitLengthPrefixedNals(s, 4), [
        [0x41, 1],
      ]);
      expect(
        splitLengthPrefixedNals(Uint8List.fromList([0xFF, 0xFF]), 4),
        isEmpty,
      );
      expect(
        splitLengthPrefixedNals(
          Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF, 1]),
          4,
        ),
        isEmpty,
      );
      expect(splitLengthPrefixedNals(s, 3), isEmpty);
    });

    test('annex b conversion', () {
      final s = Uint8List.fromList([0, 0, 0, 2, 0x41, 1, 0, 0, 0, 1, 0x06]);
      expect(avccToAnnexB(s, 4), [0, 0, 0, 1, 0x41, 1, 0, 0, 0, 1, 0x06]);
      expect(avccToAnnexB(s, 4, prepend: [kSps]), [
        0, 0, 0, 1, ...kSps, //
        0, 0, 0, 1, 0x41, 1, 0, 0, 0, 1, 0x06,
      ]);
      final cfg = AvcConfig.parse(Uint8List.sublistView(avcC(kSps, kPps), 8));
      expect(avcConfigToAnnexB(cfg), [
        0,
        0,
        0,
        1,
        ...kSps,
        0,
        0,
        0,
        1,
        ...kPps,
      ]);
    });
  });

  group('audio specific config', () {
    test('HE-AAC explicit signalling', () {
      // AOT 5, 24000 Hz core (index 6), stereo, ext 48000 (index 3), AOT 2.
      // bits: 00101 0110 0010 0011 00010 ...
      final asc = AudioSpecificConfig.parse(
        Uint8List.fromList([0x2B, 0x11, 0x88, 0x00]),
      );
      expect(asc.audioObjectType, 5);
      expect(asc.sampleRate, 24000);
      expect(asc.channels, 2);
      expect(asc.extensionSampleRate, 48000);
      expect(asc.extensionAudioObjectType, 2);
    });
  });
}
