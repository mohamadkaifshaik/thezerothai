import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/primitives/app_empty_view.dart';
import 'package:dzeroth/shared/widgets/primitives/app_notice_banner.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:dzeroth/shared/widgets/primitives/app_section_header.dart';
import 'package:dzeroth/shared/widgets/primitives/app_status_pill.dart';
import 'package:dzeroth/shared/widgets/primitives/app_surface.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tab_bar.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tile_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/theme_harness.dart';

/// The existing primitives and Material defaults under the navy and pearl
/// schemes (PR 1.3): every cell of the redesign matrix builds without an
/// exception and the page is the scheme surface. Goldens are opt-in.
class _Gallery extends StatelessWidget {
  const _Gallery();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        AppTabBar(
          tabs: const [
            AppTab(label: 'For you'),
            AppTab(label: 'Following'),
          ],
          selectedIndex: 1,
          onChanged: (_) {},
        ),
        const AppSectionHeader(title: 'Section', subtitle: 'Muted subtitle'),
        const AppSurface(child: Text('A raised surface')),
        const AppNoticeBanner(message: 'You are offline'),
        const Wrap(
          spacing: AppSpacing.sm,
          children: [
            AppStatusPill(label: 'Coming soon'),
            AppStatusPill(label: 'Info', tone: AppStatusTone.info),
            AppTileIcon(icon: Icons.bookmark),
          ],
        ),
        AppPillButton(label: 'Post', onPressed: () {}),
        const AppPillButton(label: 'Disabled', onPressed: null),
        FilledButton(onPressed: () {}, child: const Text('Filled')),
        OutlinedButton(onPressed: () {}, child: const Text('Outlined')),
        TextButton(onPressed: () {}, child: const Text('Text')),
        const Badge(label: Text('3'), child: Icon(Icons.notifications_none)),
        const LinearProgressIndicator(value: 0.4),
        const TextField(decoration: InputDecoration(hintText: 'Hint')),
        const AppEmptyView(
          icon: Icons.inbox_outlined,
          title: 'Nothing here yet',
          subtitle: 'Posts show up here.',
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: FloatingActionButton(
            onPressed: () {},
            tooltip: 'New post',
            child: const Icon(Icons.add),
          ),
        ),
      ],
    );
  }
}

void main() {
  forEachThemeAndWidth(
    'the primitive gallery builds on the redesign schemes',
    (tester, env) async {
      await pumpThemed(
        tester,
        const _Gallery(),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      final page =
          scaffold.backgroundColor ??
          Theme.of(tester.element(find.byType(_Gallery)))
              .scaffoldBackgroundColor;
      expect(page, env.isDark ? AppPalette.navy : AppPalette.pearl);
      await expectGolden(tester, find.byType(_Gallery), 'palette_gallery', env);
    },
    widths: kRedesignWidths,
    textScales: kRedesignTextScales,
    heights: kRedesignHeights,
  );
}
