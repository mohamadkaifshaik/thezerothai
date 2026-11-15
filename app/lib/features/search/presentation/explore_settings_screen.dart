import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/widgets/shell_geometry.dart';
import '../../../shared/widgets/primitives/settings_group.dart';
import '../../location/domain/location_copy.dart';
import '../../location/presentation/bloc/location_settings_cubit.dart';
import '../../location/presentation/widgets/location_settings_scope.dart';

/// `/explore/settings` (F8): one group, "Nearby", with one row, "Your area":
/// the area name or "Not set", opening Settings > Location. Nothing else (no
/// other toggles). The Explore gear opens it while `location` is on.
class ExploreSettingsScreen extends StatelessWidget {
  const ExploreSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(kExploreSettingsTitle)),
      body: SafeArea(
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: ShellGeometry.readableMaxWidth(context),
            ),
            child: LocationSettingsScope(
              child: ListView(
                padding: const EdgeInsets.only(top: 16),
                children: [
                  SettingsGroup(
                    title: kExploreSettingsNearbyGroup,
                    rows: [
                      Builder(
                        builder: (context) {
                          final area = context
                              .select<LocationSettingsCubit?, String?>(
                                (cubit) => cubit?.state.area?.label,
                              );
                          return SettingsRow(
                            icon: Icons.place_outlined,
                            title: kExploreSettingsAreaRow,
                            subtitle: area ?? kLocationNotSet,
                            onTap: () =>
                                context.push(AppRouter.locationSettingsPath),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
