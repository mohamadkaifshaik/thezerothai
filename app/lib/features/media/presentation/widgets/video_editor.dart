import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

import '../../data/video_source.dart';

Future<ClipEdit?> showVideoEditor(BuildContext context, String path) =>
    showDialog<ClipEdit>(
      context: context,
      builder: (_) => _VideoEditor(path: path),
    );

class _VideoEditor extends StatefulWidget {
  const _VideoEditor({required this.path});
  final String path;

  @override
  State<_VideoEditor> createState() => _VideoEditorState();
}

class _VideoEditorState extends State<_VideoEditor> {
  late final _player = pickedVideoController(widget.path);
  late final _ready = _initialize();
  var _range = const RangeValues(0, 1);
  var _muted = false;

  Future<void> _initialize() async {
    await _player.initialize();
    if (!mounted) return;
    _range = RangeValues(0, _player.value.duration.inMilliseconds.toDouble());
    _player.addListener(_stopAtEnd);
  }

  void _stopAtEnd() {
    if (_player.value.isPlaying &&
        _player.value.position.inMilliseconds >= _range.end) {
      _player.pause();
    }
  }

  @override
  void dispose() {
    _player.removeListener(_stopAtEnd);
    _player.dispose();
    super.dispose();
  }

  String _time(double milliseconds) {
    final seconds = milliseconds ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _ready,
    builder: (context, snapshot) {
      final ready = snapshot.connectionState == ConnectionState.done;
      final duration = _player.value.duration.inMilliseconds.toDouble();
      final preview = ready && !snapshot.hasError && duration > 0;
      final length = (_range.end - _range.start).round();
      final valid = !preview || (length > 0 && length <= 300000);
      return AlertDialog(
        title: const Text('Edit video'),
        scrollable: true,
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!ready)
                const Center(child: CircularProgressIndicator())
              else if (preview) ...[
                SizedBox(
                  height: MediaQuery.sizeOf(context).height * .3,
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: _player.value.aspectRatio,
                      child: VideoPlayer(_player),
                    ),
                  ),
                ),
                ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: _player,
                  builder: (_, value, _) => IconButton(
                    tooltip: value.isPlaying ? 'Pause' : 'Play selection',
                    icon: Icon(
                      value.isPlaying ? Icons.pause : Icons.play_arrow,
                    ),
                    onPressed: () async {
                      if (value.isPlaying) {
                        await _player.pause();
                      } else {
                        await _player.seekTo(
                          Duration(milliseconds: _range.start.round()),
                        );
                        if (mounted) await _player.play();
                      }
                    },
                  ),
                ),
                Text('Trim  ${_time(_range.start)} – ${_time(_range.end)}'),
                RangeSlider(
                  max: duration,
                  values: _range,
                  semanticFormatterCallback: _time,
                  onChangeStart: (_) => _player.pause(),
                  onChanged: (next) {
                    final position = next.start != _range.start
                        ? next.start
                        : next.end;
                    setState(() => _range = next);
                    _player.seekTo(Duration(milliseconds: position.round()));
                  },
                ),
                if (!valid) const Text('Choose a clip up to 5 minutes long.'),
              ] else
                const Text(
                  'Preview unavailable. You can still add this video.',
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Mute audio'),
                value: _muted,
                onChanged: (value) {
                  setState(() => _muted = value);
                  if (preview) _player.setVolume(value ? 0 : 1);
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: ready && valid
                ? () => Navigator.pop(
                    context,
                    ClipEdit(
                      start: Duration(milliseconds: _range.start.round()),
                      length: preview && _range.end < duration
                          ? Duration(milliseconds: length)
                          : null,
                      muted: _muted,
                    ),
                  )
                : null,
            child: const Text('Add video'),
          ),
        ],
      );
    },
  );
}
