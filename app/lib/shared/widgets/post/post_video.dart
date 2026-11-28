import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

import '../../../core/theme/app_theme.dart';
import '../../../features/media/domain/video_edit.dart';
import '../../../features/media/data/photo_gallery.dart';

/// The poster is the only network asset loaded until the viewer presses play.
class PostVideo extends StatefulWidget {
  const PostVideo({
    super.key,
    required this.url,
    required this.poster,
    this.previewController,
    this.startOnOpen = false,
    this.onOpen,
    this.loop = false,
    this.labels = 0,
  });
  final VideoPlayerController Function()? previewController;
  final VoidCallback? onOpen;
  final bool loop;
  final bool startOnOpen;
  final int labels;
  final String url;
  final Widget poster;
  @override
  State<PostVideo> createState() => _PostVideoState();
}

class _PostVideoState extends State<PostVideo> {
  VideoPlayerController? _player;
  bool _failed = false;
  bool _routeVisible = true;
  bool _resumeOnReturn = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.startOnOpen) return;
    final visible = ModalRoute.isCurrentOf(context) ?? true;
    if (visible == _routeVisible) return;
    _routeVisible = visible;
    final player = _player;
    if (player == null || !player.value.isInitialized) return;
    if (!visible && player.value.isPlaying) {
      _resumeOnReturn = true;
      player.pause();
    } else if (visible && _resumeOnReturn) {
      _resumeOnReturn = false;
      player.play();
    }
  }

  bool _revealed = false;
  bool _downloading = false;
  late final _galleryAvailable = canSavePhotoToGallery();

  @override
  void initState() {
    super.initState();
    if (VideoLabel.warnings(widget.labels).isEmpty &&
        (widget.startOnOpen || widget.previewController != null)) {
      _start();
    }
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
      if (widget.loop) await player.setLooping(true);
      if (!mounted || player != _player) return;
      if (kIsWeb) await player.setVolume(0);
      if (!mounted || player != _player) return;
      if (_routeVisible) {
        await player.play();
      } else {
        _resumeOnReturn = true;
      }
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
    final warnings = VideoLabel.warnings(widget.labels);
    if (warnings.isNotEmpty && !_revealed) {
      return ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Sensitive video'),
                Text(
                  warnings.map((label) => label.label).join(' · '),
                  textAlign: TextAlign.center,
                ),
                TextButton(
                  onPressed: () => setState(() => _revealed = true),
                  child: const Text('Show video'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final player = _buildPlayer(context);
    final ai = widget.labels & VideoLabel.ai.bit != 0;
    final downloadable = widget.labels & kAllowVideoDownload != 0;
    if (!ai && !downloadable) return player;
    return Stack(
      fit: StackFit.expand,
      children: [
        player,
        if (ai)
          const PositionedDirectional(
            top: 8,
            start: 8,
            child: IgnorePointer(
              child: Material(
                color: AppColors.mediaDisclosureBackground,
                borderRadius: BorderRadius.all(Radius.circular(6)),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text(
                    'Made with AI',
                    style: TextStyle(color: AppColors.onPhotoBackground),
                  ),
                ),
              ),
            ),
          ),
        if (downloadable)
          PositionedDirectional(
            top: 4,
            end: 4,
            child: FutureBuilder<bool>(
              future: _galleryAvailable,
              builder: (context, available) => available.data == true
                  ? IconButton.filledTonal(
                      tooltip: 'Save video to gallery',
                      onPressed: _downloading ? null : _download,
                      icon: _downloading
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download_outlined),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
      ],
    );
  }

  Future<void> _download() async {
    setState(() => _downloading = true);
    var message = 'Saved to gallery.';
    try {
      await downloadVideoToGallery(widget.url);
    } catch (_) {
      message = 'Could not save the video to your gallery.';
    }
    if (!mounted) return;
    setState(() => _downloading = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _buildPlayer(BuildContext context) {
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
            onTap: widget.onOpen ?? _start,
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
          color: widget.loop ? AppColors.photoBackground : colors.surface,
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
                  color: widget.loop
                      ? AppPalette.photoScrim
                      : colors.surfaceContainerHigh,
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
