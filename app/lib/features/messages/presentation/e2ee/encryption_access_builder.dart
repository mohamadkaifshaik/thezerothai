import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/feature_flags/feature_flags.dart';
import '../../../../core/vault/vault_status.dart';
import '../../domain/e2ee/encryption_access.dart';
import '../../domain/e2ee/encryption_device.dart';
import '../../domain/messaging_feature_flag.dart';

/// Rebuilds on the flag set (OnboardingBloc) and on EncryptionDevice.vaultStatus. No EncryptionDevice in the
/// tree => EncryptionAccess.hidden, whatever the flag says.
///
/// It does not read `EncryptionDevice.flag`: the flag set of `enabled_features`
/// is the input, and the access rule decides. `device.vaultKnown` is read
/// whenever `vaultStatus` notifies, so the production adapter (Task 14) must
/// notify `vaultStatus` when `vaultKnown` changes.
class EncryptionAccessBuilder extends StatelessWidget {
  const EncryptionAccessBuilder({super.key, required this.builder});

  final Widget Function(BuildContext context, EncryptionAccess access) builder;

  /// One-off read for callbacks (no rebuild).
  static EncryptionAccess of(BuildContext context) {
    final device = _device(context);
    if (device == null) return EncryptionAccess.hidden;
    return encryptionAccessOf(
      flagOn: featureEnabledSnapshot(context, kFeatureE2eeDm),
      vaultKnown: device.vaultKnown,
      status: device.vaultStatus.value,
    );
  }

  static EncryptionDevice? _device(BuildContext context) {
    try {
      return context.read<EncryptionDevice>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final flagOn = isFeatureEnabled(context, kFeatureE2eeDm);
    final device = _device(context);
    if (device == null) return builder(context, EncryptionAccess.hidden);
    return ValueListenableBuilder<VaultStatus>(
      valueListenable: device.vaultStatus,
      builder: (context, status, _) => builder(
        context,
        encryptionAccessOf(
          flagOn: flagOn,
          vaultKnown: device.vaultKnown,
          status: status,
        ),
      ),
    );
  }
}
