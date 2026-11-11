import 'dart:async';

import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/context_pane.dart';
import 'package:dzeroth/core/widgets/shell_geometry.dart';
import 'package:dzeroth/features/beacons/domain/beacon_labels.dart';
import 'package:dzeroth/features/beacons/domain/beacons_feature_flag.dart';
import 'package:dzeroth/features/beacons/presentation/beacon_screen.dart';
import 'package:dzeroth/features/beacons/presentation/create_beacon_screen.dart';
import 'package:dzeroth/features/beacons/presentation/edit_beacon_screen.dart';
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
    show expectTabletPanes, findContextPane, inContextPane;
import '../../../support/plans_tablet_rig.dart';
import '../../../support/tablet_modal_harness.dart' show openDialogRect;
import '../../../support/theme_harness.dart';

const _widths = <double>[360, 599, 600, 839, 840, 1024, 1199, 1200];

bool _tabletFlags(Set<String> flags) =>
    flags.contains(kFeatureUiShell) && flags.contains(kFeatureUiTablet);

bool _tabletWidth(double w) =>
    w >= AppBreakpoints.mobile && w < AppBreakpoints.tablet;

bool _bandA(double w) =>
    w >= AppBreakpoints.mobile && w < AppBreakpoints.expanded;

bool _bandB(double w) =>
    w >= AppBreakpoints.expanded && w < AppBreakpoints.tablet;

/// The kinds of the context pane's sections, top to bottom (empty: no pane).
List<ContextSectionKind> _paneKinds(WidgetTester tester) {
  final pane = findContextPane();
  if (pane.evaluate().isEmpty) return const [];
  return [for (final s in tester.widget<ContextPane>(pane).sections) s.kind];
}

const _formKinds = [
  ContextSectionKind.planPreview,
  ContextSectionKind.planTips,
  ContextSectionKind.links,
];

/// The create or edit form (the route child).
Finder _formPage() => find.byWidgetPredicate(
  (w) => w is CreateBeaconScreen || w is EditBeaconScreen,
);

Finder _inForm(Finder f) => find.descendant(of: _formPage(), matching: f);

/// [f] inside the preview in the pane.
Finder _inPanePreview(Finder f) =>
    find.descendant(of: inContextPane(find.byType(PlanPreview)), matching: f);

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

