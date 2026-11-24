import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/e2ee/encrypted_messaging.dart';
import '../../domain/e2ee/encryption_access.dart';
import 'encryption_access_builder.dart';

/// Decides ONCE per screen which encrypted port the screen's cubits and
/// widgets use (Plan 5b Task 14, "compute the port once per screen"), and
/// hands it to [builder].
///
/// Before this, the thread cubit, the lazily created composer cubit and the
/// draft's `initState` each read the access at a different time, so a flag
/// or vault change in between could give one cubit the port and another none.
/// Now the answer is taken when the screen opens: access `hidden` (or no
/// provider) gives null (today's plain screen), anything else the provided
/// port. With access `unsupported` (iOS) the provided port is null as well, so
/// the screens fall back to the placeholders and the R11 notice.
///
/// Decision: the answer is NOT re-taken while the screen is open. Why: a
/// screen that changed its mind mid-way could draw a plain composer over an
/// encrypted thread; the port itself fails closed (a send while the vault is
/// not ready is `refused(blocked)`), and the next screen opens with the new
/// answer.
class ScreenEncryptedPort extends StatefulWidget {
  const ScreenEncryptedPort({super.key, required this.builder});

  final Widget Function(BuildContext context, EncryptedMessaging? port) builder;

  @override
  State<ScreenEncryptedPort> createState() => _ScreenEncryptedPortState();
}

class _ScreenEncryptedPortState extends State<ScreenEncryptedPort> {
  late final EncryptedMessaging? _port;

  @override
  void initState() {
    super.initState();
    _port = EncryptionAccessBuilder.of(context) == EncryptionAccess.hidden
        ? null
        : context.read<EncryptedMessaging?>();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _port);
}
