import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/primitives/app_avatar.dart';
import '../../../shared/widgets/primitives/app_pill_button.dart';
import '../../auth/presentation/widgets/auth_page_layout.dart' show AuthFrame;
import '../../media/data/image_picker_service.dart';
import '../../media/data/media_repository.dart';
import '../../media/data/media_uploader.dart';
import '../../media/domain/image_processor.dart';
import '../../media/domain/media_feature_flag.dart';
import '../../profile/presentation/bloc/edit_profile_cubit.dart';
import '../../profile/presentation/profile_edit_error_messages.dart';
import '../data/identity_repository.dart';
import 'bloc/onboarding_bloc.dart';
import 'bloc/onboarding_event.dart';

/// Right after this session's CreateProfile, with `media` on: an optional,
/// skippable "Add a profile photo" step (the CreateProfile mock's 84 dp dashed
/// circle). It reuses [EditProfileCubit]'s avatar path (pick, resize on the
/// device, upload, UpdateProfile with the media id), so the gating and the
/// error copy are Edit profile's. Skip stores nothing.
class ProfilePhotoStepScreen extends StatelessWidget {
  const ProfilePhotoStepScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final profile = context.read<OnboardingBloc>().state.profile;
    final mediaEnabled = featureEnabledSnapshot(context, kFeatureMedia);
    if (profile == null || !mediaEnabled) {
      // The router keeps this page for a media-on, profiled caller only.
      return const _LeaveOnBuild();
    }
    return BlocProvider<EditProfileCubit>(
      create: (context) => EditProfileCubit(
        identityRepository: context.read<IdentityRepository>(),
        initial: profile,
        onUnexpectedError: context.read<UnexpectedErrorReporter>(),
        picker: context.read<ImagePickerService>(),
        processor: context.read<ImageProcessor>(),
        uploader: MediaUploader(
          repository: context.read<MediaRepository>(),
          onUnexpectedError: context.read<UnexpectedErrorReporter>(),
        ),
      ),
      child: const _PhotoStepView(),
    );
  }
}

/// Finishes the step as soon as it is built (media went off, or no profile).
class _LeaveOnBuild extends StatefulWidget {
  const _LeaveOnBuild();

  @override
  State<_LeaveOnBuild> createState() => _LeaveOnBuildState();
}

class _LeaveOnBuildState extends State<_LeaveOnBuild> {
  @override
  void initState() {
    super.initState();
    scheduleMicrotask(() {
      if (mounted) {
        context.read<OnboardingBloc>().add(const OnboardingPhotoStepFinished());
      }
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _PhotoStepView extends StatelessWidget {
  const _PhotoStepView();

  void _finish(BuildContext context) =>
      context.read<OnboardingBloc>().add(const OnboardingPhotoStepFinished());

  void _onState(BuildContext context, EditProfileState state) {
    final saved = state.saved;
    if (state.status == EditProfileStatus.saved && saved != null) {
      final bloc = context.read<OnboardingBloc>();
      bloc.add(OnboardingProfileUpdated(saved));
      bloc.add(const OnboardingPhotoStepFinished());
      return;
    }
    final message = editProfileErrorMessage(state);
    if (message == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
    context.read<EditProfileCubit>().errorShown();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<EditProfileCubit>();
    final theme = Theme.of(context);
    return BlocConsumer<EditProfileCubit, EditProfileState>(
      listener: _onState,
      builder: (context, state) {
        final chosen = state.avatarPreview != null;
        final busy = state.isSaving || state.isPreparingAvatar;
        final skip = TextButton(
          onPressed: state.isSaving ? null : () => _finish(context),
          child: const Text('Skip'),
        );
        return AuthFrame(
          eyebrow: 'Welcome to Dzeroth',
          headline: 'Add a profile ',
          accent: 'photo',
          heroEyebrow: 'Good things start with a plan',
          heroHeadline: 'Put a face\nto the ',
          heroAccent: 'name',
          phoneAction: skip,
          actions: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppPillButton(
                label: chosen ? 'Save photo' : 'Choose a photo',
                size: AppButtonSize.large,
                busy: busy,
                onPressed: chosen
                    ? (cubit.canSave ? () => unawaited(cubit.save()) : null)
                    : () => unawaited(cubit.pickAvatar()),
              ),
              if (chosen && !busy) ...[
                const SizedBox(height: AppSpacing.sm),
                TextButton(
                  onPressed: () => unawaited(cubit.pickAvatar()),
                  child: const Text('Choose a different photo'),
                ),
              ],
            ],
          ),
          wideFooter: Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: Center(child: skip),
          ),
          children: [
            Row(
              children: [
                _PhotoCircle(
                  preview: state.avatarPreview,
                  busy: busy,
                  onTap: () => unawaited(cubit.pickAvatar()),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    'A friendly photo helps people nearby say hello.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// The 84 dp dashed teal circle with a camera; once a photo is picked it is
/// replaced by the photo. One tap target.
class _PhotoCircle extends StatelessWidget {
  const _PhotoCircle({
    required this.preview,
    required this.busy,
    required this.onTap,
  });

  final Uint8List? preview;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const d = AppPhotoStepLayout.circle;
    final bytes = preview;
    return Semantics(
      button: true,
      enabled: !busy,
      label: bytes == null ? 'Add a photo' : 'Change photo',
      excludeSemantics: true,
      onTap: busy ? null : onTap,
      child: SizedBox.square(
        dimension: d,
        child: InkResponse(
          key: const ValueKey('photo-step-circle'),
          onTap: busy ? null : onTap,
          customBorder: const CircleBorder(),
          child: bytes == null
              ? CustomPaint(
                  foregroundPainter: _DashedCircle(color: colors.primary),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: colors.primary.withValues(
                        alpha: AppPhotoStepLayout.fillAlpha,
                      ),
                    ),
                    child: Icon(
                      Icons.photo_camera_outlined,
                      size: AppPhotoStepLayout.cameraIcon,
                      color: colors.primary,
                    ),
                  ),
                )
              : Stack(
                  alignment: Alignment.center,
                  children: [
                    Opacity(
                      opacity: busy ? 0.5 : 1,
                      child: AppAvatar(url: '', radius: d / 2, bytes: bytes),
                    ),
                    if (busy)
                      const SizedBox.square(
                        dimension: AppIconSize.lg,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _DashedCircle extends CustomPainter {
  const _DashedCircle({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = AppPhotoStepLayout.border;
    final ring = Path()
      ..addOval((Offset.zero & size).deflate(AppPhotoStepLayout.border / 2));
    for (final PathMetric m in ring.computeMetrics()) {
      for (
        var at = 0.0;
        at < m.length;
        at += AppPhotoStepLayout.dash + AppPhotoStepLayout.dashGap
      ) {
        canvas.drawPath(m.extractPath(at, at + AppPhotoStepLayout.dash), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedCircle old) => old.color != color;
}
