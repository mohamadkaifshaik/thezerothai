import 'package:material_ui/material_ui.dart';

import '../../../../core/network/app_exception.dart' show SessionEndedException;
import '../../../messages/presentation/e2ee/encryption_copy.dart'
    show kSignedOutAfterOwnRemovalNotice;

/// Why the user is on the sign-in screens after a device removal ended their
/// session. Two causes, two texts, neither naming a device:
/// - the server ended this session because a device was removed from the
///   account elsewhere (lane D PR 4, ruling 2; removal design §4), while
///   `AuthState.signedOutByDeviceRemoval` is set:
///   [SessionEndedException.userMessage];
/// - THIS device removed another one and so signed every device out, itself
///   included (H1; controller ruling 2026-11-27), while
///   `AuthState.signedOutAfterOwnRemoval` is set ([afterOwnRemoval]):
///   [kSignedOutAfterOwnRemovalNotice].
class SessionEndedNotice extends StatelessWidget {
  const SessionEndedNotice({super.key, this.afterOwnRemoval = false});

  /// The remover's text instead of the removed device's.
  final bool afterOwnRemoval;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Text(
        afterOwnRemoval
            ? kSignedOutAfterOwnRemovalNotice
            : SessionEndedException.userMessage,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.error,
        ),
      ),
    );
  }
}
