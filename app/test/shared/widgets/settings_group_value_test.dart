import 'package:dzeroth/shared/widgets/app_status_pill.dart';
import 'package:dzeroth/shared/widgets/settings_group.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/theme_harness.dart';

Widget _group() => SingleChildScrollView(
  child: SettingsGroup(
    title: 'Your account',
    rows: [
      SettingsRow(
        icon: Icons.people_outline,
        title: 'Followers',
        value: Text('1.2K'),
      ),
      SettingsRow(
        icon: Icons.schedule,
        title: 'Voice calls',
        subtitle: 'Talk to people you follow with a much longer line of help',
        value: AppStatusPill(label: 'Coming soon'),
      ),
      SettingsRow(
        icon: Icons.info_outline,
        title: 'Plain',
        trailing: Icon(Icons.add),
      ),
      SettingsRow(
        icon: Icons.tag,
        title: 'Custom',
        value: SizedBox(width: 600, height: 20),
        valueLabel: 'wide thing',
      ),
    ],
  ),
);

void main() {
  forEachThemeAndWidth(
    'static value rows fit and read as one non-button node',
    (tester, env) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(
        tester,
        _group(),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);

      final followers = tester.getSemantics(
        find.bySemanticsLabel('Followers, 1.2K'),
      );
      expect(
        followers.getSemanticsData().hasAction(SemanticsAction.tap),
        false,
      );
      expect(
        find.bySemanticsLabel(RegExp(r'^Voice calls, Coming soon')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Custom, wide thing'), findsOneWidget);
      // The pill and the value text are not separate nodes.
      expect(find.bySemanticsLabel('Coming soon'), findsNothing);
      expect(find.bySemanticsLabel('1.2K'), findsNothing);
      // `trailing` stays ignored without onTap.
      expect(find.byIcon(Icons.add), findsNothing);
      handle.dispose();
    },
    textScales: kMatrixTextScalesLarge,
  );

  testWidgets('value sits at the row end at 1.0 and under the title at 1.3', (
    tester,
  ) async {
    await pumpThemed(tester, _group(), size: const Size(600, 800));
    var title = tester.getTopLeft(find.text('Followers'));
    var value = tester.getTopLeft(find.text('1.2K'));
    expect(value.dx, greaterThan(title.dx + 100));
    expect(value.dy, lessThan(title.dy + 8));

    await pumpThemed(
      tester,
      _group(),
      size: const Size(600, 800),
      textScale: 1.3,
    );
    title = tester.getTopLeft(find.text('Followers'));
    value = tester.getTopLeft(find.text('1.2K'));
    expect(value.dx, title.dx);
    expect(value.dy, greaterThan(title.dy));
  });
}
