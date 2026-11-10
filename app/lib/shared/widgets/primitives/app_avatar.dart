import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../core/theme/app_theme.dart';

/// The avatar size presets (ADR-0033); diameters come from [AppSize].
enum AppAvatarSize {
  sm(AppSize.avatarSm),
  row(AppSize.avatarRow),
  post(AppSize.avatarPost),
  lg(AppSize.avatarLg),

  /// Profile header: drawn with a 4 dp page-colour ring around it.
  xl(AppSize.avatarXl, ring: 4);

  const AppAvatarSize(this.diameter, {this.ring = 0});

  final double diameter;

  /// Width of the page-colour ring drawn outside [diameter].
  final double ring;
}

/// Up to two initials of [name] (first letters of its first and last word),
/// upper-cased; empty when [name] has no letters.
String avatarInitials(String name) {
  final words = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return '';
  String first(String w) => String.fromCharCodes(w.runes.take(1));
  final picked = words.length == 1
      ? first(words.first)
      : first(words.first) + first(words.last);
  return picked.toUpperCase();
}

/// The fallback tint index for [name]: a stable FNV-1a hash (not
/// `String.hashCode`, which is not stable across runs), so a person keeps
/// their colour.
int avatarTintIndex(String name) {
  var h = 0x811c9dc5;
  for (final c in name.trim().toLowerCase().codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return h % AppPalette.avatarTints.length;
}

/// A user avatar: the network image when [url] is set, else the initials of
/// [name] on a deterministic tint, else a person icon.
///
/// The one avatar for post cards, list rows and profile headers (no per-feature
/// copies). Images come through the `cached_network_image`
/// disk cache and are resized at decode time to display size (`radius * 2`
/// device pixels, never more than [maxDecodePx]) instead of full size, which keeps long
/// lists cheap on memory. Lists should pass the 96 px author-snapshot
/// thumbnail; only the profile header has a larger source.
///
/// **Load error: the same fallback as no avatar** (point 5).
/// A removed or replaced avatar's object is deleted from the bucket
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
    this.name = '',
    this.ring = 0,
    this.onTap,
    this.semanticLabel,
  });

  /// One of the [AppAvatarSize] presets (the `xl` one carries its ring).
  AppAvatar.sized({
    Key? key,
    required String url,
    required AppAvatarSize size,
    int maxDecodePx = 400,
    Uint8List? bytes,
    String name = '',
    VoidCallback? onTap,
    String? semanticLabel,
  }) : this(
         key: key,
         url: url,
         radius: size.diameter / 2,
         maxDecodePx: maxDecodePx,
         bytes: bytes,
         name: name,
         ring: size.ring,
         onTap: onTap,
         semanticLabel: semanticLabel,
       );

  /// Avatar image URL; empty shows the fallback.
  final String url;
  final double radius;

  /// Upper bound for the decoded width/height in pixels.
  final int maxDecodePx;

  /// A local image (for example a just-picked, unsaved avatar). When set it
  /// is shown instead of [url], decoded at display size.
  final Uint8List? bytes;

  /// The person's display name. When set and there is no picture (or it
  /// failed), the avatar shows initials on a tint chosen from the name.
  final String name;

  /// Width of a page-colour ring drawn outside the circle (0: none).
  final double ring;

  /// Makes the avatar a button with at least a 48 dp hit area.
  final VoidCallback? onTap;

  /// Announced for a tappable avatar; defaults to [name]. Without [onTap]
  /// the avatar adds no semantics of its own (it is decoration beside a name).
  final String? semanticLabel;

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
    final initials = avatarInitials(widget.name);
    final tint = initials.isEmpty
        ? null
        : AppPalette.avatarTints[avatarTintIndex(widget.name)];
    final ink = tint == AppPalette.avatarTintNavy
        ? AppPalette.avatarInkOnNavy
        : AppPalette.avatarInkOnTint;
    Widget avatar = CircleAvatar(
      // A new element when the picture goes: `CircleAvatar` animates its
      // decoration, and for the first half of that animation it would paint
      // (and so ask for) the failed image again.
      key: ValueKey<bool>(image == null),
      radius: radius,
      backgroundColor: image == null ? tint : null,
      foregroundColor: image == null && tint != null ? ink : null,
      backgroundImage: image,
      // Without a handler a failed load is reported as an unhandled error. A
      // local picture is ours: its failure stays reported.
      onBackgroundImageError: showNetwork ? _onImageError : null,
      child: image != null
          ? null
          : initials.isNotEmpty
          ? ExcludeSemantics(
              child: Text(
                initials,
                maxLines: 1,
                overflow: TextOverflow.clip,
                // The circle is fixed size: initials do not follow text scale.
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  fontSize: radius * 0.8,
                  fontWeight: FontWeight.w600,
                  height: 1,
                  color: ink,
                ),
              ),
            )
          : Icon(Icons.person_outline, size: radius),
    );
    if (widget.ring > 0) {
      avatar = DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Theme.of(context).colorScheme.surface,
        ),
        child: Padding(padding: EdgeInsets.all(widget.ring), child: avatar),
      );
    }
    final onTap = widget.onTap;
    if (onTap == null) return avatar;
    final label =
        widget.semanticLabel ?? (widget.name.isEmpty ? null : widget.name);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: Center(widthFactor: 1, heightFactor: 1, child: avatar),
        ),
      ),
    );
  }
}

