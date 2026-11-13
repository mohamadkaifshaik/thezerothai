import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import '../../../../shared/widgets/primitives/app_dialog.dart';
import '../../domain/profile_extras_rules.dart';
import '../bloc/edit_profile_cubit.dart';
import 'profile_header.dart';

/// The preview dialog's title (tablet plan section 4.1, EditProfile: *hdr→D*
/// "How others see you").
const kEditProfilePreviewTitle = 'How others see you';

/// The line under the title while the form has edits that are not saved.
const kEditProfilePreviewUnsaved = "Includes changes you haven't saved yet.";

/// The profile others would see if the form were saved now: [saved] with the
/// form's name, bio, location and website (as the save would send them,
/// trimmed and normalized). Counts, the join
/// date, the handle and the badges stay the saved ones.
///
/// An empty name cannot be saved (Save is off), so others keep seeing the
/// saved name: the preview shows it too.
identity.Profile editProfilePreviewProfile(
  identity.Profile saved,
  EditProfileState state,
) {
  final name = normalizeDisplayName(state.displayName);
  final profile = saved.deepCopy()
    ..displayName = name.isEmpty ? saved.displayName : name
    ..bio = normalizeBio(state.bio);
  if (state.extrasEnabled) {
    profile
      ..location = normalizeProfileLocation(state.location)
      ..website = normalizeProfileWebsite(state.website);
  } else {
    if (state.locationRemoved) profile.location = '';
    if (state.websiteRemoved) profile.website = '';
  }
  return profile;
}

/// Opens "How others see you" over Edit profile: the real profile header
/// ([ProfileHeader]) for the form as it stands, inert, in a D 560 dialog on
/// the content area with Close. It follows [cubit] live, so an edit made
/// while it is open (or a picked image) shows at once.
Future<void> showEditProfilePreview(
  BuildContext context, {
  required EditProfileCubit cubit,
  required identity.Profile saved,
  required bool showPostsCount,
}) => showAppDialog<void>(
  context: context,
  maxWidth: AppSize.dialogMax,
  builder: (dialogContext) => AppDialog(
    title: kEditProfilePreviewTitle,
    body: BlocBuilder<EditProfileCubit, EditProfileState>(
      bloc: cubit,
      builder: (context, state) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (cubit.hasChanges) ...[
            const Text(kEditProfilePreviewUnsaved),
            const SizedBox(height: AppSpacing.md),
          ],
          EditProfilePreview(
            profile: editProfilePreviewProfile(saved, state),
            avatarBytes: state.avatarPreview,
            showPostsCount: showPostsCount,
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        style: TextButton.styleFrom(
          minimumSize: const Size(
            AppSpacing.minTapTarget,
            AppSpacing.minTapTarget,
          ),
        ),
        onPressed: () => Navigator.of(dialogContext).pop(),
        child: const Text('Close'),
      ),
    ],
  ),
);

/// The profile header as another person sees it, framed like a page: the
/// same [ProfileHeader] the profile draws (the navy hero: avatar, name,
/// handle, location, bio, meta row and stats), with no
/// controls (no Edit profile, Follow or menu) and nothing to tap. The hero
/// takes its phone or wide look from the width the preview is given.
class EditProfilePreview extends StatelessWidget {
  const EditProfilePreview({
    super.key,
    required this.profile,
    required this.showPostsCount,
    this.avatarBytes,
  });

  final identity.Profile profile;
  final bool showPostsCount;

  /// An unsaved photo (the editor's on-device preview), over the saved one.
  final Uint8List? avatarBytes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(AppRadius.lg);
    return DecoratedBox(
      key: const ValueKey('edit-profile-preview'),
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: ClipRRect(
        borderRadius: radius,
        // The page's own surface and text style, not the dialog body's.
        child: Material(
          color: theme.scaffoldBackgroundColor,
          child: ProfileHeader(
            profile: profile,
            isOwnProfile: true,
            graphEnabled: false,
            showPostsCount: showPostsCount,
            interactive: false,
            style: ProfileHeaderStyle.hero,
            avatarBytes: avatarBytes,
          ),
        ),
      ),
    );
  }
}
