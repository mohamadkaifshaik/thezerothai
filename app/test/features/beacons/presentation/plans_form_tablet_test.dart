import 'dart:async';

import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/shell_geometry.dart';
import 'package:dzeroth/features/beacons/domain/beacon_labels.dart';
import 'package:dzeroth/features/beacons/domain/beacons_feature_flag.dart';
import 'package:dzeroth/features/beacons/presentation/beacon_screen.dart';
import 'package:dzeroth/features/beacons/presentation/create_beacon_screen.dart';
import 'package:dzeroth/features/beacons/presentation/edit_beacon_screen.dart';
import 'package:dzeroth/features/beacons/presentation/widgets/plan_form_fields.dart';
import 'package:dzeroth/features/beacons/presentation/widgets/plan_preview.dart';
import 'package:dzeroth/features/beacons/presentation/widgets/plan_summary.dart';
import 'package:dzeroth/features/beacons/presentation/widgets/plan_tips.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/moderation/domain/reports_feature_flag.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:dzeroth/shared/format/scheduled_time.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/beacons_fixtures.dart';
import '../../../support/context_pane_rig.dart'
    show expectTabletPanes, findContextPane;
import '../../../support/plans_tablet_rig.dart';
import '../../../support/tablet_modal_harness.dart' show openDialogRect;
import '../../../support/theme_harness.dart';

const _widths = <double>[360, 599, 600, 839, 840, 1024, 1199, 1200];

bool _tabletFlags(Set<String> flags) =>
    flags.contains(kFeatureUiShell) && flags.contains(kFeatureUiTablet);

bool _tabletWidth(double w) =>
    w >= AppBreakpoints.mobile && w < AppBreakpoints.tablet;

/// The create or edit form (the route child).
Finder _formPage() => find.byWidgetPredicate(
  (w) => w is CreateBeaconScreen || w is EditBeaconScreen,
);

Finder _inForm(Finder f) => find.descendant(of: _formPage(), matching: f);

/// [f] inside the preview in the open dialog.
Finder _inDialogPreview(Finder f) => find.descendant(
  of: find.descendant(
    of: find.byType(Dialog),
    matching: find.byType(PlanPreview),
  ),
  matching: f,
);

final _previewAction = find.widgetWithText(TextButton, kPlanPreviewTitle);
const _tipsToggle = ValueKey('plan-tips-toggle');

final String _editPath = AppRouter.planEditPath(kBeaconIdA);
const _rigTitle = 'Coffee at noon';

/// Fills the create form's text fields.
Future<void> _fillCreate(WidgetTester tester) async {
  await tester.enterText(
    _inForm(find.widgetWithText(TextField, 'Title')),
    ('  Board games '),
  );
  await tester.enterText(
    _inForm(find.widgetWithText(TextField, 'Details')),
    'Bring snacks',
  );
  await tester.enterText(
    _inForm(find.widgetWithText(TextField, 'Meeting point')),
    'Library hall',
  );
  await tester.pumpAndSettle();
}

