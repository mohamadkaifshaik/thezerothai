import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../domain/e2ee/encrypted_messaging.dart';
import '../../domain/e2ee/encryption_access.dart';
import '../../domain/e2ee/encryption_device.dart';
import 'encryption_access_builder.dart';

/// The two ports one screen uses (Plan 5b Task 14, fix round A).
///
/// - [send]: the provided port, WHATEVER the access is. A send that skips the
///   port goes straight to plaintext `sendMessage` and bypasses the port's
///   fail-closed answers in states that are reachable with the flag off (a
///   marker that could not be read at sign-in, a thread opened at cold start
///   before the sign-in step, a vault wiped here while the conversation stays
///   encrypted on the server). The port is inert for a user with no vault: it
///   reads the cache only, makes no RPC and answers `notEncrypted` for a
///   plain conversation. `hidden` governs what is SHOWN, never whether a send
///   goes through the port.
/// - [read]: the port the screen DRAWS from (the encrypted thread, previews,
///   notes). Null while the access is `hidden`, so a user with no vault sees
///   exactly today's screen.
typedef ScreenPorts = ({EncryptedMessaging? send, EncryptedMessaging? read});

/// Decides which ports one screen uses and hands them to [builder].
///
/// Decision: [ScreenPorts.read] is UPGRADE-ONLY. A screen that opened with no
/// visible port takes it when the access later allows (hidden to a vault or
/// the flag, for example a thread opened at cold start before the sign-in
/// step), and never gives it back (port to null). Why: a screen that took the
/// port away could draw a plain thread over an encrypted one; the port itself
/// fails closed for sends and the next screen opens with the new answer.
class ScreenEncryptedPort extends StatefulWidget {
  const ScreenEncryptedPort({super.key, required this.builder});

  final Widget Function(BuildContext context, ScreenPorts ports) builder;

  @override
  State<ScreenEncryptedPort> createState() => _ScreenEncryptedPortState();
}

class _ScreenEncryptedPortState extends State<ScreenEncryptedPort> {
  late final EncryptedMessaging? _send;
  EncryptedMessaging? _read;
  EncryptionDevice? _device;
  OnboardingBloc? _onboarding;
  void Function()? _removeFlagListener;

  @override
  void initState() {
    super.initState();
    _send = context.read<EncryptedMessaging?>();
    _read = EncryptionAccessBuilder.of(context) == EncryptionAccess.hidden
        ? null
        : _send;
    if (_read == null && _send != null) {
      // Watch the two inputs of the access rule until it opens up.
      _device = context.read<EncryptionDevice?>();
      try {
        _onboarding = context.read<OnboardingBloc>();
      } on ProviderNotFoundException {
        _onboarding = null;
      }
      _device?.vaultStatus.addListener(_recheck);
      final sub = _onboarding?.stream.listen((_) => _recheck());
      _removeFlagListener = () => sub?.cancel();
    }
  }

  void _recheck() {
    if (!mounted || _read != null) return;
    if (EncryptionAccessBuilder.of(context) == EncryptionAccess.hidden) return;
    _stopWatching();
    setState(() => _read = _send);
  }

  void _stopWatching() {
    _device?.vaultStatus.removeListener(_recheck);
    _removeFlagListener?.call();
    _removeFlagListener = null;
    _device = null;
  }

  @override
  void dispose() {
    _stopWatching();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, (send: _send, read: _read));
}
