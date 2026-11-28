import 'dart:convert';
import 'dart:typed_data';

import '../domain/video_edit.dart';

const maxClipBytes = 96 * 1024 * 1024;
const unreadableClip = 'Could not decode this video. Choose another clip.';

class ClipEdit {
  const ClipEdit({this.start = Duration.zero, this.length, this.muted = false});

  final Duration start;
  final Duration? length;
  final bool muted;
}

const _videoScale =
    "scale='min(1920,iw)':'min(1920,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2,setsar=1";

typedef ConvertedClip = ({
  Uint8List video,
  Uint8List poster,
  String metadata,
  String fullMd5,
});

// Only self-contained media containers. In particular, never open playlists,
// network URLs, or external tracks referenced by an input.
List<String> encodeClip(
  String input,
  String output, {
  required bool web,
  ClipEdit edit = const ClipEdit(),
  List<({String path, VideoLayer layer})> artwork = const [],
}) => [
  '-v', 'error', '-protocol_whitelist', 'file', '-format_whitelist',
  'mov,matroska,webm,avi,asf,flv,mpeg,mpegts,ogg,3gp,m4v,h264,hevc',
  if (edit.start > Duration.zero) ...['-ss', _seconds(edit.start)],
  '-i', input,
  for (final item in artwork) ...[
    '-f',
    'image2',
    '-pattern_type',
    'none',
    '-i',
    item.path,
  ],
  if (artwork.isEmpty) ...[
    '-map',
    '0:V:0',
    '-vf',
    _videoScale,
  ] else ...[
    '-filter_complex_threads',
    '1',
    '-filter_complex',
    _videoGraph(artwork),
    '-map',
    '[edited]',
  ],
  if (edit.muted) '-an' else ...['-map', '0:a:0?'],
  '-map_metadata', '-1',
  '-map_chapters', '-1',
  if (web) ...[
    '-c:v',
    'libx264',
    '-preset',
    'ultrafast',
    '-crf',
    '23',
  ] else ...[
    '-c:v',
    'libopenh264',
    '-b:v',
    '2100k',
  ],
  '-pix_fmt', 'yuv420p',
  '-threads', '2', '-maxrate', '2350k', '-bufsize', '4700k',
  // Frequent keyframes keep server-side frame sampling and feed seeking cheap.
  '-force_key_frames',
  'expr:gte(t,n_forced*2)',
  '-fpsmax',
  '30',
  '-c:a',
  'aac',
  '-ac',
  '2',
  '-b:a',
  '128k',
  // Keep one extra second so an overlong recording is refused, never posted truncated.
  '-t', edit.length == null ? '301' : _seconds(edit.length!),
  '-movflags', '+faststart', output,
];

String _videoGraph(List<({String path, VideoLayer layer})> artwork) {
  final graph = <String>['[0:V:0]$_videoScale[v0]'];
  for (final (index, item) in artwork.indexed) {
    final layer = item.layer;
    final y = switch (layer.position) {
      VideoTextPosition.top => 'H*0.07',
      VideoTextPosition.center => '(H-h)/2',
      VideoTextPosition.bottom => 'H-h-H*0.07',
    };
    final start = layer.start;
    final end = layer.end;
    final when = start == null || end == null
        ? ''
        : ":enable='gte(t,${_seconds(start)})*lt(t,${_seconds(end)})'";
    final next = index == artwork.length - 1 ? 'edited' : 'v${index + 1}';
    graph.add('[v$index][${index + 1}:v:0]overlay=x=(W-w)/2:y=$y$when[$next]');
  }
  return graph.join(';');
}

String _seconds(Duration duration) =>
    (duration.inMicroseconds / Duration.microsecondsPerSecond).toStringAsFixed(
      6,
    );

List<String> encodeCaptionAudio(
  String input,
  String output,
  VideoAudioWindow window,
) => [
  '-v',
  'error',
  '-protocol_whitelist',
  'file',
  '-f',
  'mov',
  '-ss',
  _seconds(window.start),
  '-i',
  input,
  '-map',
  '0:a:0',
  '-vn',
  '-sn',
  '-dn',
  '-map_metadata',
  '-1',
  '-t',
  _seconds(window.length),
  '-ac',
  '1',
  '-ar',
  '16000',
  '-c:a',
  'libopus',
  '-b:a',
  '20k',
  '-vbr',
  'off',
  '-f',
  'ogg',
  output,
];

List<String> probeClip(String output, String metadata) => [
  '-v',
  'error',
  '-select_streams',
  'v:0',
  '-show_entries',
  'stream=width,height:format=duration',
  '-of',
  'json',
  '-o',
  metadata,
  output,
];

List<String> extractPoster(String output, String poster, {Duration? at}) => [
  '-v',
  'error',
  if (at != null && at > Duration.zero) ...['-ss', _seconds(at)],
  '-i',
  output,
  '-frames:v',
  '1',
  '-vf',
  "scale='min(iw,480)':-1",
  '-q:v',
  '3',
  poster,
];

/// A seek past the last decoded frame can succeed without writing a JPEG.
/// Retry a little earlier for low frame-rate clips, then fall back to frame 0.
Iterable<List<String>> posterCandidates(
  String input,
  String output,
  Duration? at,
) sync* {
  if (at != null && at > Duration.zero) {
    yield extractPoster(input, output, at: at);
    const lookBack = Duration(seconds: 1);
    if (at > lookBack) yield extractPoster(input, output, at: at - lookBack);
  }
  yield extractPoster(input, output);
}

({int width, int height}) clipDimensions(String metadata) {
  final info = jsonDecode(metadata) as Map<String, dynamic>;
  final duration = double.tryParse(info['format']['duration'] as String? ?? '');
  if (duration == null || !duration.isFinite || duration <= 0) {
    throw const FormatException(unreadableClip);
  }
  if (duration > 300) {
    throw const FormatException('Choose a clip up to 5 minutes.');
  }
  final stream = (info['streams'] as List).single as Map;
  return (width: stream['width'] as int, height: stream['height'] as int);
}
