import 'dart:convert';
import 'dart:typed_data';

const maxClipBytes = 96 * 1024 * 1024;
const unreadableClip = 'Could not decode this video. Choose another clip.';

typedef ConvertedClip = ({
  Uint8List video,
  Uint8List poster,
  String metadata,
  String fullMd5,
});

// Only self-contained media containers. In particular, never open playlists,
// network URLs, or external tracks referenced by an input.
List<String> encodeClip(String input, String output, {required bool web}) => [
  '-v', 'error', '-protocol_whitelist', 'file', '-format_whitelist',
  'mov,matroska,webm,avi,asf,flv,mpeg,mpegts,ogg,3gp,m4v,h264,hevc',
  '-i', input, '-map', '0:V:0', '-map', '0:a:0?', '-map_metadata', '-1',
  '-map_chapters', '-1', '-vf',
  "scale='min(1920,iw)':'min(1920,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2,setsar=1",
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
  '-t', '301', '-movflags', '+faststart', output,
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

List<String> extractPoster(String output, String poster) => [
  '-v',
  'error',
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