/// One avatar of an [AppAvatarStack].
class AppAvatarStackItem {
  const AppAvatarStackItem({this.url = '', this.name = ''});

  final String url;
  final String name;
}

/// Overlapping avatars (-8 dp, 2 dp page-colour ring) with a "+N" bubble for
/// the people beyond [maxVisible]. Announced once, as one node: the names,
/// then "+N" (the children add no semantics of their own).
class AppAvatarStack extends StatelessWidget {
  const AppAvatarStack({
    super.key,
    required this.items,
    this.maxVisible = 3,
    this.size = AppAvatarSize.sm,
    this.total,
  });

  static const double overlap = 8;
  static const double ringWidth = 2;

  final List<AppAvatarStackItem> items;
  final int maxVisible;
  final AppAvatarSize size;

  /// The real number of people when [items] is only a page of them.
  final int? total;

  @override
  Widget build(BuildContext context) {
    final count = total ?? items.length;
    if (count == 0) return const SizedBox.shrink();
    final shown = items.take(maxVisible).toList();
    final extra = count - shown.length;
    final d = size.diameter + 2 * ringWidth;
    final slots = shown.length + (extra > 0 ? 1 : 0);
    final width = d + (slots - 1) * (d - overlap);
    final scheme = Theme.of(context).colorScheme;
    final names = shown
        .map((e) => e.name)
        .where((n) => n.isNotEmpty)
        .join(', ');
    final label = [
      if (names.isNotEmpty) names,
      if (extra > 0) '+$extra',
    ].join(', ');
    return Semantics(
      container: true,
      label: label.isEmpty ? null : label,
      excludeSemantics: true,
      child: SizedBox(
        width: width,
        height: d,
        child: Stack(
          children: [
            for (var i = 0; i < shown.length; i++)
              Positioned(
                left: i * (d - overlap),
                child: AppAvatar(
                  url: shown[i].url,
                  name: shown[i].name,
                  radius: size.diameter / 2,
                  ring: ringWidth,
                ),
              ),
            if (extra > 0)
              Positioned(
                left: shown.length * (d - overlap),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: scheme.surface,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(ringWidth),
                    child: CircleAvatar(
                      radius: size.diameter / 2,
                      backgroundColor: scheme.surfaceContainerHighest,
                      foregroundColor: scheme.onSurface,
                      child: Text(
                        '+$extra',
                        maxLines: 1,
                        textScaler: TextScaler.noScaling,
                        style: TextStyle(
                          fontSize: size.diameter * 0.36,
                          fontWeight: FontWeight.w600,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
