import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/icons/dz_icon.dart';
import 'package:dzeroth/core/icons/dz_icons.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_bottom_bar.dart';
import 'package:dzeroth/core/widgets/app_nav_destination.dart';
import 'package:dzeroth/core/widgets/app_shell_scope.dart';
import 'package:dzeroth/core/widgets/app_tap_area.dart';
import 'package:dzeroth/core/widgets/app_top_bar.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/shared/widgets/post/post_action_bar.dart';
import 'package:dzeroth/shared/widgets/primitives/app_choice_chip.dart';
import 'package:dzeroth/shared/widgets/primitives/app_gradient_fab.dart';
import 'package:dzeroth/shared/widgets/primitives/app_hero_band.dart';
import 'package:dzeroth/shared/widgets/primitives/app_list_row.dart';
import 'package:dzeroth/shared/widgets/primitives/app_media_placeholder.dart';
import 'package:dzeroth/shared/widgets/primitives/app_round_action.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tile_icon.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../support/contrast.dart';
import '../../support/dz_finders.dart';
import '../../support/theme_harness.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// One shared piece of the Dz foundation, and what it must satisfy.
class _Piece {
  const _Piece(
    this.name,
    this.build, {
    this.minTargets = const [],
    this.contrastPairs,
  });

  final String name;
  final Widget Function() build;

  /// Finders whose first match must be at least 44 dp square (tap boxes).
  final List<Finder Function()> minTargets;

  /// Foreground and background colours that must be 3:1 or better (icons and
  /// large text) for the theme; null checks none.
  final List<(Color, Color)> Function(ThemeData theme)? contrastPairs;
}

final _bars = [
  const AppNavDestination(
    icon: Icons.home_outlined,
    selectedIcon: Icons.home,
    label: 'Home',
    dzIcon: DzIcons.home,
    dzFilledWhenSelected: true,
  ),
  const AppNavDestination(
    icon: Icons.search,
    selectedIcon: Icons.manage_search,
    label: 'Explore',
    dzIcon: DzIcons.search,
  ),
  const AppNavDestination(
    icon: Icons.track_changes,
    selectedIcon: Icons.adjust,
    label: 'Plans',
    dzIcon: DzIcons.plans,
  ),
  const AppNavDestination(
    icon: Icons.notifications_none,
    selectedIcon: Icons.notifications,
    label: 'Notifications',
    dzIcon: DzIcons.bell,
    badgeLabel: '1',
  ),
  const AppNavDestination(
    icon: Icons.mail_outline,
    selectedIcon: Icons.mail,
    label: 'Messages',
    dzIcon: DzIcons.mail,
  ),
];

PostActions _actions() => PostActions(
  onReply: () {},
  onRepost: () {},
  onLike: () {},
  onBookmark: () {},
  onShare: () {},
);

Widget _page(Widget child) => Padding(
  padding: const EdgeInsets.all(16),
  child: Align(alignment: Alignment.topLeft, child: child),
);

final _pieces = <_Piece>[
  _Piece(
    'PostActionBar compact',
    () => _page(
      PostActionBar(
        actions: _actions(),
        replyCount: 12,
        repostCount: 3,
        likeCount: 1500,
        liked: true,
      ),
    ),
    minTargets: [() => find.byWidgetPredicate((w) => w is InkResponse)],
    contrastPairs: (t) => [
      (t.extension<AppColors>()!.text2, t.colorScheme.surface),
      (t.extension<AppColors>()!.like, t.colorScheme.surface),
    ],
  ),
  _Piece(
    'PostActionBar spread',
    () => _page(
      PostActionBar(
        actions: _actions(),
        layout: PostActionBarLayout.spread,
        showCounts: false,
      ),
    ),
    minTargets: [() => find.byWidgetPredicate((w) => w is InkResponse)],
  ),
  _Piece(
    'AppFloatingBottomBar',
    () => Align(
      alignment: Alignment.bottomCenter,
      child: AppFloatingBottomBar(
        destinations: _bars,
        selectedIndex: 2,
        onSelected: (_) {},
      ),
    ),
    minTargets: [() => find.byWidgetPredicate((w) => w is InkResponse)],
    contrastPairs: (t) => [
      (AppColors.light.navBarUnselected, AppColors.light.navBarSurface),
      (AppColors.light.navBarSelected, AppFloatingBottomBar.activePill),
    ],
  ),
  _Piece(
    'AppChoiceChip',
    () => _page(
      Wrap(
        spacing: 8,
        children: [
          AppChoiceChip(label: 'Everyone', selected: true, onPressed: () {}),
          AppChoiceChip(label: 'Followers', selected: false, onPressed: () {}),
        ],
      ),
    ),
    minTargets: [() => find.byWidgetPredicate((w) => w is InkResponse)],
  ),
  _Piece(
    'AppHeroBand',
    () => const AppHeroBand(
      child: Padding(
        padding: EdgeInsets.all(8),
        child: Text(
          'Bengaluru builders',
          style: TextStyle(color: AppPalette.white, fontSize: 26),
        ),
      ),
    ),
    contrastPairs: (_) => [(AppPalette.white, AppPalette.navy)],
  ),
  _Piece(
    'AppHeroBand welcome rings',
    () => const SizedBox(
      height: 240,
      child: AppHeroBand(
        rings: AppHeroRings.welcome,
        child: SizedBox(height: 200),
      ),
    ),
  ),
  _Piece(
    'AppListRow',
    () => AppListRow(
      title: 'Bengaluru builders with a rather long list name',
      subtitle: 'People shipping apps in the city, 24 members',
      leading: const AppTileIcon.dz(dzIcon: DzIcons.list),
      trailing: AppRoundAction(
        icon: DzIcons.plus,
        tooltip: 'Add',
        onPressed: () {},
      ),
      onTap: () {},
      divider: true,
    ),
    minTargets: [() => find.byWidgetPredicate((w) => w is InkResponse)],
  ),
  _Piece(
    'AppTileIcon.dz',
    () => _page(const AppTileIcon.dz(dzIcon: DzIcons.gear)),
  ),
  _Piece(
    'AppGradientFab',
    () => Align(
      alignment: Alignment.bottomRight,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: AppGradientFab(
          tooltip: 'New post',
          dzIcon: DzIcons.compose,
          onPressed: () {},
        ),
      ),
    ),
    minTargets: [() => find.byWidgetPredicate((w) => w is InkResponse)],
    contrastPairs: (_) => [(AppPalette.navy, AppPalette.tealElectric)],
  ),
  _Piece(
    'AppRoundAction',
    () => _page(
      AppRoundAction(icon: DzIcons.gear, tooltip: 'Settings', onPressed: () {}),
    ),
    minTargets: [() => find.byWidgetPredicate((w) => w is InkResponse)],
  ),
  _Piece(
    'AppMediaPlaceholder',
    () => const SizedBox(height: 200, child: AppMediaPlaceholder()),
  ),
  _Piece(
    'Every DzIcon',
    () => Wrap(
      children: [for (final icon in DzIcons.all.values) DzIcon(icon, size: 24)],
    ),
  ),
];

