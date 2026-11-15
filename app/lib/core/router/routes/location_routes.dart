import 'package:go_router/go_router.dart';

import '../../../features/auth/presentation/widgets/auth_gate.dart';
import '../../../features/location/presentation/area_picker_screen.dart';
import '../app_router.dart';

/// Root-level (full screen) location routes: the area picker, which pops the
/// chosen `AreaRef`. Needs `location` (`_locationFlagRedirect`).
List<RouteBase> locationRootRoutes() => [
  GoRoute(
    path: AppRouter.areaPickerPath,
    builder: (context, state) => const AuthGate(child: AreaPickerScreen()),
  ),
];
