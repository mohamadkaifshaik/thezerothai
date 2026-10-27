import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// A user avatar: the network image when [url] is set, else a person icon.
///
/// The one avatar for post cards, list rows and profile headers (reuse-first:
/// no per-feature copies). Images come through the `cached_network_image`
/// disk cache and are resized at decode time to display size (`radius * 2`
/// device pixels, never more than [maxDecodePx]) instead of full size, which keeps long
/// lists cheap on memory. Lists should pass the 96 px author-snapshot
/// thumbnail; only the profile header has a larger source.
///
/// **Load error: the same person icon as no avatar** (ADR-0024 Amendment 1 A4
/// point 5). A removed or replaced avatar's object is deleted from the bucket
/// 24-48 h later (`PROFILE_MEDIA_RETIRE`), and older posts and notifications
/// keep its URL in their author snapshot, so a missing object (HTTP 404) is an
/// expected answer, not a bug. Any load error takes the fallback, because the
/// web image loader cannot read a status; it needs no size change (the circle
/// is `radius * 2` either way), no retry loop and no error report. The
/// fallback sticks for this widget's life and clears when [url] changes.
class AppAvatar extends StatefulWidget {
  const AppAvatar({
    super.key,
    required this.url,
    this.radius = 20,
    this.maxDecodePx = 400,
    this.bytes,
  });

  /// Avatar image URL; empty shows the fallback icon.
  final String url;
  final double radius;

  /// Upper bound for the decoded width/height in pixels.
  final int maxDecodePx;

  /// A local image (for example a just-picked, unsaved avatar). When set it
  /// is shown instead of [url], decoded at display size.
  final Uint8List? bytes;

  @override
  State<AppAvatar> createState() => _AppAvatarState();
}

class _AppAvatarState extends State<AppAvatar> {
  /// The [AppAvatar.url] that failed to load, if any.
  String? _failedUrl;

  @override
  void didUpdateWidget(AppAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _failedUrl = null;
  }

  void _onImageError(Object error, StackTrace? stack) {
    final failing = widget.url;
    void mark() {
      if (mounted && widget.url == failing && _failedUrl != failing) {
        setState(() => _failedUrl = failing);
      }
    }

    // The error can arrive while a frame is being built or painted (a
    // provider that fails at once); a rebuild is then due after it.
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      mark();
    } else {
      SchedulerBinding.instance.addPostFrameCallback((_) => mark());
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.url;
    final radius = widget.radius;
    final pixels = (radius * 2 * MediaQuery.devicePixelRatioOf(context))
        .ceil()
        .clamp(1, widget.maxDecodePx);
    final local = widget.bytes;
    final showNetwork = local == null && url.isNotEmpty && _failedUrl != url;
    final ImageProvider? image = local != null
        ? ResizeImage(
            MemoryImage(local),
            width: pixels,
            height: pixels,
            policy: ResizeImagePolicy.fit,
          )
        : showNetwork
        ? ResizeImage(
            CachedNetworkImageProvider(url),
            width: pixels,
            height: pixels,
            policy: ResizeImagePolicy.fit,
          )
        : null;
    return CircleAvatar(
      // A new element when the picture goes: `CircleAvatar` animates its
      // decoration, and for the first half of that animation it would paint
      // (and so ask for) the failed image again.
      key: ValueKey<bool>(image == null),
      radius: radius,
      backgroundImage: image,
      // Without a handler a failed load is reported as an unhandled error. A
      // local picture is ours: its failure stays reported.
      onBackgroundImageError: showNetwork ? _onImageError : null,
      child: image == null ? Icon(Icons.person_outline, size: radius) : null,
    );
  }
}
