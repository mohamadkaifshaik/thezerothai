import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/trends_cubit.dart';

/// Asks the shared [TrendsCubit] for the list when it mounts and when the app
/// resumes (W4-17/18). Free while the answer is under five minutes old (0
/// RPCs); past that it is one call shared by every surface. No timer, no
/// polling. Needs [TrendsCubit] in scope: mount it only with `trends` on.
class TrendsLoader extends StatefulWidget {
  const TrendsLoader({super.key, required this.child});

  final Widget child;

  @override
  State<TrendsLoader> createState() => _TrendsLoaderState();
}

class _TrendsLoaderState extends State<TrendsLoader>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // After the first frame: an emit while the tree builds would mark the
    // other surface dirty mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(context.read<TrendsCubit>().ensureLoaded());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      unawaited(context.read<TrendsCubit>().ensureLoaded());
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
