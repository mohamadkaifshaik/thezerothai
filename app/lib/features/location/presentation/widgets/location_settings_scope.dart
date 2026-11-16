import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../data/location_repository.dart';
import '../bloc/location_settings_cubit.dart';

/// Gives [child] a [LocationSettingsCubit] for the signed-in account and loads
/// it (one memoised read per session). Without a [LocationRepository] in the
/// tree (a test harness) or nobody signed in, [child] gets no cubit and every
/// location surface stays hidden.
class LocationSettingsScope extends StatelessWidget {
  const LocationSettingsScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final repository = context.read<LocationRepository?>();
    final uid = context.select((AuthBloc bloc) => bloc.state.user?.uid);
    if (repository == null || uid == null || uid.isEmpty) return child;
    return BlocProvider<LocationSettingsCubit>(
      key: ValueKey(uid),
      create: (_) => LocationSettingsCubit(repository: repository)..load(),
      child: child,
    );
  }
}
