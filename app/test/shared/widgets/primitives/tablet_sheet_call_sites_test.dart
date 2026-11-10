import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/beacons/presentation/widgets/join_note_sheet.dart';
import 'package:dzeroth/features/engagement/presentation/widgets/repost_sheet.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/lists/presentation/widgets/add_to_lists_sheet.dart';
import 'package:dzeroth/features/moderation/data/moderation_repository.dart';
import 'package:dzeroth/features/moderation/presentation/report_sheet.dart';
import 'package:dzeroth/features/posts/domain/compose_audience.dart';
import 'package:dzeroth/features/posts/domain/reply_audience.dart';
import 'package:dzeroth/features/posts/presentation/widgets/audience_sheet.dart';
import 'package:dzeroth/features/posts/presentation/widgets/reply_audience_sheet.dart';
import 'package:dzeroth/features/settings/presentation/widgets/appearance_sheet.dart';
import 'package:dzeroth/gen/dzeroth/moderation/v1/moderation.pbenum.dart';
import 'package:dzeroth/shared/widgets/post/alt_text_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/tablet_modal_harness.dart';

/// Every bottom sheet of tablet plan section 4.2: a menu (repost, audience,
/// reply audience) or a dialog (report, add to lists, join note, appearance,
/// image description) on the tablet layout at 600-1199 dp, and the same
/// bottom sheet as before on phones and desktop (ruling R-1).

class _MockModeration extends Mock implements ModerationRepository {}

class _MockLists extends Mock implements ListsRepository {}

class _MemoryStore implements ThemeModeStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async => this.value = value;
}

enum _Shape { menu, dialog }

class _Site {
  const _Site(this.name, this.shape, this.open, this.marker);

  final String name;
  final _Shape shape;

  /// Opens the sheet from the trigger's context (also its anchor).
  final void Function(BuildContext context) open;

  /// Text the content shows.
  final String marker;
}

final _sites = [
  _Site(
    'repost',
    _Shape.menu,
    (c) => showRepostSheet(c, reposted: false, canQuote: true, anchor: c),
    'Quote',
  ),
  _Site(
    'audience',
    _Shape.menu,
    (c) => showAudienceSheet(
      c,
      selected: ComposeAudience.everyone,
      communities: const [],
      anchor: c,
    ),
    'Choose audience',
  ),
  _Site(
    'reply audience',
    _Shape.menu,
    (c) =>
        showReplyAudienceSheet(c, selected: ReplyAudience.everyone, anchor: c),
    'Who can reply?',
  ),
  _Site(
    'report',
    _Shape.dialog,
    (c) => showReportSheet(
      c,
      targetType: ReportTargetType.REPORT_TARGET_TYPE_POST,
      targetId: '1234567890123456789',
      subject: "@alice's post",
    ),
    "Report @alice's post",
  ),
  _Site(
    'add to lists',
    _Shape.dialog,
    (c) => showAddToListsSheet(
      c,
      repository: _lists,
      userId: 'u9',
      handle: 'kaif',
    ),
    'Add or remove @kaif',
  ),
  _Site(
    'join note',
    _Shape.dialog,
    (c) => showJoinNoteSheet(c, title: 'Sunday run'),
    'Ask to join',
  ),
  _Site('appearance', _Shape.dialog, AppearanceSheet.show, 'Appearance'),
  _Site(
    'image description',
    _Shape.dialog,
    (c) => showAltTextSheet(c, text: 'A dog on a beach'),
    'Image description',
  ),
];

late _MockLists _lists;

void main() {
  late _MockModeration moderation;
  late ThemeModeCubit themeMode;

  setUp(() {
    moderation = _MockModeration();
    _lists = _MockLists();
    when(() => _lists.enabled).thenReturn(true);
    when(
      () => _lists.listUserLists(
        ownerId: any(named: 'ownerId'),
        containsUserId: any(named: 'containsUserId'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) async => const ListsPage(lists: []));
    themeMode = ThemeModeCubit(_MemoryStore());
  });

  tearDown(() => themeMode.close());

  Widget providers(Widget app) =>
      RepositoryProvider<ModerationRepository>.value(
        value: moderation,
        child: RepositoryProvider<UnexpectedErrorReporter>.value(
          value: (e, s) {},
          child: BlocProvider<ThemeModeCubit>.value(
            value: themeMode,
            child: app,
          ),
        ),
      );

  for (final site in _sites) {
    for (final textScale in [1.0, 2.0]) {
      for (final width in [599.0, 834.0, 1024.0, 1200.0]) {
        final tablet = width >= 600 && width < 1200;
        final expected = !tablet
            ? 'a bottom sheet'
            : site.shape == _Shape.menu
            ? 'a menu'
            : 'a dialog';
        testWidgets('${site.name} at ${width.toInt()} dp, text $textScale, is '
            '$expected', (tester) async {
          await pumpTabletModalHost(
            tester,
            width: width,
            height: 1194,
            textScale: textScale,
            wrap: providers,
            trigger: (context) => TextButton(
              onPressed: () => site.open(context),
              child: const Text('open'),
            ),
          );

          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();

          expect(find.text(site.marker), findsOneWidget);
          expect(tester.takeException(), isNull);
          if (!tablet) {
            expect(find.byType(BottomSheet), findsOneWidget);
            return;
          }
          expect(find.byType(BottomSheet), findsNothing);
          if (site.shape == _Shape.dialog) {
            expect(find.byType(Dialog), findsOneWidget);
            final box = openDialogRect(tester);
            final content = tabletContentRect(Size(width, 1194));
            expect(box.center.dx, closeTo(content.center.dx, 1));
            expect(box.width, lessThanOrEqualTo(560.5));
          } else {
            expect(find.byType(Dialog), findsNothing);
            // Hung from the trigger.
            final trigger = tester.getRect(find.byKey(kTabletTriggerKey));
            final marker = tester.getRect(find.text(site.marker));
            expect(marker.top, greaterThan(trigger.bottom));
            expect(marker.top, lessThan(trigger.bottom + 80));
          }
        });
      }
    }
  }
}
