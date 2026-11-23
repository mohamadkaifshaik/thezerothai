import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

/// The poster is the only network asset loaded until the viewer presses play.
class PostVideo extends StatefulWidget {
  const PostVideo({
    super.key,
    required this.url,
    required this.poster,
    this.previewController,
  });
  final VideoPlayerController Function()? previewController;
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
    if (widget.previewController != null) _start();
  }

  Future<void> _start() async {
    if (_player != null) return;
    final player =
        widget.previewController?.call() ??
        VideoPlayerController.networkUrl(Uri.parse(widget.url));
    setState(() {
      _player = player;
      _failed = false;
    });
    try {
      await player.initialize();
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
      return Stack(
        fit: StackFit.expand,
        children: [
          widget.poster,
          Center(
            child: IconButton.filled(
              tooltip: _failed ? 'Retry video' : 'Play video',
              onPressed: _start,
              icon: Icon(_failed ? Icons.refresh : Icons.play_arrow),
            ),
          ),
        ],
      );
    }
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: player,
      builder: (context, value, _) {
        if (value.hasError) {
          return Center(
            child: TextButton(
              onPressed: () async {
                setState(() {
                  _player = null;
                  _failed = true;
                });
                await player.dispose();
              },
              child: const Text('Video unavailable. Try again'),
            ),
          );
        }
        if (!value.isInitialized) {
          return const Center(child: CircularProgressIndicator());
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
