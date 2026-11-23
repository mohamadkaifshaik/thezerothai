import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

/// The poster is the only network asset loaded until the viewer presses play.
class PostVideo extends StatefulWidget {
  const PostVideo({
    super.key,
    required this.url,
    required this.poster,
    this.previewController,
    this.startOnOpen = false,
  });
  final VideoPlayerController Function()? previewController;
  final bool startOnOpen;
  final String url;
  final Widget poster;
  @override
  State<PostVideo> createState() => _PostVideoState();
}

class _PostVideoState extends State<PostVideo> {
  VideoPlayerController? _player;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (widget.startOnOpen || widget.previewController != null) _start();
  }

  Future<void> _start() async {
    final previous = _player;
    if (previous != null && !previous.value.hasError) return;
    final player =
        widget.previewController?.call() ??
        VideoPlayerController.networkUrl(Uri.parse(widget.url));
    setState(() {
      _player = player;
      _failed = false;
    });
    try {
      if (previous != null) await previous.dispose();
      if (!mounted || player != _player) return;
      await player.initialize().timeout(const Duration(seconds: 30));
      if (!mounted || player != _player) return;
      // Network initialization may outlast the browser's tap activation.
      // Start inline playback muted and let the sound button unmute it.
      if (kIsWeb) await player.setVolume(0);
      if (!mounted || player != _player) return;
      await player.play();
    } catch (_) {
      if (!mounted || player != _player) return;
      setState(() {
        _failed = true;
        _player = null;
      });
      await player.dispose();
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final player = _player;
    if (player == null) {
      final label = _failed ? 'Retry video' : 'Play video';
      return Tooltip(
        message: label,
        child: Semantics(
          button: true,
          label: label,
          child: InkWell(
            onTap: _start,
            child: Stack(
              fit: StackFit.expand,
              children: [
                widget.poster,
                Center(
                  child: CircleAvatar(
                    backgroundColor: colors.primary,
                    foregroundColor: colors.onPrimary,
                    child: Icon(_failed ? Icons.refresh : Icons.play_arrow),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: player,
      builder: (context, value, _) {
        if (value.hasError) {
          return Center(
            child: TextButton(
              onPressed: _start,
              child: const Text('Video unavailable. Try again'),
            ),
          );
        }
        if (!value.isInitialized) {
          return Stack(
            fit: StackFit.expand,
            children: [
              widget.poster,
              const Center(child: CircularProgressIndicator()),
            ],
          );
        }
        return ColoredBox(
          color: colors.surface,
          child: Stack(
            children: [
              Center(
                child: AspectRatio(
                  aspectRatio: value.aspectRatio,
                  child: VideoPlayer(player),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: ColoredBox(
                  color: colors.surfaceContainerHigh,
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: value.isPlaying ? 'Pause video' : 'Play video',
                        color: colors.onSurface,
                        onPressed: value.isPlaying ? player.pause : player.play,
                        icon: Icon(
                          value.isPlaying ? Icons.pause : Icons.play_arrow,
                        ),
                      ),
                      Expanded(
                        child: VideoProgressIndicator(
                          player,
                          allowScrubbing: true,
                        ),
                      ),
                      IconButton(
                        tooltip: value.volume == 0
                            ? 'Unmute video'
                            : 'Mute video',
                        color: colors.onSurface,
                        onPressed: () =>
                            player.setVolume(value.volume == 0 ? 1 : 0),
                        icon: Icon(
                          value.volume == 0
                              ? Icons.volume_off
                              : Icons.volume_up,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
