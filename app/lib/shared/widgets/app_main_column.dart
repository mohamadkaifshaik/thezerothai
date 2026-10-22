import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Keeps a full-screen page in the main-column width of the shell on wide
/// screens: centred, at most [AppLayout.mainColumnMaxWidth], between 1dp
/// borders. On a phone it is edge to edge. Purely presentational.
class AppMainColumn extends StatelessWidget {
  const AppMainColumn({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final border = Theme.of(context).colorScheme.outlineVariant;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: AppLayout.mainColumnMaxWidth,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.symmetric(vertical: BorderSide(color: border)),
          ),
          child: child,
        ),
      ),
    );
  }
}
