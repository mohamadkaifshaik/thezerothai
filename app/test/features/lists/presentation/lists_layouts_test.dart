import 'dart:io';
import 'dart:ui' as ui;

import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/lists/presentation/widgets/list_row.dart';
import 'package:dzeroth/shared/widgets/primitives/app_back_header.dart';
import 'package:dzeroth/shared/widgets/primitives/app_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/app_fonts.dart';
import '../../../support/lists_tablet_rig.dart';

// Lists, ListDetail, ListMembers, ManagePinned and UserLists from the
// dzeroth-mobile, tablet and desktop mocks: one set of actions at every
// width. The phone has the 20 dp gutter, navy tiles, a raised create button
// and the List's Back inside its hero; tablet and desktop share the flat
// rows, the chevron, a top bar and the uppercase section label.

const _screenshots = bool.fromEnvironment('LISTS_SCREENSHOTS');

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_screenshots) return;
  await tester.runAsync(() async {
    final image = await captureImage(tester.element(find.byType(MaterialApp)));
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/artifacts/lists/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

const _sizes = <String, Size>{
  'phone': Size(390, 844),
  'tablet': Size(1024, 768),
  'desktop': Size(1440, 900),
};

enum _Screen { lists, detail, members, pinned, userLists }

/// Opens [screen] as the app does (a push over the page it comes from), as
/// the owner of [kRigListId], which is also pinned to Home.
Future<ListsTabletRig> _open(
  WidgetTester tester,
  _Screen screen,
  Size size, {
  Brightness brightness = Brightness.light,
  double textScale = 1,
  bool owner = true,
}) async {
  final rig = ListsTabletRig();
  rig.server.viewerOwnsList = owner;
  rig.server.pinRigList();
  final listPath = AppRouter.listPath(kRigListId);
  final (location, push) = switch (screen) {
    _Screen.lists => (AppRouter.listsPath, const <String>[]),
    _Screen.detail => (AppRouter.listsPath, [listPath]),
    _Screen.members => (
      AppRouter.listsPath,
      [listPath, AppRouter.listMembersPath(kRigListId)],
    ),
    _Screen.pinned => (AppRouter.homePath, [AppRouter.pinnedPath]),
    _Screen.userLists => (
      AppRouter.profilePath('olivia'),
      [AppRouter.userListsPath(kRigOwnerId)],
    ),
  };
  await rig.pump(
    tester,
    location: location,
    push: push,
    pushExtra: screen == _Screen.userLists ? 'olivia' : null,
    width: size.width,
    height: size.height,
    brightness: brightness,
    textScale: textScale,
  );
  return rig;
}

void main() {
  setUpAll(() async {
    if (_screenshots) await loadAppFonts();
  });

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    final phone = size.width < 600;

    group('$name (${size.width.toInt()} dp)', () {
      testWidgets('Lists: the look', (tester) async {
        await _open(tester, _Screen.lists, size);
        expect(find.text('Pinned'), findsOneWidget);
        expect(find.text('Manage'), findsOneWidget);
        expect(find.text('Your Lists'), findsOneWidget);
        // Pinned Friends leaves "Your Lists": each List shows once.
        expect(find.text('Friends'), findsOneWidget);
        expect(find.text('Books'), findsOneWidget);
        expect(find.text('Alice A · 3 members'), findsOneWidget);
        expect(
          tester.getSize(find.byType(ListTileIcon).first),
          const Size.square(52),
        );
        // The phone leads with Back and marks the pin; the wide mocks have a
        // rail (no Back), the viewer's @handle and a chevron.
        expect(find.byTooltip('Back'), phone ? findsOneWidget : findsNothing);
        expect(
          inListsPage(find.text('@alice')),
          phone ? findsNothing : findsOneWidget,
        );
        expect(
          find.byIcon(Icons.push_pin),
          phone ? findsOneWidget : findsNothing,
        );
        expect(
          find.byIcon(Icons.chevron_right),
          phone ? findsNothing : findsNWidgets(2),
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('Lists: Create, Edit, Manage and a row', (tester) async {
        var rig = await _open(tester, _Screen.lists, size);
        await tester.tap(find.byTooltip('Create a new List'));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(TextField, 'Name'), findsOneWidget);

        rig = await _open(tester, _Screen.lists, size);
        await tester.tap(find.byTooltip('Edit Books'));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(TextField, 'Name'), findsOneWidget);

        rig = await _open(tester, _Screen.lists, size);
        await tester.tap(find.text('Manage'));
        await tester.pumpAndSettle();
        expect(rig.uri.path, AppRouter.pinnedPath);

        rig = await _open(tester, _Screen.lists, size);
        await tester.tap(find.text('Books'));
        await tester.pumpAndSettle();
        expect(rig.uri.path, AppRouter.listPath('78'));
      });

      testWidgets('ListDetail: the look', (tester) async {
        await _open(tester, _Screen.detail, size);
        expect(find.byKey(const ValueKey('list-hero')), findsOneWidget);
        expect(find.text('LIST · PUBLIC'), findsOneWidget);
        expect(find.text('Friends.', findRichText: true), findsOneWidget);
        expect(find.text('3 Members', findRichText: true), findsOneWidget);
        // A phone holds Back in the hero; the wide mocks have a top bar.
        expect(
          find.byType(AppBackHeader),
          phone ? findsNothing : findsOneWidget,
        );
        expect(find.byTooltip('Back'), findsOneWidget);
        final hero = tester.getRect(find.byKey(const ValueKey('list-hero')));
        // Edge to edge on a phone; the wide hero sits in the column.
        expect(hero.width, phone ? size.width : lessThan(size.width));
        expect(tester.takeException(), isNull);
      });

      testWidgets('ListDetail: Back, Pin, Members, Edit List and Report', (
        tester,
      ) async {
        var rig = await _open(tester, _Screen.detail, size);
        await tester.tap(find.text('Unpin from Home'));
        await tester.pumpAndSettle();
        expect(rig.server.count('SetHomeTabs'), 1);

        rig = await _open(tester, _Screen.detail, size);
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        expect(rig.uri.path, AppRouter.listsPath);

        rig = await _open(tester, _Screen.detail, size);
        await tester.tap(find.text('3 Members', findRichText: true));
        await tester.pumpAndSettle();
        expect(rig.uri.path, AppRouter.listMembersPath(kRigListId));

        rig = await _open(tester, _Screen.detail, size);
        await tester.tap(find.text('Edit List'));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(TextField, 'Name'), findsOneWidget);

        await _open(tester, _Screen.detail, size, owner: false);
        expect(find.text('Edit List'), findsNothing);
        await tester.tap(find.byTooltip('More options'));
        await tester.pumpAndSettle();
        expect(find.text('Report List'), findsOneWidget);
      });

      testWidgets('ListMembers: the look and Remove', (tester) async {
        final rig = await _open(tester, _Screen.members, size);
        expect(find.text('Members'), findsOneWidget);
        expect(find.text('Friends'), findsOneWidget);
        expect(find.text('Members · 3'), findsOneWidget);
        expect(find.text('Suggested'), findsNothing);
        expect(find.text('Remove'), findsNWidgets(3));
        await tester.tap(find.text('Remove').first);
        await tester.pumpAndSettle();
        expect(find.text('Remove @mia?'), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, 'Remove'));
        await tester.pumpAndSettle();
        expect(rig.server.count('RemoveListMember'), 1);
        expect(find.text('Members · 2'), findsOneWidget);
      });

      testWidgets('ManagePinned: the look', (tester) async {
        await _open(tester, _Screen.pinned, size);
        expect(find.text('Following'), findsOneWidget);
        expect(find.text('Always first'), findsOneWidget);
        expect(find.byTooltip('Unpin Friends'), findsOneWidget);
        expect(
          find.text('Add from your Lists'),
          phone ? findsOneWidget : findsNothing,
        );
        expect(
          find.text('ADD FROM YOUR LISTS'),
          phone ? findsNothing : findsOneWidget,
        );
        // Raised cards on the phone; flat rows, "Unpin" and "Pin" wide.
        expect(find.byType(AppCard), phone ? findsNWidgets(2) : findsNothing);
        expect(find.text('PINNED'), phone ? findsNothing : findsOneWidget);
        expect(find.text('Unpin'), phone ? findsNothing : findsOneWidget);
        expect(find.text('Pin'), phone ? findsNothing : findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('ManagePinned: Unpin, Pin and Done', (tester) async {
        var rig = await _open(tester, _Screen.pinned, size);
        await tester.tap(find.byTooltip('Unpin Friends'));
        await tester.pumpAndSettle();
        expect(rig.server.count('SetHomeTabs'), 1);

        rig = await _open(tester, _Screen.pinned, size);
        await tester.tap(find.byTooltip('Pin Books to Home'));
        await tester.pumpAndSettle();
        expect(rig.server.count('SetHomeTabs'), 1);

        rig = await _open(tester, _Screen.pinned, size);
        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();
        expect(rig.uri.path, AppRouter.homePath);
      });

      testWidgets('UserLists: the look and a row', (tester) async {
        final rig = await _open(tester, _Screen.userLists, size);
        expect(inListsPage(find.text('Lists')), findsOneWidget);
        expect(find.text('@olivia'), findsOneWidget);
        expect(find.text('Chess'), findsOneWidget);
        expect(find.text('Runners'), findsOneWidget);
        expect(find.text('Olivia Owner · 2 members'), findsNWidgets(2));
        expect(
          find.byIcon(Icons.chevron_right),
          phone ? findsNothing : findsNWidgets(2),
        );
        await tester.tap(find.text('Chess'));
        await tester.pumpAndSettle();
        expect(rig.uri.path, AppRouter.listPath('79'));
      });
    });
  }

  group('text scale 2.0 on a phone: nothing overflows', () {
    for (final screen in _Screen.values) {
      testWidgets(screen.name, (tester) async {
        await _open(tester, screen, _sizes['phone']!, textScale: 2);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('screenshots', () {
    for (final screen in _Screen.values) {
      for (final brightness in Brightness.values) {
        for (final MapEntry(key: name, value: size) in _sizes.entries) {
          testWidgets('${screen.name} $name ${brightness.name}', (
            tester,
          ) async {
            await _open(tester, screen, size, brightness: brightness);
            await _capture(tester, '${screen.name}-$name-${brightness.name}');
          }, skip: !_screenshots);
        }
      }
    }
  });
}
