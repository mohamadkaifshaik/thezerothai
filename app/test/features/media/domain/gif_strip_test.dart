import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dzeroth/features/media/domain/image_processor.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/media_fixtures.dart';

/// Security L-4: the byte-level GIF stripper, against the same
/// fixture the Go pre-scan runs (`testdata/gif_strip.json`). No re-encode:
/// every dirty input must come out as exactly the clean bytes.
void main() {
  final cases =
      (jsonDecode(File('../testdata/gif_strip.json').readAsStringSync())
              as Map<String, dynamic>)['cases']
          as List<dynamic>;

  test('the fixture covers every kind of dirt', () {
    final names = [for (final c in cases) (c as Map)['name']];
    expect(
      names,
      containsAll([
        'netscape_clean',
        'animexts_clean',
        'comment',
        'xmp',
        'plain_text',
        'trailing_bytes',
        'loop_extra_subblocks',
        'second_loop_block',
        'loop_wrong_id',
        'loop_wrong_length',
        'animexts_extra_subblocks',
      ]),
    );
  });

  for (final raw in cases) {
    final c = raw as Map<String, dynamic>;
    final input = base64.decode(c['gif'] as String);
    final expected = base64.decode(c['stripped'] as String);
    final dirty = c['dirty'] as bool;

    test('${c['name']}: stripping gives exactly the expected bytes', () {
      final out = stripGifBytes(input);
      expect(out, expected);
      if (!dirty) expect(out, same(input), reason: 'identity when clean');
      // Idempotent: a stripped file is clean.
      expect(stripGifBytes(out), out);
    });

    test(
      '${c['name']}: prepareGifSync uploads and hashes the stripped bytes',
      () {
        final out = prepareGifSync(input);
        expect(out.fullBytes, expected);
        expect(out.fullMd5, base64.encode(md5.convert(expected).bytes));
        expect(out.width, 2);
        expect(out.height, 2);
        expect(out.contentType, 'image/gif');
      },
    );
  }

  test('NETSCAPE2.0 and ANIMEXTS1.0 loop blocks are kept', () {
    for (final name in ['netscape_clean', 'animexts_clean']) {
      final c = cases.cast<Map<String, dynamic>>().firstWhere(
        (c) => c['name'] == name,
      );
      final out = stripGifBytes(base64.decode(c['gif'] as String));
      final id = name == 'netscape_clean' ? 'NETSCAPE2.0' : 'ANIMEXTS1.0';
      expect(String.fromCharCodes(out), contains(id));
    }
  });

  test(
    'W6-58: the loop block keeps only its count; a second one is dropped',
    () {
      Map<String, dynamic> byName(String n) =>
          cases.cast<Map<String, dynamic>>().firstWhere((c) => c['name'] == n);
      final extra = stripGifBytes(
        base64.decode(byName('loop_extra_subblocks')['gif'] as String),
      );
      final at = String.fromCharCodes(extra).indexOf('NETSCAPE2.0') + 11;
      expect(extra.sublist(at, at + 5), [3, 1, 5, 0, 0]);
      final second = stripGifBytes(
        base64.decode(byName('second_loop_block')['gif'] as String),
      );
      expect('NETSCAPE2.0'.allMatches(String.fromCharCodes(second)).length, 1);
      final dropped = stripGifBytes(
        base64.decode(byName('loop_wrong_id')['gif'] as String),
      );
      expect(String.fromCharCodes(dropped), isNot(contains('NETSCAPE')));
    },
  );

  test('a generated multi-frame GIF with a comment loses only the comment', () {
    final clean = realGifBytes(width: 8, height: 8, frames: 4);
    expect(stripGifBytes(clean), clean);
    // Comment extension right after the header's global colour table.
    final gct = 3 << ((clean[10] & 7) + 1);
    final at = 13 + ((clean[10] & 0x80) != 0 ? gct : 0);
    final dirty = Uint8List.fromList([
      ...clean.sublist(0, at),
      0x21, 0xFE, 3, 0x61, 0x62, 0x63, 0, //
      ...clean.sublist(at),
      ...'tail'.codeUnits,
    ]);
    expect(stripGifBytes(dirty), clean);
  });

  test('a truncated or non-GIF-structured file is refused', () {
    final good = base64.decode(
      (cases.first as Map<String, dynamic>)['gif'] as String,
    );
    expect(
      () => stripGifBytes(Uint8List.sublistView(good, 0, good.length - 1)),
      throwsA(GifRefusedException.notGif),
    );
    expect(
      () => stripGifBytes(Uint8List.fromList('GIF89a'.codeUnits)),
      throwsA(GifRefusedException.notGif),
    );
  });
}
