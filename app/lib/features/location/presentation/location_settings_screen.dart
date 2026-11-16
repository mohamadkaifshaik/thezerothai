import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/shell_geometry.dart';
import '../../../shared/widgets/primitives/headline_message.dart';
import '../../../shared/widgets/primitives/settings_group.dart';
import '../../settings/presentation/settings_up.dart';
import '../domain/location_copy.dart';
import '../domain/location_feature_flag.dart';
import '../domain/location_models.dart';
import 'bloc/location_settings_cubit.dart';
import 'location_error_messages.dart';
import 'widgets/location_settings_scope.dart';

/// Settings > Location (`/settings/location`).
///
/// - `location` on, no area: the explainer and "Choose your area" (the
///   rationale first when no valid consent is stored, then the picker, then
///   SetArea with the consent).
/// - `location` on, area set: the area, "Change area" and "Clear my area"
///   (one tap, no dialog, then the "Location cleared" snackbar).
/// - `location` off with an area stored: only the clear action. Off with
///   none: a short "nothing stored" line. A user can always withdraw.
///
/// Phone, tablet and desktop share this page (the tablet layout adds the up
/// button, the readable column is wider there).
class LocationSettingsScreen extends StatelessWidget {
  const LocationSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: settingsUpButton(
          context,
          settingsUpLocation(AppRouter.locationSettingsPath),
        ),
        title: const Text(kLocationSettingsTitle),
      ),
      body: SafeArea(
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: ShellGeometry.readableMaxWidth(context),
            ),
            child: LocationSettingsScope(
              child: Builder(
                builder: (context) =>
                    context.select<LocationSettingsCubit?, bool>(
                      (cubit) => cubit != null,
                    )
                    ? const _Body()
                    : const HeadlineMessage(
                        title: kLocationOffTitle,
                        body: kLocationOffBody,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body();

  @override
  Widget build(BuildContext context) {
    final flagOn = isFeatureEnabled(context, kFeatureLocation);
    return BlocConsumer<LocationSettingsCubit, LocationSettingsState>(
      listenWhen: (before, after) => before.serial != after.serial,
      listener: (context, state) {
        final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
        final error = state.error;
        if (error != null) {
          messenger.showSnackBar(
            SnackBar(content: Text(locationErrorMessage(error))),
          );
        } else if (state.notice == LocationNotice.cleared) {
          messenger.showSnackBar(
            const SnackBar(content: Text(kLocationCleared)),
          );
        }
      },
      builder: (context, state) {
        final bottom = MediaQuery.paddingOf(context).bottom;
        final padding = EdgeInsets.only(
          top: AppSpacing.md,
          bottom: AppSpacing.lg + bottom,
        );
        if (state.load == LocationLoad.failed) {
          return ListView(
            padding: padding,
            children: [
              AppErrorView(
                error: state.error!,
                onRetry: () =>
                    context.read<LocationSettingsCubit>().load(refresh: true),
              ),
            ],
          );
        }
        if (state.data == null) {
          return ListView(
            padding: padding,
            children: const [
              SettingsGroupPlaceholder(
                rows: 1,
                semanticsLabel: 'Loading location',
              ),
            ],
          );
        }
        final area = state.area;
        if (!flagOn && area == null) {
          return ListView(
            padding: padding,
            children: const [
              HeadlineMessage(title: kLocationOffTitle, body: kLocationOffBody),
            ],
          );
        }
        return ListView(
          padding: padding,
          children: [
            if (!flagOn)
              _Note(kLocationOffStoredNote)
            else if (area == null)
              ..._chooseArea(context, state)
            else
              _Note(kLocationExplainer),
            if (area != null)
              SettingsGroup(
                rows: [
                  SettingsRow(
                    icon: Icons.place_outlined,
                    title: 'Your area',
                    subtitle: area.label,
                    showChevron: false,
                  ),
                  if (flagOn)
                    SettingsRow(
                      icon: Icons.edit_location_alt_outlined,
                      title: kLocationChangeArea,
                      busy: state.busy,
                      onTap: state.busy ? null : () => chooseArea(context),
                    ),
                  SettingsRow(
                    icon: Icons.location_off_outlined,
                    title: kLocationClearArea,
                    destructive: true,
                    showChevron: false,
                    busy: state.busy,
                    onTap: state.busy
                        ? null
                        : () => context.read<LocationSettingsCubit>().clear(),
                  ),
                ],
              ),
            if (area != null) _ConsentDate(state.data?.consent?.at),
          ],
        );
      },
    );
  }

  List<Widget> _chooseArea(BuildContext context, LocationSettingsState state) =>
      [
        _Note(kLocationExplainer),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: FilledButton(
            onPressed: state.busy ? null : () => chooseArea(context),
            child: const Text(kLocationChooseArea),
          ),
        ),
      ];
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.md,
      0,
      AppSpacing.md,
      AppSpacing.md,
    ),
    child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
  );
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

class _ConsentDate extends StatelessWidget {
  const _ConsentDate(this.at);

  final DateTime? at;

  @override
  Widget build(BuildContext context) {
    final at = this.at?.toLocal();
    if (at == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Text(
        'You agreed on ${at.day} ${_months[at.month - 1]} ${at.year}.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// The set flow: the rationale when no valid consent is stored, the picker,
/// then SetArea; a `consent_required` answer runs the rationale again.
Future<void> chooseArea(BuildContext context) async {
  final cubit = context.read<LocationSettingsCubit>();
  ConsentGrantData? grant;
  if (!cubit.state.consentValid) {
    grant = await context.push<ConsentGrantData>(AppRouter.locationConsentPath);
    if (grant == null || !context.mounted) return;
  }
  final area = await context.push<AreaRef>(AppRouter.areaPickerPath);
  if (area == null || !context.mounted) return;
  final result = await cubit.setArea(area, consent: grant);
  if (result != SetAreaResult.consentRequired || !context.mounted) return;
  final fresh = await context.push<ConsentGrantData>(
    AppRouter.locationConsentPath,
  );
  if (fresh == null) return;
  await cubit.setArea(area, consent: fresh);
}
