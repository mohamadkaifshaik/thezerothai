import 'package:material_ui/material_ui.dart';

import '../../../../core/network/app_exception.dart' show SessionEndedException;

/// Why the user is on the sign-in screens after the server ended their
/// session because a device was removed from the account (lane D PR 4,
/// ruling 2; removal design §4). Shown only while
/// `AuthState.signedOutByDeviceRemoval` is set. The text is fixed
/// ([SessionEndedException.userMessage]) and names no device.
class SessionEndedNotice extends StatelessWidget {
  const SessionEndedNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Text(
        SessionEndedException.userMessage,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.error,
        ),
      ),
    );
  }
}
