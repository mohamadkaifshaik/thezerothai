import 'dart:typed_data';

typedef VideoEdit = ({Duration start, Duration end, bool muted});

enum VideoTextPosition { top, center, bottom }

const kAllowVideoDownload = 16;

enum VideoLabel {
  nudity(1, 'Nudity'),
  violence(2, 'Violence'),
  sensitive(4, 'Other sensitive content'),
  ai(8, 'Made with AI');

  const VideoLabel(this.bit, this.label);
  final int bit;
  final String label;

  static List<VideoLabel> warnings(int flags) => [
    for (final label in values)
      if (label != ai && flags & label.bit != 0) label,
  ];
}

enum VideoTextStyle {
  basic('Basic'),
  strong('Strong'),
  typewriter('Typewriter'),
  poster('Poster');

  const VideoTextStyle(this.label);
  final String label;
}

typedef VideoOverlay = ({
  String text,
  VideoTextPosition position,
  VideoTextStyle style,
  double size,
  int color,
});
typedef VideoCaption = ({Duration start, Duration end, String text});
typedef VideoAudioWindow = ({Duration start, Duration length});
typedef VideoLayer = ({
  Uint8List png,
  VideoTextPosition position,
  Duration? start,
  Duration? end,
});

class VideoProject {
  const VideoProject({
    required this.range,
    this.overlay,
    this.captions = const [],
    this.coverFrame,
    this.coverImage,
    this.labels = 0,
  });

  final VideoEdit range;
  final VideoOverlay? overlay;
  final List<VideoCaption> captions;

  /// Position in the source clip, before trimming.
  final Duration? coverFrame;
  final Uint8List? coverImage;
  final int labels;
}

List<VideoAudioWindow> captionWindows(VideoEdit range) {
  // Leave time for the encoder's last audio packet inside the RPC limit.
  const maximum = Duration(seconds: 54);
  return [
    for (var start = range.start; start < range.end; start += maximum)
      (
        start: start,
        length: range.end - start < maximum ? range.end - start : maximum,
      ),
  ];
}

/// Read plain-text cues from a WebVTT or SubRip file. Times refer to the
/// source clip so the cues stay aligned if the trim range changes.
List<VideoCaption> parseVideoCaptions(String input) {
  final lines = input.replaceFirst('\ufeff', '').replaceAll('\r', '').trim();
  final result = <VideoCaption>[];
  for (final block in lines.split(RegExp(r'\n[ \t]*\n'))) {
    final rows = block.split('\n');
    if (rows.first.startsWith('WEBVTT') ||
        rows.first.startsWith('NOTE ') ||
        rows.first == 'NOTE' ||
        rows.first == 'STYLE' ||
        rows.first == 'REGION') {
      continue;
    }
    final index = rows.indexWhere((line) => line.contains('-->'));
    if (index < 0 || index == rows.length - 1) {
      throw const FormatException('Use a valid SRT or WebVTT caption file.');
    }
    final times = rows[index].split('-->');
    if (times.length != 2) {
      throw const FormatException('A caption has an invalid timestamp.');
    }
    final start = _captionTime(times[0].trim());
    final end = _captionTime(times[1].trim().split(RegExp(r'\s+')).first);
    final text = rows
        .skip(index + 1)
        .join('\n')
        .replaceAll(RegExp(r'</?[A-Za-z][^>]*>'), '')
        .trim();
    if (end <= start || text.isEmpty || text.runes.length > 240) {
      throw const FormatException(
        'Each caption needs a valid range and 1–240 characters.',
      );
    }
    result.add((start: start, end: end, text: text));
  }
  if (result.isEmpty || result.length > 60) {
    throw const FormatException('Choose a caption file with 1–60 cues.');
  }
  result.sort((a, b) => a.start.compareTo(b.start));
  for (var i = 1; i < result.length; i++) {
    if (result[i].start < result[i - 1].end) {
      throw const FormatException('The caption ranges must not overlap.');
    }
  }
  return List.unmodifiable(result);
}

Duration _captionTime(String value) {
  final match = RegExp(r'^(?:(\d{1,3}):)?([0-5]\d):([0-5]\d)[.,](\d{3})$')
      .firstMatch(value);
  if (match == null) {
    throw const FormatException('A caption has an invalid timestamp.');
  }
  return Duration(
    hours: int.parse(match[1] ?? '0'),
    minutes: int.parse(match[2]!),
    seconds: int.parse(match[3]!),
    milliseconds: int.parse(match[4]!),
  );
}
