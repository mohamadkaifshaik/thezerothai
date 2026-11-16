import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/widgets/shell_geometry.dart';
import '../../../shared/widgets/primitives/app_empty_view.dart';
import '../data/location_repository.dart';
import '../domain/area_search.dart';
import '../domain/location_copy.dart';
import '../domain/location_models.dart';
import 'bloc/area_picker_cubit.dart';

/// `/area-picker` (root, full screen): a searchable list of areas grouped by
/// city, each city with an "All of `<city>`" row. Pops the chosen [AreaRef]
/// (null when dismissed). Reusable by plan create and edit.
class AreaPickerScreen extends StatelessWidget {
  const AreaPickerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repository = context.read<LocationRepository?>();
    return Scaffold(
      appBar: AppBar(title: const Text(kLocationPickerTitle)),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: ShellGeometry.readableMaxWidth(context),
            ),
            child: repository == null
                ? const AppEmptyView(title: kLocationPickerEmptyTitle)
                : BlocProvider(
                    create: (_) =>
                        AreaPickerCubit(repository: repository)..load(),
                    child: const _PickerBody(),
                  ),
          ),
        ),
      ),
    );
  }
}

class _PickerBody extends StatelessWidget {
  const _PickerBody();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: TextField(
            autofocus: false,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: kLocationSearchHint,
            ),
            onChanged: context.read<AreaPickerCubit>().search,
          ),
        ),
        Expanded(
          child: BlocBuilder<AreaPickerCubit, AreaPickerState>(
            builder: (context, state) {
              if (state.load == AreaPickerLoad.loading) {
                return const Center(child: CircularProgressIndicator());
              }
              if (state.load == AreaPickerLoad.failed) {
                return AppErrorView(
                  error:
                      state.error ??
                      const NetworkException("Couldn't load areas."),
                  onRetry: context.read<AreaPickerCubit>().load,
                );
              }
              final groups = groupByCity(state.results, state.areas);
              if (groups.isEmpty) {
                return const AppEmptyView(
                  icon: Icons.search_off,
                  title: kLocationPickerEmptyTitle,
                  subtitle: kLocationPickerEmptyBody,
                );
              }
              return ListView.builder(
                itemCount: groups.length,
                itemBuilder: (context, i) => _GroupTile(group: groups[i]),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _GroupTile extends StatelessWidget {
  const _GroupTile({required this.group});

  final AreaGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final city = group.city;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.xs,
          ),
          child: Text(
            group.cityName,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if (city != null)
          ListTile(
            leading: const Icon(Icons.location_city_outlined),
            title: Text(locationAllOf(group.cityName)),
            onTap: () => context.pop(city),
          ),
        for (final area in group.areas)
          ListTile(
            leading: const Icon(Icons.place_outlined),
            title: Text(area.name),
            onTap: () => context.pop(area),
          ),
      ],
    );
  }
}
