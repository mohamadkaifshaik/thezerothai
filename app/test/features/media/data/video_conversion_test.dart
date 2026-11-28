import 'dart:typed_data';

import 'package:dzeroth/features/media/data/video_conversion.dart';
import 'package:dzeroth/features/media/domain/video_edit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('caption audio windows cover exactly the selected range', () {
    final chunks = captionWindows((
      start: const Duration(seconds: 5),
      end: const Duration(seconds: 120),
      muted: true,
    ));
    expect(chunks.map((window) => window.start.inSeconds), [5, 59, 113]);
    expect(chunks.map((window) => window.length.inSeconds), [54, 54, 7]);
    final args = encodeCaptionAudio('source', 'segment.ogg', chunks.last);
    expect(args, containsAll(['0:a:0', '-vn', 'libopus', '16000']));
  });

  test('timed captions use export-relative times and selected covers seek', () {
    final args = encodeClip(
      'source',
      'output',
      web: true,
      artwork: [
        (
          path: 'cue.png',
          layer: (
            png: Uint8List(0),
            position: VideoTextPosition.bottom,
            start: const Duration(milliseconds: 200),
            end: const Duration(milliseconds: 850),
          ),
        ),
      ],
    );
    expect(args, contains('cue.png'));
    expect(args, contains('[edited]'));
    final graph = args[args.indexOf('-filter_complex') + 1];
    expect(graph, contains("enable='gte(t,0.200000)*lt(t,0.850000)'"));
    final poster = extractPoster(
      'output',
      'cover.jpg',
      at: const Duration(seconds: 2),
    );
    expect(poster[poster.indexOf('-ss') + 1], '2.000000');
    final candidates = posterCandidates(
      'output',
      'cover.jpg',
      const Duration(seconds: 2),
    ).toList();
    expect(candidates.last, isNot(contains('-ss')));
    expect(candidates[1], contains('1.000000'));
  });

  test('parses ordered SRT and WebVTT with source-relative timestamps', () {
    final srt = parseVideoCaptions(
      '1\r\n00:00:02,500 --> 00:00:04,000\r\nHello\r\n\r\n'
      '2\r\n00:00:04,000 --> 00:00:05,000\r\nAgain',
    );
    expect(srt.first.start, const Duration(milliseconds: 2500));
    expect(srt.last.text, 'Again');
    final vtt = parseVideoCaptions(
      'WEBVTT\n\n00:02.500 --> 00:04.000 align:center\n<i>Hello</i>',
    );
    expect(vtt.single, srt.first);
    expect(
      () => parseVideoCaptions(
        '00:01.000 --> 00:02.000\nA\n\n00:01.500 --> 00:03.000\nB',
      ),
      throwsFormatException,
    );
  });

  test('video exports seek and limit the range and can omit the audio', () {
    for (final web in [false, true]) {
      final args = encodeClip(
        'source',
        'output',
        web: web,
        edit: const ClipEdit(
          start: Duration(milliseconds: 1250),
          length: Duration(milliseconds: 2125),
          muted: true,
        ),
      );
      expect(args[args.indexOf('-ss') + 1], '1.250000');
      expect(args[args.indexOf('-t') + 1], '2.125000');
      expect(args, contains('-an'));
      expect(args, isNot(contains('0:a:0?')));
      final original = encodeClip('source', 'output', web: web);
      expect(original, contains('0:a:0?'));
      expect(original, isNot(contains('-ss')));
    }
  });
}
