import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/app_avatar.dart';

/// The profile photo on Edit profile. With [onChange] it is a tap target
/// (48dp minimum, camera badge) that opens the picker; without it (media
/// flag off) it is a plain avatar. A freshly chosen, not yet saved photo is
/// shown from [previewBytes] (the on-device thumbnail), never re-downloaded.
class AvatarEditor extends StatelessWidget {
  const AvatarEditor({
    super.key,
    required this.url,
    this.previewBytes,
    this.onChange,
    this.busy = false,
    this.preparing = false,
  });

  /// The current (saved) avatar URL; empty shows the person icon.
  final String url;

  /// The new, unsaved photo, if any.
  final Uint8List? previewBytes;

  /// Opens the photo picker; null makes the avatar read-only.
  final VoidCallback? onChange;

  /// A photo is being prepared or saved: dim it and ignore taps.
  final bool busy;

  /// The photo is being resized: also shows a spinner over the avatar.
  final bool preparing;

  static const double radius = AppSpacing.xl + AppSpacing.sm;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final avatar = AppAvatar(url: url, radius: radius, bytes: previewBytes);
    final editable = onChange != null;
    final size = radius * 2;

    return Semantics(
      label: editable ? 'Change profile photo' : 'Profile photo',
      button: editable,
      image: !editable,
      enabled: editable ? !busy : null,
      excludeSemantics: true,
      onTap: editable && !busy ? onChange : null,
      child: SizedBox(
        width: size + AppSpacing.sm,
        height: size + AppSpacing.sm,
        child: InkResponse(
          onTap: editable && !busy ? onChange : null,
          radius: radius,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Opacity(opacity: busy ? 0.5 : 1, child: avatar),
              if (preparing)
                const SizedBox.square(
                  dimension: AppIconSize.lg,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              if (editable)
                PositionedDirectional(
                  end: 0,
                  bottom: 0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHigh,
                      shape: BoxShape.circle,
                      border: Border.all(color: colors.outlineVariant),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.all(AppSpacing.xs),
                      child: Icon(
                        Icons.photo_camera_outlined,
                        size: AppIconSize.md,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
