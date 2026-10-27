import 'package:dzeroth/shared/widgets/app_side_column.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/theme_harness.dart';

void main() {
  Widget column({List<Widget> sections = const []}) => AppSideColumn(
    profile: AppSideProfile(
      displayName: 'Alice A',
      handle: 'alice',
      avatarUrl: '',
      onTap: () {},
    ),
    sections: sections,
    links: [
      AppSideLink(
        icon: Icons.settings_outlined,
        label: 'Settings',
        onTap: () {},
      ),
    ],
  );

  testWidgets('sections sit between the profile card and the links, in '
      'order', (tester) async {
    await pumpThemed(
      tester,
      column(sections: const [Text('first'), Text('second')]),
      size: const Size(350, 800),
    );

    final profile = tester.getTopLeft(find.text('@alice')).dy;
    final first = tester.getTopLeft(find.text('first')).dy;
    final second = tester.getTopLeft(find.text('second')).dy;
    final links = tester.getTopLeft(find.text('Settings')).dy;
    expect(profile, lessThan(first));
    expect(first, lessThan(second));
    expect(second, lessThan(links));
  });

  testWidgets('without sections the column is as before', (tester) async {
    await pumpThemed(tester, column(), size: const Size(350, 800));

    expect(find.text('@alice'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