void main() {
  late _MockOnboardingBloc onboarding;

  setUp(() {
    onboarding = _MockOnboardingBloc();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(status: OnboardingStatus.ready),
    );
  });

  forEachThemeAndWidth(
    'Dz shared pieces lay out without overflow, with tap boxes and contrast',
    (tester, env) async {
      for (final piece in _pieces) {
        await pumpThemed(
          tester,
          piece.build(),
          brightness: env.brightness,
          size: env.size,
          textScale: env.textScale,
        );
        expect(tester.takeException(), isNull, reason: piece.name);
        for (final target in piece.minTargets) {
          final finder = target();
          expect(finder, findsWidgets, reason: piece.name);
          for (final element in finder.evaluate()) {
            final target = find.byWidget(element.widget).first;
            // The tap area: the drawn box, or the 48 dp AppTapArea around a
            // control the artboards draw at 44.
            final inArea = find
                .ancestor(
                  of: target,
                  matching: find.byWidgetPredicate(
                    (w) => w is AppTapArea && w.mergeSemantics,
                  ),
                )
                .evaluate()
                .isNotEmpty;
            final size = inArea
                ? tapAreaOf(tester, target).size
                : tester.getSize(target);
            // 1e-6: the spread row's boxes sit at fractional offsets, so
            // the area's corners carry float error (47.99999999999997).
            const slack = 1e-6;
            expect(
              size.width >= AppSpacing.minTapTarget - slack &&
                  size.height >= AppSpacing.minTapTarget - slack,
              isTrue,
              reason: '${piece.name}: tap area $size',
            );
          }
        }
        final pairs = piece.contrastPairs?.call(
          buildAppTheme(brightness: env.brightness),
        );
        for (final (fg, bg) in pairs ?? const <(Color, Color)>[]) {
          expect(
            contrast(fg, bg),
            greaterThanOrEqualTo(3),
            reason: '${piece.name} $fg on $bg',
          );
        }
      }
    },
    widths: const [390, 700, 1300],
    textScales: const [1.0, 2.0],
    height: 844,
  );

  forEachThemeAndWidth(
    'Dz headers lay out without overflow',
    (tester, env) async {
      for (final style in [AppTopBarStyle.screen, AppTopBarStyle.back]) {
        await pumpThemed(
          tester,
          BlocProvider<OnboardingBloc>.value(
            value: onboarding,
            child: AppShellScope(
              openDrawer: () {},
              child: Builder(
                builder: (context) => Scaffold(
                  appBar: AppTopBar.of(
                    context,
                    style: style,
                    title: 'A rather long screen title that must not overflow',
                    actions: [
                      AppRoundAction(
                        icon: DzIcons.gear,
                        tooltip: 'Settings',
                        onPressed: () {},
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          brightness: env.brightness,
          size: env.size,
          textScale: env.textScale,
          useScaffold: false,
        );
        expect(tester.takeException(), isNull, reason: '$style');
        // Drawn at the artboards' 44, tapped at 48.
        final action = tester.getSize(find.byType(AppRoundAction));
        expect(action, const Size.square(44));
        expect(
          tapAreaOf(
            tester,
            find.descendant(
              of: find.byType(AppRoundAction),
              matching: find.byType(InkResponse),
            ),
          ).size,
          const Size.square(AppSpacing.minTapTarget),
        );
      }
    },
    widths: const [390, 700, 1300],
    textScales: const [1.0, 2.0],
    height: 844,
  );
}
