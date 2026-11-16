import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/privacy_policy_link.dart';
import '../../../core/widgets/shell_geometry.dart';
import '../../settings/presentation/settings_up.dart';
import '../domain/location_copy.dart';
import '../domain/location_models.dart';

/// `/settings/location/consent`: what is stored, why, who sees it and how to
/// withdraw, the copy version, and the "I am 18 or older" tick. Continue is
/// enabled only when ticked and pops a [ConsentGrantData] (nothing is sent
/// here; SetArea carries it).
class LocationRationaleScreen extends StatefulWidget {
  const LocationRationaleScreen({super.key});

  @override
  State<LocationRationaleScreen> createState() =>
      _LocationRationaleScreenState();
}

class _LocationRationaleScreenState extends State<LocationRationaleScreen> {
  bool _adult = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: settingsUpButton(
          context,
          settingsUpLocation(AppRouter.locationConsentPath),
        ),
        title: const Text(kLocationRationaleTitle),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: ShellGeometry.readableMaxWidth(context),
            ),
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.md),
              children: [
                for (final line in const [
                  kLocationRationaleStored,
                  kLocationRationaleWhy,
                  kLocationRationaleWho,
                  kLocationRationalePlans,
                  kLocationRationaleWithdraw,
                ]) ...[
                  Text(line, style: theme.textTheme.bodyLarge),
                  const SizedBox(height: AppSpacing.sm),
                ],
                Text(
                  'Notice version $kLocationConsentCopyVersion',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: PrivacyPolicyLink(),
                ),
                const SizedBox(height: AppSpacing.md),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _adult,
                  onChanged: (v) => setState(() => _adult = v ?? false),
                  title: const Text(kLocationAdultTick),
                ),
                const SizedBox(height: AppSpacing.md),
                FilledButton(
                  onPressed: _adult
                      ? () => context.pop(
                          const ConsentGrantData(
                            copyVersion: kLocationConsentCopyVersion,
                            adultConfirmed: true,
                          ),
                        )
                      : null,
                  child: const Text(kLocationContinue),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
