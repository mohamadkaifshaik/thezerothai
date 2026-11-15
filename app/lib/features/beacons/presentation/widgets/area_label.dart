import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/feature_flags/feature_flags.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../../../gen/dzeroth/location/v1/location.pb.dart' as loc;
import '../../../../gen/dzeroth/location/v1/location.pbenum.dart' show AreaKind;
import '../../../location/domain/location_feature_flag.dart';

/// Whether `location` is on for the caller (false when no session is above,
/// as in some tests). [listen] false is for event handlers.
bool areaLabelsEnabled(BuildContext context, {bool listen = true}) {
  final read = listen ? isFeatureEnabled : featureEnabledSnapshot;
  try {
    return read(context, kFeatureLocation);
  } on ProviderNotFoundException {
    return false;
  }
}

/// Whether a plan with [area] shows its area line: set, and `location` on.
bool showsAreaLabel(BuildContext context, loc.AreaSummary? area) =>
    area != null && area.areaId.isNotEmpty && areaLabelsEnabled(context);

/// The text a plan's area reads as: with a [proximity] (Nearby rows) "In
/// your area", "Nearby: AREA" or "In CITY"; without one the area name
/// (a city area is just its city). No distances, ever.
String areaLabelText(loc.AreaSummary area, [pb.AreaProximity? proximity]) {
  final name = area.name;
  final city = area.cityName.isEmpty ? name : area.cityName;
  return switch (proximity) {
    pb.AreaProximity.AREA_PROXIMITY_SAME_AREA => 'In your area',
    pb.AreaProximity.AREA_PROXIMITY_NEIGHBOURING => 'Nearby: $name',
    pb.AreaProximity.AREA_PROXIMITY_SAME_CITY => 'In $city',
    _ =>
      area.kind == AreaKind.AREA_KIND_CITY ||
              area.cityName.isEmpty ||
              area.cityName == name
          ? name
          : '$name, ${area.cityName}',
  };
}

/// A small place icon and the plan's area (plan cards, the plan page).
/// Draws nothing, not even a gap, when [area] is unset or `location` is off.
/// [onDark] is for the navy hero of the plan page.
class AreaLabel extends StatelessWidget {
  const AreaLabel({
    super.key,
    required this.area,
    this.proximity,
    this.onDark = false,
  });

  final loc.AreaSummary? area;
  final pb.AreaProximity? proximity;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final a = area;
    if (a == null || !showsAreaLabel(context, a)) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final color = onDark
        ? AppPalette.pearl
        : theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.place_outlined,
          size: AppIconSize.sm,
          color: onDark ? AppPalette.tealElectric : color,
        ),
        const SizedBox(width: AppSpacing.xs),
        Flexible(
          child: Text(
            areaLabelText(a, proximity),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
