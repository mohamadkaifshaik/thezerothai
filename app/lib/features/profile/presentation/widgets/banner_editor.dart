import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import 'profile_cover_band.dart';

/// The profile banner on Edit profile: the 3:1 band as it will look on the
/// profile (the saved banner, the unsaved on-device [previewBytes], or the flat
/// placeholder), with two 48dp buttons on it.
///
/// - [onChange] opens the picker ("Add banner photo" / "Change banner photo");
///   null makes the band read-only (media is off).
/// - [onRemove] drops the banner ("Remove banner photo"); shown only while the
///   band shows a banner; null hides it.
/// - [removed]: the saved banner is to be removed on Save, so the band shows
///   the placeholder instead of [url].
/// - [busy]: a banner is being prepared or the form is saving; the band dims
///   and the buttons ignore taps. [preparing] also shows a spinner.
///
/// The buttons sit on solid theme surfaces with a 1dp border (like the avatar
/// badge), so their contrast does not depend on the picture under them.
class BannerEditor extends StatelessWidget {
  const BannerEditor({
    super.key,
    this.url = '',
    this.previewBytes,
    this.removed = false,
    this.onChange,
    this.onRemove,
    this.busy = false,
    this.preparing = false,
  });

  /// The saved banner (the 600 px thumb is enough for the editor); empty if
  /// none.
  final String url;

  /// The new, unsaved banner, if any.
  final Uint8List? previewBytes;

  final bool removed;
  final VoidCallback? onChange;
  final VoidCallback? onRemove;
  final bool busy;
  final bool preparing;

  /// Whether the band currently shows a banner (a pick, or a saved one that is
  /// not being removed).
  bool get hasBanner => previewBytes != null || (!removed && url.isNotEmpty);

  @override
  Widget build(BuildContext context) {
    final canTap = !busy;
    return AspectRatio(
      aspectRatio: 3,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Opacity(
              opacity: busy ? 0.5 : 1,
              child: ProfileCoverBand(
                url: removed ? '' : url,
                bytes: previewBytes,
              ),
            ),
            Center(
              child: preparing
                  ? Semantics(
                      label: 'Preparing banner photo',
                      liveRegion: true,
                      child: const SizedBox.square(
                        dimension: AppIconSize.xl,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (onChange != null)
                          _BandButton(
                            icon: Icons.photo_camera_outlined,
                            label: hasBanner
                                ? 'Change banner photo'
                                : 'Add banner photo',
                            onTap: canTap ? onChange : null,
                          ),
                        if (onRemove != null && hasBanner) ...[
                          const SizedBox(width: AppSpacing.md),
                          _BandButton(
                            icon: Icons.close,
                            label: 'Remove banner photo',
                            onTap: canTap ? onRemove : null,
                          ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A round 40dp button on the band inside a 48dp tap target.
class _BandButton extends StatelessWidget {
  const _BandButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: label,
      button: true,
      enabled: onTap != null,
      excludeSemantics: true,
      onTap: onTap,
      child: SizedBox.square(
        dimension: AppSpacing.minTapTarget,
        child: InkResponse(
          onTap: onTap,
          radius: AppSpacing.minTapTarget / 2,
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceContainerHigh,
                shape: BoxShape.circle,
                border: Border.all(color: colors.outlineVariant),
              ),
              child: SizedBox.square(
                dimension: AppIconSize.xl,
                child: Icon(icon, size: AppIconSize.md),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