void main() {
  group('PlanCreate (/plans/new): flag modes x widths', () {
    for (final MapEntry(key: mode, value: flags) in kPlansFlagModes.entries) {
      for (final w in _widths) {
        final tablet = _tabletFlags(flags) && _tabletWidth(w);
        final inline = tablet && _bandA(w);
        final pane = tablet && _bandB(w);
        testWidgets('$mode at ${w.toInt()}: '
            '${inline
                ? 'Preview action and inline tips'
                : pane
                ? 'preview and tips in the pane'
                : 'today\'s form'}', (tester) async {
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
          expect(_previewAction, inline ? findsOneWidget : findsNothing);
          expect(
            find.byKey(_tipsToggle),
            inline ? findsOneWidget : findsNothing,
          );
          // No list pane beside the form (plan section 3, "Not on").
          expect(findPlansPane(), findsNothing);
          if (pane) {
            expect(_paneKinds(tester), _formKinds);
            expect(inContextPane(find.text(kPlanPreviewTitle)), findsOneWidget);
            expect(
              _inPanePreview(find.text(kPlanPreviewUntitled)),
              findsOneWidget,
            );
            expect(
              _inPanePreview(find.text(kMeetingPointNote)),
              findsOneWidget,
            );
            expect(inContextPane(find.text(kPlanTipsTitle)), findsOneWidget);
            for (final tip in kPlanTips) {
              expect(inContextPane(find.text(tip)), findsOneWidget);
            }
          } else {
            expect(findContextPane(), findsNothing);
            expect(find.byType(PlanPreview), findsNothing);
            expect(find.text(kPlanTipsTitle), inline ? findsOne : findsNothing);
          }
          // Tips are collapsed inline: no tip text until opened.
          if (!pane) expect(find.text(kPlanTips.first), findsNothing);
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
        final inline = tablet && _bandA(w);
        final pane = tablet && _bandB(w);
        testWidgets('$mode at ${w.toInt()}: '
            '${inline
                ? 'Preview action and inline tips'
                : pane
                ? 'preview and tips in the pane'
                : 'today\'s form'}', (tester) async {
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
          expect(_previewAction, inline ? findsOneWidget : findsNothing);
          expect(
            find.byKey(_tipsToggle),
            inline ? findsOneWidget : findsNothing,
          );
          expect(findPlansPane(), findsNothing);
          // The meeting point's privacy note: on the tablet layout only.
          expect(
            _inForm(find.text(kMeetingPointNote)),
            tablet ? findsOneWidget : findsNothing,
          );
          if (pane) {
            expect(_paneKinds(tester), _formKinds);
            expect(_inPanePreview(find.text(_rigTitle)), findsOneWidget);
            expect(
              _inPanePreview(find.text(kMeetingPointNote)),
              findsOneWidget,
            );
            expect(inContextPane(find.text(kPlanTipsTitle)), findsOneWidget);
          } else {
            expect(findContextPane(), findsNothing);
            expect(find.byType(PlanPreview), findsNothing);
          }
          // F28 stays out: start, duration and cost are not editable.
          expect(find.byTooltip('Pick a date'), findsNothing);
          expect(find.byTooltip('Pick a time'), findsNothing);
          expect(find.byType(ChoiceChip), findsNothing);
          expect(rig.server.calls, ['get']);
        });
      }
    }
  });

  group('band B: the pane follows the pushed form', () {
    testWidgets('New plan from the Plans list: the preview and tips replace '
        'the list pane; back restores it', (tester) async {
      final rig = PlansTabletRig();
      await rig.pump(tester, realForms: true);
      expect(findPlansPane(), findsOneWidget);
      expect(findContextPane(), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, 'New plan'));
      // One frame: the pane is there with its cards, never blank.
      await tester.pump();
      expect(_paneKinds(tester), _formKinds);
      expect(inContextPane(find.text(kPlanPreviewTitle)), findsOneWidget);
      expect(inContextPane(find.text(kPlanTipsTitle)), findsOneWidget);
      await tester.pumpAndSettle();
      expect(findPlansPane(), findsNothing);
      expect(_inPanePreview(find.text(kPlanPreviewUntitled)), findsOneWidget);
      expectTabletPanes(tester, _formPage(), 1024);

      rig.router.pop();
      await tester.pumpAndSettle();
      expect(findPlansPane(), findsOneWidget);
      expect(findContextPane(), findsNothing);
    });

    testWidgets('Edit from a plan: the loading preview after one frame, then '
        'the plan; no tips while it loads', (tester) async {
      final rig = PlansTabletRig();
      _organise(rig);
      await rig.pump(
        tester,
        location: AppRouter.planPath(kBeaconIdA),
        realForms: true,
      );
      final hold = rig.server.holdGet = Completer<void>();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Edit'));
      await tester.pump();
      expect(_paneKinds(tester), _formKinds);
      expect(inContextPane(find.text(kPlanPreviewTitle)), findsOneWidget);
      expect(inContextPane(find.text(kPlanTipsTitle)), findsNothing);
      await tester.pumpAndSettle();
      // Still loading: the card over its skeleton, no tips, no preview text.
      expect(inContextPane(find.text(kPlanPreviewTitle)), findsOneWidget);
      expect(inContextPane(find.bySemanticsLabel('Loading plan')), findsOne);
      expect(inContextPane(find.text(kPlanTipsTitle)), findsNothing);
      expect(find.byType(PlanPreview), findsNothing);

      hold.complete();
      await tester.pumpAndSettle();
      expect(_inPanePreview(find.text(_rigTitle)), findsOneWidget);
      expect(inContextPane(find.text(kPlanTipsTitle)), findsOneWidget);

      rig.router.pop();
      await tester.pumpAndSettle();
      expect(findPlansPane(), findsOneWidget);
      expect(findContextPane(), findsNothing);
    });

    testWidgets('a failed load: no preview and no tips over the error', (
      tester,
    ) async {
      final rig = PlansTabletRig();
      rig.server.refusals.add(const NetworkException('down'));
      await rig.pump(tester, location: _editPath, realForms: true);
      expect(find.text('Try again'), findsOneWidget);
      expect(_paneKinds(tester), _formKinds);
      expect(inContextPane(find.text(kPlanPreviewTitle)), findsNothing);
      expect(inContextPane(find.text(kPlanTipsTitle)), findsNothing);

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(_inPanePreview(find.text(_rigTitle)), findsOneWidget);
      expect(inContextPane(find.text(kPlanTipsTitle)), findsOneWidget);
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
      expect(inContextPane(find.text(kPlanPreviewTitle)), findsNothing);
      expect(inContextPane(find.text(kPlanTipsTitle)), findsNothing);
    });
  });

  group('band B: the live preview follows every field', () {
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

      expect(_inPanePreview(find.text(kPlanPreviewUntitled)), findsOneWidget);
      expect(_inPanePreview(find.text(kPlanPreviewNoVenue)), findsOneWidget);
      expect(_inPanePreview(find.text('0 of 3 seats taken')), findsOneWidget);
      expect(_inPanePreview(find.text('Alice A')), findsOneWidget);
      expect(_inPanePreview(find.text('Organiser')), findsOneWidget);
      // No details yet: nothing drawn for them.
      expect(_inPanePreview(find.text('Bring snacks')), findsNothing);

      await _fillCreate(tester);
      expect(_inPanePreview(find.text('Board games')), findsOneWidget);
      expect(_inPanePreview(find.text(kPlanPreviewUntitled)), findsNothing);
      expect(_inPanePreview(find.text('Bring snacks')), findsOneWidget);
      expect(_inPanePreview(find.text('Library hall')), findsOneWidget);
      expect(_inPanePreview(find.text(kPlanPreviewNoVenue)), findsNothing);
      expect(_inPanePreview(find.text(kMeetingPointNote)), findsOneWidget);

      await _tapInForm(
        tester,
        _inForm(find.widgetWithText(ChoiceChip, 'Walk')),
      );
      expect(
        _inPanePreview(find.byIcon(Icons.directions_walk)),
        findsOneWidget,
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
      expect(label('Pick a time'), contains('9:30'));
      expect(
        _inPanePreview(
          find.text(
            '${label('Pick a date')} at ${label('Pick a time')} · 60 min',
          ),
        ),
        findsOneWidget,
      );

      await _tapInForm(
        tester,
        _inForm(find.widgetWithText(ChoiceChip, '90 min')),
      );
      expect(
        _inPanePreview(find.textContaining(RegExp(r' · 90 min$'))),
        findsOneWidget,
      );

      await _tapInForm(tester, find.byTooltip('More spots'));
      expect(_inPanePreview(find.text('0 of 4 seats taken')), findsOneWidget);

      await _tapInForm(
        tester,
        _inForm(find.widgetWithText(ChoiceChip, 'Split evenly')),
      );
      expect(_inPanePreview(find.text('Cost: Split evenly')), findsOneWidget);

      await _tapInForm(
        tester,
        _inForm(find.widgetWithText(ChoiceChip, 'Open to chat')),
      );
      expect(_inPanePreview(find.text('Chat: Open to chat')), findsOneWidget);
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
      expect(_inPanePreview(find.text('Organiser')), findsNothing);
      expect(_inPanePreview(find.text(kPlanPreviewUntitled)), findsOneWidget);
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
      expect(_inPanePreview(find.text('2 of 3 seats taken')), findsOneWidget);
      expect(_inPanePreview(find.text('Full')), findsNothing);
      expect(_inPanePreview(find.text('Orla')), findsOneWidget);

      await tester.enterText(
        _inForm(find.widgetWithText(TextField, _rigTitle)),
        ' Tea at four ',
      );
      await tester.enterText(
        _inForm(find.widgetWithText(TextField, 'Venue of $_rigTitle')),
        'Library',
      );
      await tester.pumpAndSettle();
      expect(_inPanePreview(find.text('Tea at four')), findsOneWidget);
      expect(_inPanePreview(find.text('Library')), findsOneWidget);

      await _tapInForm(tester, find.byTooltip('Fewer spots'));
      expect(_inPanePreview(find.text('2 of 2 seats taken')), findsOneWidget);
      expect(_inPanePreview(find.text('Full')), findsOneWidget);
      await _tapInForm(tester, find.byTooltip('More spots'));
      expect(_inPanePreview(find.text('2 of 3 seats taken')), findsOneWidget);
      expect(_inPanePreview(find.text('Full')), findsNothing);
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
      testWidgets('plan page at ${w.toInt()} x$scale: the label whole, at '
          'the end of the row', (tester) async {
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
        final row = find.ancestor(of: label, matching: find.byType(Row)).first;
        expect(tester.getRect(label).right, tester.getRect(row).right);
      });
    }

    testWidgets('the 320 dp pane at 2.0: the label gives way, nothing '
        'overflows', (tester) async {
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
      final label = _inPanePreview(find.text('Organiser'));
      expect(label, findsOneWidget);
      final row = find.ancestor(of: label, matching: find.byType(Row)).first;
      expect(
        tester.getRect(label).right,
        lessThanOrEqualTo(tester.getRect(row).right),
      );
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
      final previewTitle = style(_inPanePreview(find.text('Board games')));
      final previewVenue = style(_inPanePreview(find.text('Library hall')));
      final previewNote = style(_inPanePreview(find.text(kMeetingPointNote)));
      final previewTop = tester.getTopLeft(
        _inPanePreview(find.text(kMeetingPointNote)),
      );
      final previewVenueBottom = tester.getBottomLeft(
        _inPanePreview(find.text('Library hall')),
      );
      expect(previewTop.dy, previewVenueBottom.dy, reason: 'note under venue');

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

  group('band A: the Preview dialog', () {
    for (final w in <double>[600, 744, 839]) {
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

    testWidgets('edit at 744: the dialog shows the plan with the edits', (
      tester,
    ) async {
      final rig = PlansTabletRig();
      await rig.pump(
        tester,
        location: _editPath,
        width: 744,
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
      expect(_inDialogPreview(find.text(kMeetingPointNote)), findsOneWidget);
      expect(openDialogRect(tester).center.dx, closeTo(_contentCentre(744), 1));
      expect(rig.server.calls, ['get']);
    });

    testWidgets('edit at 744 while loading and after a failure: no Preview '
        'action and no tips', (tester) async {
      final rig = PlansTabletRig();
      final hold = rig.server.holdGet = Completer<void>();
      await rig.pump(tester, location: _editPath, width: 744, realForms: true);
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
        width: 744,
        realForms: true,
      );
      expect(find.text('Try again'), findsOneWidget);
      expect(_previewAction, findsNothing);
      expect(find.byKey(_tipsToggle), findsNothing);
    });
  });

  group('band A: Tips for a good plan, inline and collapsible', () {
    for (final location in [AppRouter.planNewPath, _editPath]) {
      testWidgets('$location at 744: collapsed, a real 48 dp toggle with its '
          'expanded state, at the top of the form', (tester) async {
        final semantics = tester.ensureSemantics();
        final rig = PlansTabletRig();
        await rig.pump(tester, location: location, width: 744, realForms: true);
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
          isSemantics(isButton: true, hasExpandedState: true, isExpanded: true),
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
  });

  group('state across resizes', () {
    testWidgets('create: 839 -> 840 -> 1024 -> 1199 -> 1200 -> 599 -> 600 -> '
        '839 keeps the form, the text and the open tips; the preview moves '
        'between the pane and the dialog', (tester) async {
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
        expect(
          _inPanePreview(find.text('Board games')),
          _bandB(w) ? findsOneWidget : findsNothing,
          reason: '$w',
        );
        expect(
          _previewAction,
          _bandA(w) ? findsOneWidget : findsNothing,
          reason: '$w',
        );
        expect(
          find.byKey(_tipsToggle),
          _bandA(w) ? findsOneWidget : findsNothing,
          reason: '$w',
        );
      }
      // Back in band A, the tips are still open.
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
        expect(
          _inPanePreview(find.text('Tea at four')),
          _bandB(w) ? findsOneWidget : findsNothing,
          reason: '$w',
        );
      }
      expect(rig.server.calls, ['get']);
    });
  });

  group('date and time pickers (T2 deferred them here; plan section 5.4)', () {
    for (final w in <double>[599, 600, 744, 1024, 1199, 1200]) {
      final tablet = _tabletWidth(w);
      for (final (tooltip, name) in [
        ('Pick a date', 'date'),
        ('Pick a time', 'time'),
      ]) {
        testWidgets('$name at ${w.toInt()}: centred on the '
            '${tablet ? 'content area' : 'window'}', (tester) async {
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
            closeTo(tablet ? _contentCentre(w) : w / 2, 1),
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
      expect(
        _inPanePreview(find.textContaining(formatScheduledDate(next))),
        findsOneWidget,
      );
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
          find.widgetWithText(OutlinedButton, 'Cancel plan'),
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
      testWidgets('$location at 1024: the global set, no preview or tips', (
        tester,
      ) async {
        final rig = PlansTabletRig();
        await rig.pump(tester, location: location, flags: off, realForms: true);
        expect(tester.takeException(), isNull);
        expect(
          _paneKinds(tester),
          isNot(contains(ContextSectionKind.planPreview)),
        );
        expect(
          _paneKinds(tester),
          isNot(contains(ContextSectionKind.planTips)),
        );
        expect(_paneKinds(tester).last, ContextSectionKind.links);
        expect(inContextPane(find.byType(PlanPreview)), findsNothing);
        expect(inContextPane(find.text(kPlanTipsTitle)), findsNothing);
      });
    }
  });

  group('RTL and focus', () {
    testWidgets('band B in RTL: the pane on the left, then the form, then '
        'the rail', (tester) async {
      final rig = PlansTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.planNewPath,
        textDirection: TextDirection.rtl,
        realForms: true,
      );
      expect(tester.takeException(), isNull);
      final pane = tester.getRect(findContextPane());
      final page = tester.getRect(_formPage());
      final rail = tester.getRect(find.byKey(const ValueKey('tablet-rail')));
      expect(pane.left, 0);
      expect(page.left, greaterThan(pane.right));
      expect(rail.right, 1024);
      expect(_inPanePreview(find.text(kPlanPreviewUntitled)), findsOneWidget);
      // The tips' check marks sit at the start (right) of each line.
      final tip = inContextPane(find.text(kPlanTips.first));
      final mark = find.descendant(
        of: find.ancestor(of: tip, matching: find.byType(Row)).first,
        matching: find.byIcon(Icons.check_circle_outline),
      );
      expect(tester.getRect(mark).left, greaterThan(tester.getRect(tip).right));
    });

    testWidgets('band A: Cancel, Preview, then the tips toggle', (
      tester,
    ) async {
      final rig = PlansTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.planNewPath,
        width: 744,
        realForms: true,
      );
      bool focused(Finder f) => Focus.of(tester.element(f)).hasPrimaryFocus;
      final cancel = _inForm(find.text('Cancel'));
      Focus.of(tester.element(cancel)).requestFocus();
      await tester.pump();
      expect(focused(cancel), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focused(find.text(kPlanPreviewTitle)), isTrue, reason: 'Preview');
      // Create is disabled until the form is valid, so it takes no focus.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focused(find.text(kPlanTipsTitle)), isTrue, reason: 'tips');
    });

    testWidgets('band B: the form, then the pane', (tester) async {
      final rig = PlansTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.planNewPath,
        height: 2000,
        realForms: true,
      );
      bool focused(Finder f) => Focus.of(tester.element(f)).hasPrimaryFocus;
      final lastChip = _inForm(find.widgetWithText(ChoiceChip, 'Public'));
      final privacy = inContextPane(find.text('Privacy Policy'));
      Focus.of(
        tester.element(
          find.descendant(of: lastChip, matching: find.text('Public')),
        ),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focused(privacy), isTrue, reason: 'then the context pane');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(
        focused(find.descendant(of: lastChip, matching: find.text('Public'))),
        isTrue,
        reason: 'Shift+Tab back into the form',
      );
    });
  });

  group('tablet matrix (plan section 5.5)', () {
    for (final (name, location) in [
      ('PlanCreate', AppRouter.planNewPath),
      ('PlanEdit', AppRouter.planEditPath(kBeaconIdA)),
    ]) {
      forEachThemeAndWidth(
        '$name: no overflow, the rail pinned at 0, the panes of section 3',
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
          expectTabletPanes(tester, _formPage(), env.size.width);
          if (_bandB(env.size.width)) {
            expect(_paneKinds(tester), _formKinds);
            final paneRect = tester.getRect(findContextPane());
            for (final kind in _paneKinds(tester)) {
              final section = tester.getRect(find.byKey(ValueKey(kind)).first);
              expect(section.left, greaterThanOrEqualTo(paneRect.left));
              expect(section.right, lessThanOrEqualTo(paneRect.right));
            }
          } else {
            expect(_previewAction, findsOneWidget);
            expect(find.byKey(_tipsToggle), findsOneWidget);
          }
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

  group('text scale 2.0 in the 320 dp pane (840 x 1194)', () {
    for (final brightness in Brightness.values) {
      for (final (name, location) in [
        ('PlanCreate', AppRouter.planNewPath),
        ('PlanEdit', AppRouter.planEditPath(kBeaconIdA)),
      ]) {
        testWidgets('$name, ${brightness.name}: the preview and the tips fit', (
          tester,
        ) async {
          final rig = PlansTabletRig();
          await rig.pump(
            tester,
            location: location,
            width: 840,
            height: 1194,
            textScale: 2,
            brightness: brightness,
            realForms: true,
          );
          expect(tester.takeException(), isNull);
          expect(tester.getSize(findContextPane()).width, 320);
          final last = inContextPane(find.text(kPlanTips.last));
          await tester.scrollUntilVisible(
            last,
            100,
            scrollable: find.descendant(
              of: findContextPane(),
              matching: find.byType(Scrollable),
            ),
          );
          expect(tester.takeException(), isNull);
          final pane = tester.getRect(findContextPane());
          expect(tester.getRect(last).right, lessThanOrEqualTo(pane.right));
          expect(_inPanePreview(find.text(kMeetingPointNote)), findsOneWidget);
        });
      }
    }
  });
}
