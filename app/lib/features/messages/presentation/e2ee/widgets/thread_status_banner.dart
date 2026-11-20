import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../../core/router/app_router.dart';
import '../encryption_status.dart';
import '../encryption_status_banner.dart';

/// The status banner above the composer of a thread (Plan 5b Task 5, the
/// re-read N2 rule): drawn only while the status blocks messaging, because
/// every send is refused then. Details opens the Settings page. Nothing is
/// drawn, and nothing is added to the tree, without a status cubit.
class ConnectedThreadStatusBanner extends StatelessWidget {
  const ConnectedThreadStatusBanner({super.key, required this.child});

  /// The area the banner sits above (the composer, say).
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cubit = context.watch<EncryptionStatusCubit?>();
    if (cubit == null) return child;
    // One stable shape while a cubit exists, so the composer keeps its state
    // (typed text) when the banner comes and goes.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        BlocBuilder<EncryptionStatusCubit, EncryptionStatus>(
          bloc: cubit,
          builder: (context, status) => status.blocksMessaging
              ? EncryptionStatusBanner(
                  status: status,
                  onDetails: () => unawaited(
                    context.push<void>(AppRouter.encryptionSettingsPath),
                  ),
                  onDismissHistoryLost: cubit.dismissHistoryLost,
                )
              : const SizedBox.shrink(),
        ),
        child,
      ],
    );
  }
}
