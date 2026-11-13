import 'dart:math' as math;

import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/router/main_shell.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/home/presentation/widgets/home_composer_entry.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/posts/presentation/composer_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/composer_tablet_rig.dart';
import '../../../support/posts_fixtures.dart';
import '../../../support/theme_harness.dart';

/// The composer and the reply composer on the tablet layout (tablet plan
/// sections 4.1 Composer / ReplyComposer, 5.2 "Composer and reply editors",
/// 5.4 and 5.6 T7): a content-area dialog at 600-1199 dp with both flags,
/// today's pages everywhere else, and one editor across every switch.
void main() {
  /// The content area's width on the tablet layout (no insets).
  double contentWidth(double w) => w - AppSize.railCompact;

  /// The tablet composer dialog's rect over a shell page at [w] x [h].
  Rect expectedDialog(double w, double h, {bool overShell = true}) {
    final left = overShell ? AppSize.railCompact : 0.0;
    final c = w - left;
    final width = math.min(AppSize.composerDialogMax, c - 48);
    final height = math.min(
      math.min(h * .85, AppSize.composerDialogMaxHeight),
      h - 48,
    );
    return Rect.fromCenter(
      center: Offset(left + c / 2, h / 2),
      width: width,
      height: height,
    );
  }

  void expectRect(Rect actual, Rect expected) {
    expect(actual.left, moreOrLessEquals(expected.left, epsilon: 1));
    expect(actual.top, moreOrLessEquals(expected.top, epsilon: 1));
    expect(actual.width, moreOrLessEquals(expected.width, epsilon: 1));
    expect(actual.height, moreOrLessEquals(expected.height, epsilon: 1));
  }

  group('composerPresentationFor', () {
    const dialog = ComposerPresentation.tabletDialog;
    const full = ComposerPresentation.fullScreen;
    const legacy = ComposerPresentation.legacyDialog;
    const desktop = ComposerPresentation.desktopDialog;
    final cases = <(double, bool, bool, bool, ComposerPresentation)>[
      // width, tablet flags, page below, reply -> presentation
      (390, true, true, false, full),
      (599, true, true, false, full),
      (600, true, true, false, dialog),
      (839, true, true, false, dialog),
      (840, true, true, false, dialog),
      (1199, true, true, false, dialog),
      (1200, true, true, false, desktop),
      (1440, true, true, false, desktop),
      (1440, false, true, false, desktop),
      (1440, true, false, false, full), // cold start (a deep link)
      (1024, true, false, false, full), // cold start
      (1024, false, true, false, full),
      (599, true, true, true, full),
      (600, true, true, true, dialog),
      (699, true, true, true, dialog),
      (1199, true, true, true, dialog),
      (1200, true, true, true, legacy),
      (1024, true, false, true, full), // cold start on the tablet layout
      (1200, true, false, true, legacy), // desktop: today's
      (600, false, true, true, full),
      (699, false, true, true, full),
      (700, false, true, true, legacy),
      (1024, false, false, true, legacy),
    ];
    for (final (width, tablet, below, reply, expected) in cases) {
      test('$width tablet=$tablet below=$below reply=$reply', () {
        expect(
          composerPresentationFor(
            width: width,
            tabletLayout: tablet,
            hasPageBelow: below,
            reply: reply,
          ),
          expected,
        );
      });
    }
  });

  group('/compose by width and flag mode', () {
    for (final MapEntry(key: mode, value: flags)
        in kComposerFlagModes.entries) {
      for (final width in <double>[
        390.0,
        599,
        600,
        700,
        839,
        840,
        1024,
        1199,
        1200,
      ]) {
        final tablet =
            mode == 'ui_shell + ui_tablet' && width >= 600 && width < 1200;
        final desktop = width >= 1200;
        testWidgets('$mode at ${width.toInt()}: '
            '${tablet
                ? 'the dialog'
                : desktop
                ? 'the desktop dialog'
                : 'full screen'}', (tester) async {
          final rig = ComposerTabletRig();
          await rig.pump(tester, width: width, height: 900, flags: flags);
          await rig.push(tester, AppRouter.composePath);

          expect(findComposer(), findsOneWidget);
          expect(tester.takeException(), isNull);
          if (tablet) {
            expect(dialogAround(findComposer()), findsOneWidget);
            expectRect(
              tester.getRect(findComposer()),
              expectedDialog(width, 900),
            );
            // The shell page stays painted behind the scrim.
            expect(find.text('home body'), findsOneWidget);
          } else if (desktop) {
            // The desktop Composer mock: 600 wide, hung 64 under the top,
            // the reply dialog's pattern; the page stays behind the scrim.
            expect(dialogAround(findComposer()), findsOneWidget);
            expectRect(
              tester.getRect(findComposer()),
              Rect.fromLTWH(
                (width - 600) / 2,
                AppSize.desktopModalTop,
                600,
                math.min(
                  AppSize.composerDialogMaxHeight,
                  900 - AppSize.desktopModalTop - AppSpacing.lg,
                ),
              ),
            );
            expect(find.text('home body'), findsOneWidget);
          } else {
            expect(dialogAround(findComposer()), findsNothing);
            expect(
              tester.getRect(findComposer()),
              Offset.zero & Size(width, 900),
            );
          }
        });
      }
    }
  });

  group('/compose/reply/:id by width and flag mode', () {
    for (final MapEntry(key: mode, value: flags)
        in kComposerFlagModes.entries) {
      for (final width in <double>[
        390.0,
        599,
        600,
        699,
        700,
        839,
        840,
        1199,
        1200,
      ]) {
        final tabletMode = mode == 'ui_shell + ui_tablet';
        final tablet = tabletMode && width >= 600 && width < 1200;
        final legacy = !tablet && width >= 700;
        testWidgets(
          '$mode at ${width.toInt()}: ${tablet
              ? 'the tablet dialog'
              : legacy
              ? "today's dialog"
              : 'full screen'}',
          (tester) async {
            final rig = ComposerTabletRig();
            await rig.pump(tester, width: width, height: 900, flags: flags);
            await rig.push(
              tester,
              AppRouter.composeReplyPath(rig.parent.post.postId),
            );

            expect(findReplyComposer(), findsOneWidget);
            expect(tester.takeException(), isNull);
            final rect = tester.getRect(findReplyComposer());
            if (tablet) {
              expectRect(rect, expectedDialog(width, 900));
            } else if (legacy && width >= 1200) {
              // Desktop (the ReplyComposer mock): 600 wide, hung 64 under
              // the top, at most 440 tall.
              expectRect(rect, Rect.fromLTWH((width - 600) / 2, 64, 600, 440));
            } else if (legacy) {
              // Today's: 600 wide, 85 % of the height, centred on the window.
              expectRect(
                rect,
                Rect.fromCenter(
                  center: Offset(width / 2, 450),
                  width: math.min(600, width - 80),
                  height: 900 * .85,
                ),
              );
            } else {
              expect(dialogAround(findReplyComposer()), findsNothing);
              expect(rect, Offset.zero & Size(width, 900));
            }
          },
        );
      }
    }
  });

  group('geometry (tablet plan section 5.4)', () {
    for (final width in kTabletMatrixWidths) {
      final height = kTabletHeights[width]!;
      testWidgets('${width.toInt()} x ${height.toInt()}: '
          'min(600, C - 48) wide, centred on the content area', (tester) async {
        final rig = ComposerTabletRig();
        await rig.pump(tester, width: width, height: height);
        await rig.push(tester, AppRouter.composePath);
        expectRect(
          tester.getRect(findComposer()),
          expectedDialog(width, height),
        );
        if (width == 600) {
          // The plan's check: 472 at 600 dp.
          expect(tester.getSize(findComposer()).width, 472);
        }
      });
    }

    testWidgets('landscape 1194 x 834 and 1024 x 768', (tester) async {
      for (final (w, h) in [(1194.0, 834.0), (1024.0, 768.0)]) {
        final rig = ComposerTabletRig();
        await rig.pump(tester, width: w, height: h);
        await rig.push(tester, AppRouter.composePath);
        expectRect(tester.getRect(findComposer()), expectedDialog(w, h));
        expect(contentWidth(w), greaterThan(600));
      }
    });

    testWidgets('a status bar adds no gap inside the dialog', (tester) async {
      final rig = ComposerTabletRig();
      await rig.pump(
        tester,
        width: 834,
        height: 1194,
        padding: const EdgeInsets.only(top: 24, bottom: 20),
      );
      await rig.push(tester, AppRouter.composePath);
      final dialog = tester.getRect(findComposer());
      final header = tester.getRect(find.byTooltip('Close'));
      // The header row sits at the top of the dialog, not 24 dp below it.
      expect(header.top - dialog.top, lessThan(24));
    });

    testWidgets('the keyboard: the dialog stays above it', (tester) async {
      final rig = ComposerTabletRig();
      await rig.pump(tester, width: 1024, height: 768);
      await rig.push(tester, AppRouter.composePath);
      tester.view.viewInsets = const FakeViewPadding(bottom: 380);
      await tester.pumpAndSettle();
      final rect = tester.getRect(findComposer());
      expect(rect.bottom, lessThanOrEqualTo(768 - 380 - 24 + 1));
      expect(rect.top, greaterThanOrEqualTo(24 - 1));
      expect(tester.takeException(), isNull);
    });

    for (final reply in [false, true]) {
      testWidgets('the keyboard at text scale 2.0 (${reply ? 'reply' : 'post'})'
          ': the field stays in view', (tester) async {
        final rig = ComposerTabletRig();
        await rig.pump(tester, textScale: 2);
        await rig.push(
          tester,
          reply
              ? AppRouter.composeReplyPath(rig.parent.post.postId)
              : AppRouter.composePath,
        );
        tester.view.viewInsets = const FakeViewPadding(bottom: 380);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final editor = reply ? findReplyComposer() : findComposer();
        final dialog = tester.getRect(editor);
        expect(dialog.bottom, lessThanOrEqualTo(768 - 380 - 24 + 1));
        final field = tester.getRect(find.byType(EditableText).first);
        // Some of the field is inside the dialog, above the keyboard.
        expect(field.top, lessThan(dialog.bottom));
        expect(field.bottom, greaterThan(dialog.top));
      });
    }

    testWidgets('RTL: centred on the content area beside a right-hand rail', (
      tester,
    ) async {
      final rig = ComposerTabletRig();
      await rig.pump(tester, textDirection: TextDirection.rtl);
      await rig.push(tester, AppRouter.composePath);
      final rect = tester.getRect(findComposer());
      expect(rect.center.dx, moreOrLessEquals((1024 - 80) / 2, epsilon: 1));
    });

    testWidgets('over a full-screen root page: centred on the window', (
      tester,
    ) async {
      final rig = ComposerTabletRig();
      await rig.pump(tester, location: kRigRootPagePath);
      await tester.tap(find.text('Reply from root'));
      await tester.pumpAndSettle();
      expectRect(
        tester.getRect(findReplyComposer()),
        expectedDialog(1024, 768, overShell: false),
      );
    });
  });

  group('the cold-start rule', () {
    for (final width in <double>[600.0, 834, 1024, 1199]) {
      testWidgets('${width.toInt()}: a typed /compose is full screen', (
        tester,
      ) async {
        final rig = ComposerTabletRig();
        await rig.pump(
          tester,
          width: width,
          height: 900,
          location: AppRouter.composePath,
        );
        expect(findComposer(), findsOneWidget);
        expect(dialogAround(findComposer()), findsNothing);
        expect(tester.getRect(findComposer()), Offset.zero & Size(width, 900));
      });

      testWidgets('${width.toInt()}: a reply deep link is full screen', (
        tester,
      ) async {
        final rig = ComposerTabletRig();
        await rig.pump(
          tester,
          width: width,
          height: 900,
          location: AppRouter.composeReplyPath(rig.parent.post.postId),
        );
        expect(findReplyComposer(), findsOneWidget);
        expect(dialogAround(findReplyComposer()), findsNothing);
        expect(
          tester.getRect(findReplyComposer()),
          Offset.zero & Size(width, 900),
        );
      });
    }

    testWidgets('a short desktop window: the dialog fits under the top', (
      tester,
    ) async {
      final rig = ComposerTabletRig();
      await rig.pump(tester, width: 1440, height: 400);
      await rig.push(
        tester,
        AppRouter.composeReplyPath(rig.parent.post.postId),
      );
      expect(tester.takeException(), isNull);
      expectRect(
        tester.getRect(findReplyComposer()),
        Rect.fromLTWH((1440 - 600) / 2, 64, 600, 400 - 64 - 24),
      );
    });

    testWidgets('1200: a reply deep link is the desktop dialog', (
      tester,
    ) async {
      final rig = ComposerTabletRig();
      await rig.pump(
        tester,
        width: 1200,
        height: 900,
        location: AppRouter.composeReplyPath(rig.parent.post.postId),
      );
      expect(dialogAround(findReplyComposer()), findsOneWidget);
      expect(tester.getSize(findReplyComposer()).width, 600);
      expect(tester.getTopLeft(findReplyComposer()).dy, 64);
    });
  });

  group('the draft survives every switch (tablet plan section 5.2)', () {
    testWidgets('/compose: 1024 -> 1200 -> 1199 -> 599 -> 600 -> 839 -> 840', (
      tester,
    ) async {
      final rig = ComposerTabletRig();
      await rig.pump(tester, height: 900);
      await rig.push(tester, AppRouter.composePath);
      await tester.enterText(find.byType(TextField).first, 'Half a thought');
      await tester.pump();
      final cubit = composerCubitOf(tester);
      final field = editorStateOf(tester);

      for (final (width, dialog) in [
        (1200.0, true),
        (1199.0, true),
        (599.0, false),
        (600.0, true),
        (839.0, true),
        (840.0, true),
      ]) {
        await rig.resize(tester, width);
        expect(
          dialogAround(findComposer()),
          dialog ? findsOneWidget : findsNothing,
          reason: '$width',
        );
        expect(composerCubitOf(tester), same(cubit), reason: '$width');
        expect(editorStateOf(tester), same(field), reason: '$width');
        expect(cubit.state.draft.text, 'Half a thought');
        expect(find.text('Half a thought'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('/compose?draft=: the opened draft keeps its cubit', (
      tester,
    ) async {
      final rig = ComposerTabletRig();
      await rig.pump(
        tester,
        flags: {...kComposerTabletFlags, kFeatureDrafts},
        location: kRigRootPagePath,
      );
      await tester.tap(find.text('Open draft'));
      await tester.pumpAndSettle();
      expect(find.text('A saved thought'), findsOneWidget);
      // Over a full-screen page: centred on the window.
      expectRect(
        tester.getRect(findComposer()),
        expectedDialog(1024, 768, overShell: false),
      );
      await tester.enterText(find.byType(TextField).first, 'Edited thought');
      await tester.pump();
      final cubit = composerCubitOf(tester);
      final field = editorStateOf(tester);
      for (final width in <double>[599.0, 600, 1200, 1024]) {
        await rig.resize(tester, width);
        expect(composerCubitOf(tester), same(cubit), reason: '$width');
        expect(editorStateOf(tester), same(field), reason: '$width');
        expect(find.text('Edited thought'), findsOneWidget);
      }
    });

    testWidgets('reply: 1024 -> 599 -> 600 -> 1200 -> 1199, one fetch', (
      tester,
    ) async {
      final rig = ComposerTabletRig();
      await rig.pump(tester, height: 900);
      await rig.push(
        tester,
        AppRouter.composeReplyPath(rig.parent.post.postId),
      );
      await tester.enterText(find.byType(TextField).first, 'Agreed');
      await tester.pump();
      final cubit = composerCubitOf(tester);
      final field = editorStateOf(tester);
      expect(rig.getPostCalls, 1);
      for (final width in <double>[599.0, 600, 1200, 1199]) {
        await rig.resize(tester, width);
        expect(composerCubitOf(tester), same(cubit), reason: '$width');
        expect(editorStateOf(tester), same(field), reason: '$width');
        expect(find.text('Agreed'), findsOneWidget);
      }
      expect(rig.getPostCalls, 1);
    });

    testWidgets('reply off the tablet layout: 699 <-> 700 keeps the editor', (
      tester,
    ) async {
      final rig = ComposerTabletRig();
      await rig.pump(
        tester,
        width: 699,
        height: 900,
        flags: kComposerFlagModes['neither']!,
      );
      await rig.push(
        tester,
        AppRouter.composeReplyPath(rig.parent.post.postId),
      );
      await tester.enterText(find.byType(TextField).first, 'Agreed');
      await tester.pump();
      final cubit = composerCubitOf(tester);
      final field = editorStateOf(tester);
      await rig.resize(tester, 700);
      expect(dialogAround(findReplyComposer()), findsOneWidget);
      expect(composerCubitOf(tester), same(cubit));
      expect(editorStateOf(tester), same(field));
      await rig.resize(tester, 699);
      expect(dialogAround(findReplyComposer()), findsNothing);
      expect(composerCubitOf(tester), same(cubit));
      expect(rig.getPostCalls, 1);
    });

    testWidgets('Drafts pushed over the dialog and back', (tester) async {
      final rig = ComposerTabletRig();
      await rig.pump(tester, flags: {...kComposerTabletFlags, kFeatureDrafts});
      await rig.push(tester, AppRouter.composePath);
      final cubit = composerCubitOf(tester);
      await tester.tap(find.text('Drafts'));
      await tester.pumpAndSettle();
      // Drafts is full screen over the dialog.
      expect(find.text('Drafts stub'), findsOneWidget);
      expect(
        tester.getRect(find.byType(Scaffold).last),
        Offset.zero & const Size(1024, 768),
      );
      await tester.tap(find.text('Pick the saved draft'));
      await tester.pumpAndSettle();
      // Back in the same dialog, with the picked draft loaded in place.
      expect(dialogAround(findComposer()), findsOneWidget);
      expect(composerCubitOf(tester), same(cubit));
      expect(find.text('A saved thought'), findsOneWidget);
    });
  });

  group('keys (tablet plan sections 2.1, 4.2, 5.5)', () {
    Future<void> focusCompose(WidgetTester tester) async {
      final button = find.byTooltip('New post');
      Focus.of(
        tester.element(
          find.descendant(of: button, matching: find.byType(Icon)).first,
        ),
      ).requestFocus();
      await tester.pump();
    }

    testWidgets('Escape closes the dialog and focus returns to New post', (
      tester,
    ) async {
      final rig = ComposerTabletRig();
      await rig.pump(tester);
      await focusCompose(tester);
      final invoker = FocusManager.instance.primaryFocus;
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(dialogAround(findComposer()), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(findComposer(), findsNothing);
      expect(rig.uri.path, AppRouter.homePath);
      expect(FocusManager.instance.primaryFocus, same(invoker));
    });

    testWidgets('Escape with an unsaved draft asks first, as Close does', (
      tester,
    ) async {
      final rig = ComposerTabletRig();
      await rig.pump(tester, flags: {...kComposerTabletFlags, kFeatureDrafts});
      await rig.push(tester, AppRouter.composePath);
      await tester.enterText(find.byType(TextField).first, 'Keep me');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Save post?'), findsOneWidget);
      expect(findComposer(), findsOneWidget);
      // The prompt is centred on the content area too, like the dialog.
      final prompt = tester.getRect(
        find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(prompt.center.dx, moreOrLessEquals(80 + 944 / 2, epsilon: 1));
    });

    for (final width in <double>[390.0, 599]) {
      testWidgets('${width.toInt()}: Escape does nothing (full screen)', (
        tester,
      ) async {
        final rig = ComposerTabletRig();
        await rig.pump(tester, width: width, height: 900);
        await rig.push(tester, AppRouter.composePath);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(findComposer(), findsOneWidget);
        expect(rig.uri.path, AppRouter.composePath);
      });
    }

    for (final (mode, flags) in [
      ('ui_shell only', kComposerFlagModes['ui_shell only']!),
      ('neither', kComposerFlagModes['neither']!),
    ]) {
      testWidgets('$mode at 834: Escape does nothing', (tester) async {
        final rig = ComposerTabletRig();
        await rig.pump(tester, width: 834, height: 900, flags: flags);
        await rig.push(tester, AppRouter.composePath);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(findComposer(), findsOneWidget);
      });
    }

    testWidgets('reply dialog: Escape closes it', (tester) async {
      final rig = ComposerTabletRig();
      await rig.pump(tester, width: 834, height: 1194);
      await rig.push(
        tester,
        AppRouter.composeReplyPath(rig.parent.post.postId),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(findReplyComposer(), findsNothing);
    });

    for (final width in <double>[1200.0, 1440]) {
      testWidgets(
        '${width.toInt()}: Escape closes the desktop compose dialog',
        (tester) async {
          final rig = ComposerTabletRig();
          await rig.pump(tester, width: width, height: 900);
          await rig.push(tester, AppRouter.composePath);
          expect(findComposer(), findsOneWidget);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(findComposer(), findsNothing);
          expect(rig.uri.path, isNot(AppRouter.composePath));
        },
      );
    }

    testWidgets('1200: Escape closes the desktop reply dialog', (tester) async {
      final rig = ComposerTabletRig();
      await rig.pump(tester, width: 1200, height: 900);
      await rig.push(
        tester,
        AppRouter.composeReplyPath(rig.parent.post.postId),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(findReplyComposer(), findsNothing);
    });

    testWidgets('1440: Escape with text typed asks first', (tester) async {
      final rig = ComposerTabletRig();
      await rig.pump(tester, width: 1440, height: 900);
      await rig.push(
        tester,
        AppRouter.composeReplyPath(rig.parent.post.postId),
      );
      await tester.enterText(find.byType(TextField), 'half a thought');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Discard reply?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('half a thought'), findsOneWidget);
    });

    testWidgets('900 off the tablet layout: Escape still does nothing', (
      tester,
    ) async {
      final rig = ComposerTabletRig();
      await rig.pump(
        tester,
        width: 900,
        height: 900,
        flags: kComposerFlagModes['neither']!,
      );
      await rig.push(
        tester,
        AppRouter.composeReplyPath(rig.parent.post.postId),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(findReplyComposer(), findsOneWidget);
    });
  });

  group('the scrim and the page underneath', () {
    /// The secondary animation of the shell's page on the root navigator,
    /// under the composer.
    Animation<double> underneath(WidgetTester tester) => ModalRoute.of(
      tester.element(find.byType(MainShell, skipOffstage: false)),
    )!.secondaryAnimation!;

    testWidgets('the scrim covers the rail: a rail tap does nothing', (
      tester,
    ) async {
      final rig = ComposerTabletRig();
      await rig.pump(tester);
      await rig.push(tester, AppRouter.composePath);
      await tester.tapAt(const Offset(40, 200));
      await tester.pumpAndSettle();
      expect(findComposer(), findsOneWidget);
      expect(rig.uri.path, AppRouter.composePath);
    });

    testWidgets('1024: the dialog fades in place; the page under it stays', (
      tester,
    ) async {
      final rig = ComposerTabletRig();
      await rig.pump(tester);
      final home = tester.getRect(find.text('home body'));
      rig.router.push(AppRouter.composePath).ignore();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      // Mid-transition: the dialog is already where it ends, fading.
      expectRect(tester.getRect(findComposer()), expectedDialog(1024, 768));
      final fade = tester.widget<FadeTransition>(
        find
            .ancestor(of: findComposer(), matching: find.byType(FadeTransition))
            .last,
      );
      expect(fade.opacity.value, inExclusiveRange(0, 1));
      expect(tester.getRect(find.text('home body')), home);
      // No exit animation: the page under the composer is not driven by
      // its route (the zoom paints a snapshot, so a rect cannot show it).
      expect(underneath(tester).value, 0);
      await tester.pumpAndSettle();
      expect(tester.getRect(find.text('home body')), home);
      // No exit animation: the page under the composer is not driven by
      // its route (the zoom paints a snapshot, so a rect cannot show it).
      expect(underneath(tester).value, 0);
    });

    testWidgets('390: the full-screen composer slides in over a still page', (
      tester,
    ) async {
      final rig = ComposerTabletRig();
      await rig.pump(tester, width: 390, height: 844);
      final home = tester.getRect(find.text('home body'));
      rig.router.push(AppRouter.composePath).ignore();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      // The platform transition moves the composer in ...
      expect(
        tester.getRect(findComposer()),
        isNot(Offset.zero & const Size(390, 844)),
      );
      // ... and the page underneath runs no exit animation (ruling 1).
      expect(tester.getRect(find.text('home body')), home);
      // No exit animation: the page under the composer is not driven by
      // its route (the zoom paints a snapshot, so a rect cannot show it).
      expect(underneath(tester).value, 0);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(findComposer()),
        Offset.zero & const Size(390, 844),
      );
    });

    testWidgets('the page under it is offstage only while full screen', (
      tester,
    ) async {
      final rig = ComposerTabletRig();
      await rig.pump(tester, width: 390, height: 900);
      await rig.push(tester, AppRouter.composePath);
      final home = find.text('home body', skipOffstage: false);
      // Full screen: an opaque page, as today's `MaterialPage`.
      expect(home, findsOneWidget);
      expect(find.text('home body'), findsNothing);
      for (final (width, shown) in [
        (1024.0, true),
        (1200.0, true),
        (834.0, true),
        (599.0, false),
      ]) {
        await rig.resize(tester, width);
        expect(
          find.text('home body'),
          shown ? findsOneWidget : findsNothing,
          reason: '$width',
        );
        expect(home, findsOneWidget, reason: '$width');
      }
    });

    testWidgets('a snack bar floats over the scrim on the content area', (
      tester,
    ) async {
      final rig = ComposerTabletRig();
      await rig.pump(tester);
      await rig.push(tester, AppRouter.composePath);
      ScaffoldMessenger.of(tester.element(find.byType(EditableText).first))
          .showSnackBar(const SnackBar(content: Text('A notice')));
      await tester.pumpAndSettle();
      final bars = find.byType(SnackBar);
      // The shell's copy under the scrim and the dialog route's on top, at
      // the same place: one visible bar, never inside the dialog.
      expect(bars, findsNWidgets(2));
      Rect surface(Finder bar) => tester.getRect(
        find.descendant(of: bar, matching: find.byType(Material)).first,
      );
      final top = surface(bars.last);
      expect(top, surface(bars.first));
      expect(top.center.dx, moreOrLessEquals(80 + 944 / 2, epsilon: 1));
      expect(top.width, AppSize.dialogMax);
      expect(
        find.descendant(of: dialogAround(findComposer()), matching: bars),
        findsNothing,
      );
    });

    testWidgets('the dialog is announced by name', (tester) async {
      final handle = tester.ensureSemantics();
      final rig = ComposerTabletRig();
      await rig.pump(tester);
      await rig.push(tester, AppRouter.composePath);
      expect(find.bySemanticsLabel('New post'), findsWidgets);
      handle.dispose();
    });
  });

  group('entry points', () {
    testWidgets('the rail New post button (band B)', (tester) async {
      final rig = ComposerTabletRig();
      await rig.pump(tester);
      await tester.tap(find.byTooltip('New post'));
      await tester.pumpAndSettle();
      expect(rig.uri.path, AppRouter.composePath);
      expectRect(tester.getRect(findComposer()), expectedDialog(1024, 768));
    });

    testWidgets('the rail New post button (band A)', (tester) async {
      final rig = ComposerTabletRig();
      await rig.pump(tester, width: 744, height: 1133);
      await tester.tap(find.byTooltip('New post'));
      await tester.pumpAndSettle();
      expectRect(tester.getRect(findComposer()), expectedDialog(744, 1133));
    });

    testWidgets('the phone FAB: full screen', (tester) async {
      final rig = ComposerTabletRig();
      await rig.pump(tester, width: 390, height: 844);
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(rig.uri.path, AppRouter.composePath);
      expect(dialogAround(findComposer()), findsNothing);
    });

    for (final width in <double>[390.0, 834, 1024]) {
      testWidgets('${width.toInt()}: the Home "Write a post" row', (
        tester,
      ) async {
        final rig = ComposerTabletRig();
        await rig.pump(tester, width: width, height: 900);
        await tester.tap(find.text(HomeComposerEntry.promptLabel));
        await tester.pumpAndSettle();
        expect(rig.uri.path, AppRouter.composePath);
        expect(
          dialogAround(findComposer()),
          width >= 600 ? findsOneWidget : findsNothing,
        );
      });
    }

    for (final width in <double>[390.0, 834, 1024, 1200]) {
      testWidgets('${width.toInt()}: Reply on a post', (tester) async {
        final rig = ComposerTabletRig();
        await rig.pump(tester, width: width, height: 900);
        await tester.tap(find.byIcon(Icons.chat_bubble_outline));
        await tester.pumpAndSettle();
        expect(
          rig.uri.path,
          AppRouter.composeReplyPath(rig.parent.post.postId),
        );
        expect(
          dialogAround(findReplyComposer()),
          width >= 600 ? findsOneWidget : findsNothing,
        );
        if (width >= 600 && width < 1200) {
          expectRect(
            tester.getRect(findReplyComposer()),
            expectedDialog(width, 900),
          );
        }
      });

      testWidgets('${width.toInt()}: Quote from the repost menu', (
        tester,
      ) async {
        final rig = ComposerTabletRig();
        await rig.pump(tester, width: width, height: 900);
        await tester.tap(find.byIcon(Icons.repeat));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Quote'));
        await tester.pumpAndSettle();
        expect(rig.uri.queryParameters['quote'], rig.parent.post.postId);
        expect(
          dialogAround(findComposer()),
          width >= 600 ? findsOneWidget : findsNothing,
        );
        // The quoted post is previewed in the dialog too.
        expect(find.text('A conversation worth continuing.'), findsWidgets);
      });
    }

    testWidgets('a community compose link (?community=) over Home', (
      tester,
    ) async {
      final rig = ComposerTabletRig();
      await rig.pump(tester);
      await rig.push(tester, AppRouter.composeCommunityPath(postId(9)));
      expect(rig.uri.queryParameters['community'], postId(9));
      expectRect(tester.getRect(findComposer()), expectedDialog(1024, 768));
    });

    testWidgets('a pushed location (a notification tap) over Home', (
      tester,
    ) async {
      final rig = ComposerTabletRig();
      await rig.pump(tester, width: 834, height: 1194);
      await rig.push(
        tester,
        AppRouter.composeReplyPath(rig.parent.post.postId),
      );
      expectRect(
        tester.getRect(findReplyComposer()),
        expectedDialog(834, 1194),
      );
    });

    testWidgets('Close returns to the page it was opened from', (tester) async {
      final rig = ComposerTabletRig();
      await rig.pump(tester);
      await rig.push(tester, AppRouter.composePath);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(findComposer(), findsNothing);
      expect(rig.uri.path, AppRouter.homePath);
    });
  });

  group('matrix (tablet plan section 5.5)', () {
    for (final width in kTabletMatrixWidths) {
      for (final scale in kTabletTextScales) {
        for (final brightness in Brightness.values) {
          testWidgets('${width.toInt()} x$scale ${brightness.name}', (
            tester,
          ) async {
            final height = kTabletHeights[width]!;
            final rig = ComposerTabletRig();
            await rig.pump(
              tester,
              width: width,
              height: height,
              textScale: scale,
              brightness: brightness,
            );
            await rig.push(tester, AppRouter.composePath);
            expect(tester.takeException(), isNull);
            expectRect(
              tester.getRect(findComposer()),
              expectedDialog(width, height),
            );
            await tester.tap(find.byTooltip('Close'));
            await tester.pumpAndSettle();
            await rig.push(
              tester,
              AppRouter.composeReplyPath(rig.parent.post.postId),
            );
            expect(tester.takeException(), isNull);
            expectRect(
              tester.getRect(findReplyComposer()),
              expectedDialog(width, height),
            );
          });
        }
      }
    }

    for (final width in kBoundaryWidths) {
      testWidgets('boundary ${width.toInt()}', (tester) async {
        final rig = ComposerTabletRig();
        await rig.pump(tester, width: width, height: 900);
        await rig.push(tester, AppRouter.composePath);
        expect(tester.takeException(), isNull);
        // The tablet dialog below 1200, the desktop dialog from it.
        expect(
          dialogAround(findComposer()),
          width >= 600 ? findsOneWidget : findsNothing,
        );
      });
    }
  });
}