/// Scrolls [f] into view in the form, then taps it.
Future<void> _tapInForm(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

/// The rig's first plan, organised by the caller (People, Edit, Cancel).
void _organise(PlansTabletRig rig, {int accepted = 0}) {
  final view = rig.server.public.first;
  view.beacon.acceptedCount = accepted;
  view.viewer = pb.ViewerState(
    role: pb.ViewerRole.VIEWER_ROLE_ORGANISER,
    canManage: true,
  );
}

/// The content centre of the tablet shell for a [width] dp window.
double _contentCentre(double width) =>
    AppSize.railCompact + (width - AppSize.railCompact) / 2;

/// Opens the Preview dialog from the header action, runs [check] inside it,
/// and closes it again (the form is behind a scrim while it is open).
Future<void> _peek(WidgetTester tester, Future<void> Function() check) async {
  await tester.tap(_previewAction);
  await tester.pumpAndSettle();
  expect(find.byType(Dialog), findsOneWidget);
  await check();
  await tester.tap(find.text('Close'));
  await tester.pumpAndSettle();
  expect(find.byType(Dialog), findsNothing);
}

void main() {
  group('PlanCreate (/plans/new): flag modes x widths', () {
    for (final MapEntry(key: mode, value: flags) in kPlansFlagModes.entries) {
      for (final w in _widths) {
        final tablet = _tabletFlags(flags) && _tabletWidth(w);
        testWidgets('$mode at ${w.toInt()}: '
            '${tablet ? 'Preview action and inline tips' : 'today\'s form'}', (
          tester,
        ) async {
          final rig = PlansTabletRig();
          await rig.pump(
            tester,
            location: AppRouter.planNewPath,
            width: w,
            height: 1100,
            flags: flags,
            realForms: true,
          );
          expect(tester.takeException(), isNull);

          expect(find.text('New plan'), findsOneWidget);
          expect(_previewAction, tablet ? findsOneWidget : findsNothing);
          expect(
            find.byKey(_tipsToggle),
            tablet ? findsOneWidget : findsNothing,
          );
          // No list pane beside the form (plan section 3, "Not on"), and no
          // side column on the tablet layout: the preview is the dialog.
          expect(findPlansPane(), findsNothing);
          expect(findContextPane(), findsNothing);
          expect(find.byType(PlanPreview), findsNothing);
          expect(find.text(kPlanTipsTitle), tablet ? findsOne : findsNothing);
          // Tips are collapsed inline: no tip text until opened.
          expect(find.text(kPlanTips.first), findsNothing);
          // The form's own note on the meeting point is unchanged.
          expect(_inForm(find.text(kMeetingPointNote)), findsOneWidget);
          expect(rig.server.calls, isEmpty);
        });
      }
    }
  });

  group('PlanEdit (/plans/:id/edit): flag modes x widths', () {
    for (final MapEntry(key: mode, value: flags) in kPlansFlagModes.entries) {
      for (final w in _widths) {
        final tablet = _tabletFlags(flags) && _tabletWidth(w);
        testWidgets('$mode at ${w.toInt()}: '
            '${tablet ? 'Preview action and inline tips' : 'today\'s form'}', (
          tester,
        ) async {
          final rig = PlansTabletRig();
          await rig.pump(
            tester,
            location: _editPath,
            width: w,
            height: 1100,
            flags: flags,
            realForms: true,
          );
          expect(tester.takeException(), isNull);

          expect(find.text('Edit plan'), findsOneWidget);
          expect(
            _inForm(find.widgetWithText(TextField, _rigTitle)),
            findsOneWidget,
          );
          expect(_previewAction, tablet ? findsOneWidget : findsNothing);
          expect(
            find.byKey(_tipsToggle),
            tablet ? findsOneWidget : findsNothing,
          );
          expect(findPlansPane(), findsNothing);
          expect(findContextPane(), findsNothing);
          expect(find.byType(PlanPreview), findsNothing);
          // The meeting point's privacy note, at every width (ruling 3,
          // owner 2026-11-11), as on the create form.
          expect(_inForm(find.text(kMeetingPointNote)), findsOneWidget);
          // F28 (R12): a plan that has not started takes a new date, time,
          // duration and cost, with the designs' helper under Date and Time.
          expect(_inForm(find.byTooltip('Pick a date')), findsOneWidget);
          expect(_inForm(find.byTooltip('Pick a time')), findsOneWidget);
          expect(_inForm(find.text(kPlanEditNotifyHelper)), findsOneWidget);
          expect(
            _inForm(find.widgetWithText(ChoiceChip, '60 min')),
            findsOneWidget,
          );
          expect(_inForm(find.widgetWithText(ChoiceChip, 'Free')), findsOne);
          expect(rig.server.calls, ['get']);
        });
      }
    }
  });

  // Ruling 3 (owner, 2026-11-11): the Edit form's Meeting point carries
  // the privacy note at every width, phones and desktop included.
  group('PlanEdit: the meeting point note on a phone and on desktop', () {
    for (final (w, h) in const <(double, double)>[(360, 800), (1440, 900)]) {
      for (final MapEntry(key: mode, value: flags) in kPlansFlagModes.entries) {
        testWidgets('$mode at ${w.toInt()}: the note under the field', (
          tester,
        ) async {
          final rig = PlansTabletRig();
          await rig.pump(
            tester,
            location: _editPath,
            width: w,
            height: h,
            flags: flags,
            realForms: true,
          );
          expect(tester.takeException(), isNull);
          final field = _inForm(
            find.widgetWithText(TextField, 'Venue of $_rigTitle'),
          );
          expect(
            find.descendant(of: field, matching: find.text(kMeetingPointNote)),
            findsOneWidget,
          );
          expect(find.byType(PlanPreview), findsNothing);
          expect(_previewAction, findsNothing);
        });
      }
    }
  });

  group('band B: a pushed form has no context pane', () {
    testWidgets('New plan from the Plans list: the form replaces the list '
        'pane, with the Preview action and inline tips; back restores it', (
      tester,
    ) async {
      final rig = PlansTabletRig();
      await rig.pump(tester, realForms: true);
      expect(findPlansPane(), findsOneWidget);
      expect(findContextPane(), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, 'New plan'));
      await tester.pumpAndSettle();
      expect(findPlansPane(), findsNothing);
      expect(findContextPane(), findsNothing);
      expect(_previewAction, findsOneWidget);
      expect(find.byKey(_tipsToggle), findsOneWidget);
      expectTabletPanes(tester, _formPage(), 1024, hasPane: false);

      rig.router.pop();
      await tester.pumpAndSettle();
      expect(findPlansPane(), findsOneWidget);
      expect(findContextPane(), findsNothing);
    });

    testWidgets('Edit from a plan: no Preview action and no tips while it '
        'loads, both once it has', (tester) async {
      final rig = PlansTabletRig();
      _organise(rig);
      await rig.pump(
        tester,
        location: AppRouter.planPath(kBeaconIdA),
        realForms: true,
      );
      final hold = rig.server.holdGet = Completer<void>();
      await tester.tap(find.widgetWithText(AppPillButton, 'Edit'));
      await tester.pumpAndSettle();
      expect(findContextPane(), findsNothing);
      expect(find.bySemanticsLabel('Loading plan'), findsOneWidget);
      expect(_previewAction, findsNothing);
      expect(find.byKey(_tipsToggle), findsNothing);

      hold.complete();
      await tester.pumpAndSettle();
      expect(findContextPane(), findsNothing);
      expect(_previewAction, findsOneWidget);
      expect(find.byKey(_tipsToggle), findsOneWidget);

      rig.router.pop();
      await tester.pumpAndSettle();
      expect(findPlansPane(), findsOneWidget);
      expect(findContextPane(), findsNothing);
    });

    testWidgets('a failed load: no preview and no tips over the error, both '
        'after Try again', (tester) async {
      final rig = PlansTabletRig();
      rig.server.refusals.add(const NetworkException('down'));
      await rig.pump(tester, location: _editPath, realForms: true);
      expect(find.text('Try again'), findsOneWidget);
      expect(findContextPane(), findsNothing);
      expect(_previewAction, findsNothing);
      expect(find.byKey(_tipsToggle), findsNothing);

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(_previewAction, findsOneWidget);
      expect(find.byKey(_tipsToggle), findsOneWidget);
    });

    testWidgets('a plan that does not exist: nothing over not-found', (
      tester,
    ) async {
      final rig = PlansTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.planEditPath('1999999999999999999'),
        realForms: true,
      );
      expect(findContextPane(), findsNothing);
      expect(_previewAction, findsNothing);
      expect(find.byKey(_tipsToggle), findsNothing);
    });
  });

  group('the live preview (the dialog) follows every field', () {
    testWidgets('create: title, details, meeting point, what, when, '
        'duration, spots, cost and chat', (tester) async {
      final rig = PlansTabletRig();
      rig.pickDate = (
        context, {
        required initial,
        required first,
        required last,
      }) async => initial.add(const Duration(days: 2));
      rig.pickTime = (context, {required initial}) async =>
          const TimeOfDay(hour: 9, minute: 30);
      await rig.pump(
        tester,
        location: AppRouter.planNewPath,
        height: 1100,
        realForms: true,
      );

      await _peek(tester, () async {
        expect(_inDialogPreview(find.text(kPlanPreviewUntitled)), findsOne);
        expect(_inDialogPreview(find.text(kPlanPreviewNoVenue)), findsOne);
        expect(_inDialogPreview(find.text('0 of 3 seats taken')), findsOne);
        expect(_inDialogPreview(find.text('Alice A')), findsOneWidget);
        expect(_inDialogPreview(find.text('Organiser')), findsOneWidget);
        // No details yet: nothing drawn for them.
        expect(_inDialogPreview(find.text('Bring snacks')), findsNothing);
      });

      await _fillCreate(tester);
      await _peek(tester, () async {
        expect(_inDialogPreview(find.text('Board games')), findsOneWidget);
        expect(_inDialogPreview(find.text(kPlanPreviewUntitled)), findsNothing);
        expect(_inDialogPreview(find.text('Bring snacks')), findsOneWidget);
        expect(_inDialogPreview(find.text('Library hall')), findsOneWidget);
        expect(_inDialogPreview(find.text(kPlanPreviewNoVenue)), findsNothing);
        expect(_inDialogPreview(find.text(kMeetingPointNote)), findsOne);
      });

      await _tapInForm(
        tester,
        _inForm(find.widgetWithText(ChoiceChip, 'Walk')),
      );
      await _peek(tester, () async {
        expect(
          _inDialogPreview(find.byIcon(Icons.directions_walk)),
          findsOneWidget,
        );
      });

      await _tapInForm(tester, find.byTooltip('Pick a date'));
      await _tapInForm(tester, find.byTooltip('Pick a time'));
      String label(String tooltip) => tester
          .widget<Text>(
            find.descendant(
              of: find.byTooltip(tooltip),
              matching: find.byType(Text),
            ),
          )
          .data!;
      expect(label('Pick a time'), contains('9:30'));
      await _peek(tester, () async {
        expect(
          _inDialogPreview(
            find.text(
              '${label('Pick a date')} at ${label('Pick a time')} · 60 min',
            ),
          ),
          findsOneWidget,
        );
      });

      await _tapInForm(
        tester,
        _inForm(find.widgetWithText(ChoiceChip, '90 min')),
      );
      await _peek(tester, () async {
        expect(
          _inDialogPreview(find.textContaining(RegExp(r' · 90 min$'))),
          findsOneWidget,
        );
      });

      await _tapInForm(tester, find.byTooltip('More spots'));
      await _peek(tester, () async {
        expect(_inDialogPreview(find.text('0 of 4 seats taken')), findsOne);
      });

      await _tapInForm(
        tester,
        _inForm(find.widgetWithText(ChoiceChip, 'Split evenly')),
      );
      await _peek(tester, () async {
        expect(_inDialogPreview(find.text('Cost: Split evenly')), findsOne);
      });

      await _tapInForm(
        tester,
        _inForm(find.widgetWithText(ChoiceChip, 'Open to chat')),
      );
      await _peek(tester, () async {
        expect(_inDialogPreview(find.text('Chat: Open to chat')), findsOne);
      });
      expect(findContextPane(), findsNothing);
      expect(rig.server.calls, isEmpty);
    });

    testWidgets('create without a loaded profile: no organiser row', (
      tester,
    ) async {
      final rig = PlansTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.planNewPath,
        realForms: true,
        profile: false,
      );
      await _peek(tester, () async {
        expect(_inDialogPreview(find.text('Organiser')), findsNothing);
        expect(_inDialogPreview(find.text(kPlanPreviewUntitled)), findsOne);
      });
    });

    testWidgets('edit: the text, the seats and the status follow, as the '
        'server would store them', (tester) async {
      final rig = PlansTabletRig();
      _organise(rig, accepted: 2);
      await rig.pump(
        tester,
        location: _editPath,
        height: 1100,
        realForms: true,
      );
      await _peek(tester, () async {
        expect(_inDialogPreview(find.text('2 of 3 seats taken')), findsOne);
        expect(_inDialogPreview(find.text('Full')), findsNothing);
        expect(_inDialogPreview(find.text('Orla')), findsOneWidget);
      });

      await tester.enterText(
        _inForm(find.widgetWithText(TextField, _rigTitle)),
        ' Tea at four ',
      );
      await tester.enterText(
        _inForm(find.widgetWithText(TextField, 'Venue of $_rigTitle')),
        'Library',
      );
      await tester.pumpAndSettle();
      await _peek(tester, () async {
        expect(_inDialogPreview(find.text('Tea at four')), findsOneWidget);
        expect(_inDialogPreview(find.text('Library')), findsOneWidget);
      });

      await _tapInForm(tester, find.byTooltip('Fewer spots'));
      await _peek(tester, () async {
        expect(_inDialogPreview(find.text('2 of 2 seats taken')), findsOne);
        expect(_inDialogPreview(find.text('Full')), findsOneWidget);
      });
      await _tapInForm(tester, find.byTooltip('More spots'));
      await _peek(tester, () async {
        expect(_inDialogPreview(find.text('2 of 3 seats taken')), findsOne);
        expect(_inDialogPreview(find.text('Full')), findsNothing);
      });
      expect(rig.server.calls, ['get']);
    });

    // F28: the edit form's date, time, duration and cost move the preview
    // too, and its when line equals the form's own labels.
    testWidgets('edit: the date, time, duration and cost follow', (
      tester,
    ) async {
      final rig = PlansTabletRig();
      _organise(rig);
      rig.pickDate = (
        context, {
        required initial,
        required first,
        required last,
      }) async => initial.add(const Duration(days: 2));
      rig.pickTime = (context, {required initial}) async =>
          const TimeOfDay(hour: 21, minute: 15);
      await rig.pump(
        tester,
        location: _editPath,
        height: 1100,
        realForms: true,
      );

      await _tapInForm(tester, find.byTooltip('Pick a date'));
      await _tapInForm(tester, find.byTooltip('Pick a time'));
      String label(String tooltip) => tester
          .widget<Text>(
            find.descendant(
              of: find.byTooltip(tooltip),
              matching: find.byType(Text),
            ),
          )
          .data!;
      expect(label('Pick a time'), contains('9:15'));
      await _peek(tester, () async {
        expect(
          _inDialogPreview(
            find.text(
              '${label('Pick a date')} at ${label('Pick a time')} · 60 min',
            ),
          ),
          findsOneWidget,
        );
      });

      await _tapInForm(
        tester,
        _inForm(find.widgetWithText(ChoiceChip, '120 min')),
      );
      await _peek(tester, () async {
        expect(
          _inDialogPreview(find.textContaining(RegExp(r' · 120 min$'))),
          findsOneWidget,
        );
      });
      await _tapInForm(
        tester,
        _inForm(find.widgetWithText(ChoiceChip, 'Everyone pays their own')),
      );
      await _peek(tester, () async {
        expect(
          _inDialogPreview(find.text('Cost: Everyone pays their own')),
          findsOneWidget,
        );
      });
      expect(rig.server.calls, ['get']);
    });
  });

  group('the organiser row (shared with the plan page)', () {
    // Today's row on the plan page: the role label at its natural width at
    // the end, the name beside the avatar, whenever the name keeps at least
    // an avatar's width. (At 320 x2.0 the test font's square glyphs left the
    // name 2 dp before; it now keeps 40, so that cell is not listed.)
    for (final (w, scale) in const <(double, double)>[
      (320, 1),
      (360, 1),
      (360, 2),
      (599, 1),
      (599, 2),
    ]) {
      testWidgets('plan page at ${w.toInt()} x$scale: the label whole, '
          'over the name (R12, the designs\' PlanDetail)', (tester) async {
        final rig = PlansTabletRig();
        await rig.pump(
          tester,
          location: AppRouter.planPath(kBeaconIdA),
          width: w,
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
        final label = find.text('Organiser');
        expect(
          tester.renderObject<RenderParagraph>(label).didExceedMaxLines,
          isFalse,
        );
        final name = find.text('Orla');
        expect(
          tester.getRect(label).bottom,
          lessThanOrEqualTo(tester.getRect(name).top),
        );
        expect(tester.getRect(label).left, tester.getRect(name).left);
      });
    }

    testWidgets('the Preview dialog at 2.0: the organiser label gives way, '
        'nothing overflows', (tester) async {
      final rig = PlansTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.planNewPath,
        width: 840,
        height: 1194,
        textScale: 2,
        realForms: true,
      );
      expect(tester.takeException(), isNull);
      await _peek(tester, () async {
        expect(tester.takeException(), isNull);
        final label = _inDialogPreview(find.text('Organiser'));
        expect(label, findsOneWidget);
        final row = find.ancestor(of: label, matching: find.byType(Row)).first;
        expect(
          tester.getRect(label).right,
          lessThanOrEqualTo(tester.getRect(row).right),
        );
      });
    });
  });

  group('the preview is the plan page (hierarchy, weights, meeting point)', () {
    testWidgets('create a plan: the page draws the same summary with the '
        'same styles as its preview', (tester) async {
      final rig = PlansTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.planNewPath,
        height: 1100,
        realForms: true,
      );
      await _fillCreate(tester);

      TextStyle style(Finder f) => tester.widget<Text>(f).style!;
      late final TextStyle previewTitle;
      late final TextStyle previewVenue;
      late final TextStyle previewNote;
      await _peek(tester, () async {
        previewTitle = style(_inDialogPreview(find.text('Board games')));
        previewVenue = style(_inDialogPreview(find.text('Library hall')));
        previewNote = style(_inDialogPreview(find.text(kMeetingPointNote)));
        final previewTop = tester.getTopLeft(
          _inDialogPreview(find.text(kMeetingPointNote)),
        );
        final previewVenueBottom = tester.getBottomLeft(
          _inDialogPreview(find.text('Library hall')),
        );
        expect(
          previewTop.dy,
          previewVenueBottom.dy,
          reason: 'note under venue',
        );
      });

      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      final page = find.byType(BeaconScreen);
      expect(page, findsOneWidget);
      Finder inPage(Finder f) => find.descendant(of: page, matching: f);
      expect(inPage(find.byType(PlanSummary)), findsOneWidget);
      expect(style(inPage(find.text('Board games'))), previewTitle);
      expect(style(inPage(find.text('Library hall'))), previewVenue);
      expect(style(inPage(find.text(kMeetingPointNote))), previewNote);
      expect(previewTitle.fontWeight, FontWeight.w800);
    });
  });

  group('the Preview dialog (both tablet bands)', () {
    for (final w in <double>[600, 744, 839, 840, 1024, 1199]) {
      testWidgets('create at ${w.toInt()}: a D 560 on the content area with '
          'the form as typed', (tester) async {
        final rig = PlansTabletRig();
        await rig.pump(
          tester,
          location: AppRouter.planNewPath,
          width: w,
          height: 1100,
          realForms: true,
        );
        await _fillCreate(tester);
        await tester.tap(_previewAction);
        await tester.pumpAndSettle();

        expect(find.byType(Dialog), findsOneWidget);
        expect(findContextPane(), findsNothing);
        expect(_inDialogPreview(find.text('Board games')), findsOneWidget);
        expect(_inDialogPreview(find.text('Library hall')), findsOneWidget);
        expect(_inDialogPreview(find.text(kMeetingPointNote)), findsOneWidget);
        expect(_inDialogPreview(find.text('Bring snacks')), findsOneWidget);
        expect(_inDialogPreview(find.text('Alice A')), findsOneWidget);
        final content = w - AppSize.railCompact;
        final rect = openDialogRect(tester);
        expect(
          rect.width,
          lessThanOrEqualTo(
            content - 48 < AppSize.dialogMax ? content - 48 : AppSize.dialogMax,
          ),
        );
        expect(rect.center.dx, closeTo(_contentCentre(w), 1));
        // The preview lines start where the dialog title does.
        expect(
          tester.getTopLeft(_inDialogPreview(find.byType(PlanSummary))).dx,
          closeTo(
            tester
                .getTopLeft(
                  find.descendant(
                    of: find.byType(Dialog),
                    matching: find.text(kPlanPreviewTitle),
                  ),
                )
                .dx,
            1,
          ),
        );

        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
        expect(rig.server.calls, isEmpty);
      });
    }

    for (final w in <double>[744, 1024]) {
      testWidgets('edit at ${w.toInt()}: the dialog shows the plan with the '
          'edits', (tester) async {
        final rig = PlansTabletRig();
        await rig.pump(
          tester,
          location: _editPath,
          width: w,
          height: 1100,
          realForms: true,
        );
        await tester.enterText(
          _inForm(find.widgetWithText(TextField, _rigTitle)),
          'Tea at four',
        );
        await tester.pumpAndSettle();
        await tester.tap(_previewAction);
        await tester.pumpAndSettle();
        expect(_inDialogPreview(find.text('Tea at four')), findsOneWidget);
        expect(_inDialogPreview(find.text(kMeetingPointNote)), findsOne);
        expect(openDialogRect(tester).center.dx, closeTo(_contentCentre(w), 1));
        expect(rig.server.calls, ['get']);
      });

      testWidgets('edit at ${w.toInt()} while loading and after a failure: '
          'no Preview action and no tips', (tester) async {
        final rig = PlansTabletRig();
        final hold = rig.server.holdGet = Completer<void>();
        await rig.pump(tester, location: _editPath, width: w, realForms: true);
        expect(_previewAction, findsNothing);
        expect(find.byKey(_tipsToggle), findsNothing);
        hold.complete();
        await tester.pumpAndSettle();
        expect(_previewAction, findsOneWidget);
        expect(find.byKey(_tipsToggle), findsOneWidget);

        final failed = PlansTabletRig();
        failed.server.refusals.add(const NetworkException('down'));
        await failed.pump(
          tester,
          location: _editPath,
          width: w,
          realForms: true,
        );
        expect(find.text('Try again'), findsOneWidget);
        expect(_previewAction, findsNothing);
        expect(find.byKey(_tipsToggle), findsNothing);
      });
    }
  });

  // UX review of T8d: the Preview dialog must not outlive the tablet layout.
  // Across 840 it stays (the same layout, no pane to take over); at 1200 and
  // below 600 there is no preview at all.
  group('the Preview dialog across the layout edges', () {
    for (final (name, location) in [
      ('create', AppRouter.planNewPath),
      ('edit', AppRouter.planEditPath(kBeaconIdA)),
    ]) {
      testWidgets('$name: open at 834, then 1024 keeps it open, with no '
          'pane', (tester) async {
        final rig = PlansTabletRig();
        await rig.pump(
          tester,
          location: location,
          width: 834,
          height: 1100,
          realForms: true,
        );
        await tester.tap(_previewAction);
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsOneWidget);

        await rig.resize(tester, 1024);
        expect(tester.takeException(), isNull);
        expect(find.byType(Dialog), findsOneWidget);
        expect(find.byType(PlanPreview), findsOneWidget);
        expect(findContextPane(), findsNothing);
        expect(_formPage(), findsOneWidget);
        expect(rig.uri.path, location);
      });

      for (final w in <double>[1200, 599]) {
        testWidgets('$name: open at 834, then ${w.toInt()} closes it', (
          tester,
        ) async {
          final rig = PlansTabletRig();
          await rig.pump(
            tester,
            location: location,
            width: 834,
            height: 1100,
            realForms: true,
          );
          await tester.tap(_previewAction);
          await tester.pumpAndSettle();
          expect(find.byType(Dialog), findsOneWidget);

          await rig.resize(tester, w);
          expect(tester.takeException(), isNull);
          expect(find.byType(Dialog), findsNothing);
          expect(find.byType(PlanPreview), findsNothing);
          expect(_formPage(), findsOneWidget);
          expect(rig.uri.path, location);
        });
      }

      testWidgets('$name: a resize inside the tablet layout keeps it open', (
        tester,
      ) async {
        final rig = PlansTabletRig();
        await rig.pump(
          tester,
          location: location,
          width: 834,
          height: 1100,
          realForms: true,
        );
        await tester.tap(_previewAction);
        await tester.pumpAndSettle();
        await rig.resize(tester, 700);
        expect(find.byType(Dialog), findsOneWidget);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
        // Closed by hand, then across 840: nothing else is popped, and the
        // preview is still behind the action (no pane takes it).
        await rig.resize(tester, 1024);
        expect(_formPage(), findsOneWidget);
        expect(find.byType(PlanPreview), findsNothing);
        expect(_previewAction, findsOneWidget);
      });
    }
  });

  group('Tips for a good plan, inline and collapsible', () {
    for (final location in [AppRouter.planNewPath, _editPath]) {
      for (final w in <double>[744, 1024]) {
        testWidgets('$location at ${w.toInt()}: collapsed, a real 48 dp '
            'toggle with its expanded state, at the top of the form', (
          tester,
        ) async {
          final semantics = tester.ensureSemantics();
          final rig = PlansTabletRig();
          await rig.pump(tester, location: location, width: w, realForms: true);
          final toggle = find.byKey(_tipsToggle);
          expect(tester.getSize(toggle).height, greaterThanOrEqualTo(48));
          expect(
            tester.getSemantics(toggle),
            isSemantics(
              isButton: true,
              hasExpandedState: true,
              isExpanded: false,
            ),
          );
          expect(find.text(kPlanTips.first), findsNothing);
          // Above the first field.
          final firstField = location == AppRouter.planNewPath
              ? _inForm(find.text('What'))
              : _inForm(find.byType(TextField)).first;
          expect(
            tester.getBottomLeft(toggle).dy,
            lessThan(tester.getTopLeft(firstField).dy),
          );

          // The hit area is the row, not only its label: tap near its corner.
          final rect = tester.getRect(toggle);
          await tester.tapAt(rect.topLeft + const Offset(3, 3));
          await tester.pumpAndSettle();
          expect(
            tester.getSemantics(toggle),
            isSemantics(
              isButton: true,
              hasExpandedState: true,
              isExpanded: true,
            ),
          );
          for (final tip in kPlanTips) {
            expect(_inForm(find.text(tip)), findsOneWidget);
          }
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          expect(find.text(kPlanTips.first), findsNothing);
          semantics.dispose();
        });
      }
    }
  });

  group('state across resizes', () {
    testWidgets('create: 839 -> 840 -> 1024 -> 1199 -> 1200 -> 599 -> 600 -> '
        '839 keeps the form, the text and the open tips; the Preview action '
        'follows the tablet layout', (tester) async {
      final rig = PlansTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.planNewPath,
        width: 839,
        height: 1100,
        realForms: true,
      );
      await _fillCreate(tester);
      await tester.tap(find.byKey(_tipsToggle));
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(CreateBeaconScreen));
      EditableTextState field() => tester.state<EditableTextState>(
        find.descendant(
          of: _inForm(find.widgetWithText(TextField, 'Title')),
          matching: find.byType(EditableText),
        ),
      );
      final title = field();

      for (final w in <double>[840, 1024, 1199, 1200, 599, 600, 839]) {
        await rig.resize(tester, w);
        expect(tester.takeException(), isNull, reason: '$w');
        expect(
          tester.state(find.byType(CreateBeaconScreen)),
          same(state),
          reason: '$w',
        );
        expect(field(), same(title), reason: '$w');
        expect(title.textEditingValue.text, '  Board games ');
        expect(findContextPane(), findsNothing, reason: '$w');
        expect(
          _previewAction,
          _tabletWidth(w) ? findsOneWidget : findsNothing,
          reason: '$w',
        );
        expect(
          find.byKey(_tipsToggle),
          _tabletWidth(w) ? findsOneWidget : findsNothing,
          reason: '$w',
        );
      }
      // Back in the tablet layout, the tips are still open.
      expect(_inForm(find.text(kPlanTips.first)), findsOneWidget);
      await tester.tap(_previewAction);
      await tester.pumpAndSettle();
      expect(_inDialogPreview(find.text('Board games')), findsOneWidget);
      expect(rig.server.calls, isEmpty);
    });

    testWidgets('edit: 1024 -> 839 -> 840 -> 1200 -> 1024 keeps the form '
        'and its edits with one GetBeacon', (tester) async {
      final rig = PlansTabletRig();
      await rig.pump(tester, location: _editPath, realForms: true);
      await tester.enterText(
        _inForm(find.widgetWithText(TextField, _rigTitle)),
        'Tea at four',
      );
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(EditBeaconScreen));
      for (final w in <double>[839, 840, 1200, 1024]) {
        await rig.resize(tester, w);
        expect(tester.takeException(), isNull, reason: '$w');
        expect(tester.state(find.byType(EditBeaconScreen)), same(state));
        expect(
          _inForm(find.widgetWithText(TextField, 'Tea at four')),
          findsOneWidget,
        );
        expect(findContextPane(), findsNothing, reason: '$w');
        expect(
          _previewAction,
          _tabletWidth(w) ? findsOneWidget : findsNothing,
          reason: '$w',
        );
      }
      await tester.tap(_previewAction);
      await tester.pumpAndSettle();
      expect(_inDialogPreview(find.text('Tea at four')), findsOneWidget);
      expect(rig.server.calls, ['get']);
    });
  });

  group('date and time pickers (T2 deferred them here; plan section 5.4)', () {
    for (final w in <double>[599, 600, 744, 1024, 1199, 1200, 1440]) {
      final tablet = _tabletWidth(w);
      // D1: the desktop layout centres them on the shell's feed column.
      final desktop = w >= 1200;
      for (final (tooltip, name) in [
        ('Pick a date', 'date'),
        ('Pick a time', 'time'),
      ]) {
        testWidgets('$name at ${w.toInt()}: centred on the '
            '${tablet
                ? 'content area'
                : desktop
                ? 'desktop column'
                : 'window'}', (tester) async {
          final rig = PlansTabletRig();
          await rig.pump(
            tester,
            location: AppRouter.planNewPath,
            width: w,
            height: 1100,
            realForms: true,
          );
          await _tapInForm(tester, find.byTooltip(tooltip));
          expect(
            find.byType(name == 'date' ? DatePickerDialog : TimePickerDialog),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          final rect = openDialogRect(tester);
          expect(
            rect.center.dx,
            closeTo(
              tablet
                  ? _contentCentre(w)
                  : desktop
                  ? ShellGeometry.desktopColumnFor(
                      Size(w, 1100),
                      EdgeInsets.zero,
                      master: false,
                      side: true,
                      railWidth: tester
                          .getSize(find.byType(NavigationRail))
                          .width,
                    ).center.dx
                  : w / 2,
              1,
            ),
          );
          if (tablet) {
            // Inside the content area, 24 dp off its edges at least.
            expect(
              rect.left,
              greaterThanOrEqualTo(AppSize.railCompact + 24 - 1),
            );
            expect(rect.right, lessThanOrEqualTo(w - 24 + 1));
          }
          // Cancel keeps the start as it was.
          final before = tester
              .widget<Text>(
                find.descendant(
                  of: find.byTooltip(tooltip),
                  matching: find.byType(Text),
                ),
              )
              .data;
          await tester.tap(find.text('Cancel').last);
          await tester.pumpAndSettle();
          expect(find.byType(Dialog), findsNothing);
          expect(
            tester
                .widget<Text>(
                  find.descendant(
                    of: find.byTooltip(tooltip),
                    matching: find.byType(Text),
                  ),
                )
                .data,
            before,
          );
        });
      }
    }

    testWidgets('ui_tablet off at 834: the window centre, as today', (
      tester,
    ) async {
      final rig = PlansTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.planNewPath,
        width: 834,
        height: 1100,
        flags: kPlansFlagModes['ui_shell only']!,
        realForms: true,
      );
      await _tapInForm(tester, find.byTooltip('Pick a date'));
      expect(openDialogRect(tester).center.dx, closeTo(417, 1));
    });

    testWidgets('ui_tablet off at 1200: the window centre, as today', (
      tester,
    ) async {
      final rig = PlansTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.planNewPath,
        width: 1200,
        height: 1100,
        flags: kPlansFlagModes['ui_shell only']!,
        realForms: true,
      );
      await _tapInForm(tester, find.byTooltip('Pick a date'));
      expect(openDialogRect(tester).center.dx, closeTo(600, 1));
    });

    testWidgets('a date picked in the content-area dialog reaches the form', (
      tester,
    ) async {
      final rig = PlansTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.planNewPath,
        height: 1100,
        realForms: true,
      );
      final start = DateTime.now().add(const Duration(hours: 1));
      await _tapInForm(tester, find.byTooltip('Pick a date'));
      // Switch to typing the date and pick the day after the default start.
      await tester.tap(find.byIcon(Icons.edit_outlined).last);
      await tester.pumpAndSettle();
      final next = DateTime(start.year, start.month, start.day + 1);
      await tester.enterText(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(TextField),
        ),
        '${next.month}/${next.day}/${next.year}',
      );
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byTooltip('Pick a date'),
                matching: find.byType(Text),
              ),
            )
            .data,
        formatScheduledDate(next),
      );

      await _peek(tester, () async {
        expect(
          _inDialogPreview(find.textContaining(formatScheduledDate(next))),
          findsOneWidget,
        );
      });
    });
  });

  group('the plan page\'s dialogs and menu on the tablet layout', () {
    for (final w in <double>[700, 1024]) {
      testWidgets('at ${w.toInt()} the Cancel plan confirm is a D 280-400 on '
          'the content area', (tester) async {
        final rig = PlansTabletRig();
        _organise(rig);
        await rig.pump(
          tester,
          location: AppRouter.planPath(kBeaconIdA),
          width: w,
          height: 1000,
        );
        await _tapInForm(
          tester,
          find.widgetWithText(AppPillButton, 'Cancel plan'),
        );
        expect(find.text('Cancel this plan?'), findsOneWidget);
        final rect = openDialogRect(tester);
        expect(rect.width, inInclusiveRange(280, 400));
        expect(rect.center.dx, closeTo(_contentCentre(w), 1));
        await tester.tap(find.text('Keep'));
        await tester.pumpAndSettle();
        expect(rig.count('cancel'), 0);
      });

      for (final (location, title) in [
        (AppRouter.planNewPath, 'Discard this plan?'),
        (AppRouter.planEditPath(kBeaconIdA), 'Discard your changes?'),
      ]) {
        testWidgets('at ${w.toInt()} "$title" is a D 280-400 on the content '
            'area', (tester) async {
          final rig = PlansTabletRig();
          await rig.pump(
            tester,
            location: location,
            width: w,
            height: 1000,
            realForms: true,
          );
          await tester.enterText(
            _inForm(find.byType(TextField)).first,
            'Changed',
          );
          await tester.pumpAndSettle();
          await tester.tap(_inForm(find.widgetWithText(TextButton, 'Cancel')));
          await tester.pumpAndSettle();
          expect(find.text(title), findsOneWidget);
          final rect = openDialogRect(tester);
          expect(rect.width, inInclusiveRange(280, 400));
          expect(rect.center.dx, closeTo(_contentCentre(w), 1));
        });
      }
    }

    for (final w in <double>[834, 1024]) {
      testWidgets('at ${w.toInt()} Plan options stays an anchored menu', (
        tester,
      ) async {
        final rig = PlansTabletRig();
        await rig.pump(
          tester,
          location: AppRouter.planPath(kBeaconIdA),
          width: w,
          flags: {...kPlansTabletFlags, kFeatureMessaging, kFeatureReports},
        );
        final button = find.byTooltip('Plan options');
        expect(button, findsOneWidget);
        expect(
          find.ancestor(
            of: button,
            matching: find.byType(PopupMenuButton<String>),
          ),
          findsOneWidget,
        );
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.text('Report plan'), findsOneWidget);
        expect(find.byType(Dialog), findsNothing);
        expect(find.byType(BottomSheet), findsNothing);
        // Anchored: the menu opens at the button, not centred.
        final menu = tester.getRect(
          find
              .ancestor(
                of: find.text('Report plan'),
                matching: find.byType(Material),
              )
              .first,
        );
        expect((menu.top - tester.getRect(button).top).abs(), lessThan(100));
      });
    }
  });

  group('beacons off (the router sends these routes to /plans; should one '
      'show anyway)', () {
    final off = {...kPlansTabletFlags}..remove(kFeatureBeacons);
    for (final location in [AppRouter.planNewPath, _editPath]) {
      testWidgets('$location at 1024: no context pane and no preview', (
        tester,
      ) async {
        final rig = PlansTabletRig();
        await rig.pump(tester, location: location, flags: off, realForms: true);
        expect(tester.takeException(), isNull);
        expect(findContextPane(), findsNothing);
        expect(find.byType(PlanPreview), findsNothing);
      });
    }
  });

  group('RTL and focus', () {
    testWidgets('band B in RTL: no pane, the form beside the rail on the '
        'right, the tips marks at the start', (tester) async {
      final rig = PlansTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.planNewPath,
        textDirection: TextDirection.rtl,
        realForms: true,
      );
      expect(tester.takeException(), isNull);
      expect(findContextPane(), findsNothing);
      final page = tester.getRect(_formPage());
      final rail = tester.getRect(find.byKey(const ValueKey('tablet-rail')));
      expect(rail.right, 1024);
      expect(page.right, rail.left);
      expect(page.left, 0);
      // The tips' check marks sit at the start (right) of each line.
      await tester.tap(find.byKey(_tipsToggle));
      await tester.pumpAndSettle();
      final tip = _inForm(find.text(kPlanTips.first));
      final mark = find.descendant(
        of: find.ancestor(of: tip, matching: find.byType(Row)).first,
        matching: find.byIcon(Icons.check_circle_outline),
      );
      expect(tester.getRect(mark).left, greaterThan(tester.getRect(tip).right));
    });

    for (final w in <double>[744, 1024]) {
      testWidgets('at ${w.toInt()}: Cancel, Preview, then the tips toggle', (
        tester,
      ) async {
        final rig = PlansTabletRig();
        await rig.pump(
          tester,
          location: AppRouter.planNewPath,
          width: w,
          realForms: true,
        );
        bool focused(Finder f) => Focus.of(tester.element(f)).hasPrimaryFocus;
        final cancel = _inForm(find.text('Cancel'));
        Focus.of(tester.element(cancel)).requestFocus();
        await tester.pump();
        expect(focused(cancel), isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(
          focused(find.text(kPlanPreviewTitle)),
          isTrue,
          reason: 'Preview',
        );
        // Create is disabled until the form is valid, so it takes no focus.
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(focused(find.text(kPlanTipsTitle)), isTrue, reason: 'tips');
      });
    }
  });

  group('tablet matrix (plan section 5.5)', () {
    for (final (name, location) in [
      ('PlanCreate', AppRouter.planNewPath),
      ('PlanEdit', AppRouter.planEditPath(kBeaconIdA)),
    ]) {
      forEachThemeAndWidth(
        '$name: no overflow, the rail pinned at 0, no side column',
        (tester, env) async {
          final rig = PlansTabletRig();
          await rig.pump(
            tester,
            location: location,
            width: env.size.width,
            height: env.size.height,
            textScale: env.textScale,
            brightness: env.brightness,
            realForms: true,
          );
          expect(tester.takeException(), isNull);
          expect(
            tester.getRect(find.byKey(const ValueKey('tablet-rail'))).left,
            0,
          );
          expectTabletPanes(
            tester,
            _formPage(),
            env.size.width,
            hasPane: false,
          );
          expect(_previewAction, findsOneWidget);
          expect(find.byKey(_tipsToggle), findsOneWidget);
          expect(
            ShellGeometry.maybeOf(tester.element(_formPage()))?.tablet,
            isTrue,
          );
        },
        widths: kTabletMatrixWidths,
        textScales: kTabletTextScales,
        heights: kTabletHeights,
      );
    }
  });
}
