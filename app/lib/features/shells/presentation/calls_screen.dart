import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../shared/widgets/app_back_header.dart';
import '../../../shared/widgets/app_empty_view.dart';
import '../../../shared/widgets/app_main_column.dart';

/// Calls (`/calls`, a shell of plan W8): a placeholder page, no RPC, no
/// repository and no permission. W8-7 replaces the body; the frame stays.
class CallsScreen extends StatelessWidget {
  const CallsScreen({super.key});

  static const title = 'Calls';

  @override
  Widget build(BuildContext context) {
    return AppMainColumn(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppBackHeader(
            title: title,
            onBack: () => context.canPop()
                ? context.pop()
                : context.go(AppRouter.homePath),
          ),
          const Expanded(
            child: SingleChildScrollView(
              child: AppEmptyView(
                icon: Icons.call_outlined,
                title: 'Coming soon',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
