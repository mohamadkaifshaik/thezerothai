import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shell_geometry.dart';
import '../../../shared/widgets/primitives/settings_group.dart';
import '../domain/data_usage.dart';
import 'bloc/data_usage_cubit.dart';
import 'data_usage_messages.dart';
import 'settings_up.dart';
import 'widgets/settings_choice_row.dart';

/// Settings > Data usage (`/settings/data-usage`): Data saver, High-quality
/// images and High-quality uploads. Device-level, 0 RPCs; each choice applies
/// at once. Needs a [DataUsageCubit] above it.
class DataUsageScreen extends StatelessWidget {
  const DataUsageScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // The tablet layout with nothing to pop: up to Display.
        leading: settingsUpButton(
          context,
          settingsUpLocation(AppRouter.dataUsagePath),
        ),
        title: const Text(kDataUsageTitle),
      ),
      body: SafeArea(
        // The floating bar overlays the page: the content scrolls behind it
        // and ends with the bar's inset.
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: ShellGeometry.readableMaxWidth(context),
            ),
            child: const DataUsageBody(),
          ),
        ),
      ),
    );
  }
}

/// The page's content: one group of three rows and the web note.
class DataUsageBody extends StatelessWidget {
  const DataUsageBody({super.key});

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<DataUsageCubit>();
    final dataSaver = context.select((DataUsageCubit c) => c.state.dataSaver);
    final images = context.select((DataUsageCubit c) => c.state.images);
    final uploads = context.select((DataUsageCubit c) => c.state.uploads);
    final loaded = context.select((DataUsageCubit c) => c.state.loaded);
    final theme = Theme.of(context);
    return ListView(
      padding: EdgeInsets.only(
        top: AppSpacing.md,
        bottom: AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        SettingsGroup(
          rows: [
            SettingsRow(
              icon: Icons.data_saver_on_outlined,
              title: kDataSaverTitle,
              subtitle: kDataSaverSubtitle,
              subtitleMaxLines: 4,
              toggled: dataSaver,
              onTap: loaded ? () => cubit.setDataSaver(!dataSaver) : null,
            ),
            SettingsChoiceRow<HighQualityImages>(
              icon: Icons.high_quality_outlined,
              title: kHighQualityImagesTitle,
              selected: images,
              note: dataSaver ? kHighQualityImagesOffByDataSaver : null,
              choices: [
                for (final v in HighQualityImages.values)
                  SettingsChoice(v, v.label),
              ],
              onSelected: loaded ? cubit.setImages : null,
            ),
            SettingsChoiceRow<HighQualityUploads>(
              icon: Icons.cloud_upload_outlined,
              title: kHighQualityUploadsTitle,
              selected: uploads,
              note: kHighQualityUploadsNote,
              choices: [
                for (final v in HighQualityUploads.values)
                  SettingsChoice(v, v.label),
              ],
              onSelected: loaded ? cubit.setUploads : null,
            ),
          ],
        ),
        if (!cubit.canDistinguishNetwork)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Text(
              kDataUsageWebNote,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}
