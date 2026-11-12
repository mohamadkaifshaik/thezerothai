import 'dart:io';
import 'dart:ui' as ui;

import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/posts/presentation/composer_route.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/post/conversation_row.dart';
import 'package:dzeroth/shared/widgets/post/post_card.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:dzeroth/shared/widgets/primitives/character_counter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/app_fonts.dart';
import '../../../support/composer_tablet_rig.dart';
import '../../../support/posts_fixtures.dart';

// ReplyComposer from the dzeroth-mobile, tablet and desktop mocks: one
// editor, the same functions; full screen puts Reply in the header, the
// dialogs put it in the footer by the character ring.

const _screenshots = bool.fromEnvironment('REPLY_SCREENSHOTS');

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_screenshots) return;
  await tester.runAsync(() async {
    final image = await captureImage(tester.element(find.byType(MaterialApp)));
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/artifacts/reply/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Finder get _reply => find.widgetWithText(AppPillButton, 'Reply');

Finder get _ring =>
    find.byWidgetPredicate((w) => w is CharacterCounter && w.ringOf != null);

ComposerPresentation _presentation(WidgetTester tester) =>
    ComposerPresentationScope.of(tester.element(find.byType(TextField)));

void _stubCreate(ComposerTabletRig rig) {
  when(
    () => rig.posts.createPost(
      idempotencyKey: any(named: 'idempotencyKey'),
      text: any(named: 'text'),
      replyToPostId: any(named: 'replyToPostId'),
      mediaIds: any(named: 'mediaIds'),
      mediaAltTexts: any(named: 'mediaAltTexts'),
    ),
  ).thenAnswer((_) async => postView(9, text: 'A reply'));
}

/// The layouts: the window, the flags and whether the reply opens over a
/// page (Home) or cold (a deep link).
final _cases =
    <
      ({
        String name,
        double width,
        double height,
        Set<String> flags,
        bool cold,
        ComposerPresentation expected,
      })
    >[
      (
        name: 'phone',
        width: 390,
        height: 844,
        flags: kComposerTabletFlags,
        cold: false,
        expected: ComposerPresentation.fullScreen,
      ),
      (
        name: 'tablet',
        width: 1024,
        height: 768,
        flags: kComposerTabletFlags,
        cold: false,
        expected: ComposerPresentation.tabletDialog,
      ),
      (
        name: 'desktop',
        width: 1440,
        height: 900,
        flags: kComposerTabletFlags,
        cold: false,
        expected: ComposerPresentation.legacyDialog,
      ),
      (
        name: 'tablet cold start',
        width: 1024,
        height: 768,
        flags: kComposerTabletFlags,
        cold: true,
        expected: ComposerPresentation.fullScreen,
      ),
      (
        name: '900 with no tablet flags',
        width: 900,
        height: 768,
        flags: kComposerFlagModes['neither']!,
        cold: false,
        expected: ComposerPresentation.legacyDialog,
      ),
    ];

Future<ComposerTabletRig> _open(
  WidgetTester tester, {
  required double width,
  required double height,
  required Set<String> flags,
  required bool cold,
  Brightness brightness = Brightness.light,
}) async {
  final rig = ComposerTabletRig();
  _stubCreate(rig);
  final path = AppRouter.composeReplyPath(rig.parent.post.postId);
  await rig.pump(
    tester,
    location: cold ? path : AppRouter.homePath,
    width: width,
    height: height,
    flags: flags,
    brightness: brightness,
  );
  if (!cold) await rig.push(tester, path);
  return rig;
}

void main() {
  setUpAll(() async {
    if (_screenshots) await loadAppFonts();
  });

  for (final c in _cases) {
    group('${c.name} (${c.width.toInt()} dp)', () {
      testWidgets('the look: where Reply sits', (tester) async {
        await _open(
          tester,
          width: c.width,
          height: c.height,
          flags: c.flags,
          cold: c.cold,
        );
        expect(_presentation(tester), c.expected);
        expect(_reply, findsOneWidget);
        expect(_ring, findsOneWidget);
        expect(find.text('Replying to @bob'), findsOneWidget);
        final reply = tester.getRect(_reply);
        final field = tester.getRect(find.byType(TextField));
        final card = tester.getRect(find.byType(PostCard));
        if (c.expected == ComposerPresentation.fullScreen) {
          // The header: above the post, at the end, Close at the start.
          expect(reply.bottom, lessThanOrEqualTo(card.top));
          expect(
            tester.getCenter(find.byTooltip('Close')).dy,
            closeTo(reply.center.dy, 1),
          );
          expect(tester.widget<CharacterCounter>(_ring).ringSize, 26);
        } else {
          // The footer: below the field, on the ring's line.
          expect(reply.top, greaterThan(field.bottom));
          expect(tester.getCenter(_ring).dy, closeTo(reply.center.dy, 1));
          expect(tester.widget<CharacterCounter>(_ring).ringSize, 24);
        }
      });

      testWidgets('the functions: counter, Reply enables, sends once', (
        tester,
      ) async {
        final rig = await _open(
          tester,
          width: c.width,
          height: c.height,
          flags: c.flags,
          cold: c.cold,
        );
        expect(find.bySemanticsLabel('Characters remaining: 280'), findsOne);
        expect(tester.widget<AppPillButton>(_reply).onPressed, isNull);
        await tester.enterText(find.byType(TextField), 'On my way');
        await tester.pump();
        expect(find.bySemanticsLabel('Characters remaining: 271'), findsOne);
        expect(tester.widget<AppPillButton>(_reply).onPressed, isNotNull);
        await tester.tap(_reply);
        await tester.pumpAndSettle();
        verify(
          () => rig.posts.createPost(
            idempotencyKey: any(named: 'idempotencyKey'),
            text: 'On my way',
            replyToPostId: rig.parent.post.postId,
            mediaIds: any(named: 'mediaIds'),
            mediaAltTexts: any(named: 'mediaAltTexts'),
          ),
        ).called(1);
        expect(find.byType(TextField), findsNothing, reason: 'it left');
      });

      testWidgets('Close with text asks first', (tester) async {
        await _open(
          tester,
          width: c.width,
          height: c.height,
          flags: c.flags,
          cold: c.cold,
        );
        await tester.enterText(find.byType(TextField), 'Keep this');
        await tester.pump();
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();
        expect(find.text('Discard reply?'), findsOneWidget);
        await tester.tap(find.text('Keep editing'));
        await tester.pumpAndSettle();
        expect(find.text('Keep this'), findsOneWidget);
      });

      testWidgets('over the limit: the ring and the count turn to error', (
        tester,
      ) async {
        await _open(
          tester,
          width: c.width,
          height: c.height,
          flags: c.flags,
          cold: c.cold,
        );
        await tester.enterText(find.byType(TextField), 'x' * 281);
        await tester.pump();
        expect(find.bySemanticsLabel('Characters over the limit: 1'), findsOne);
        expect(tester.widget<AppPillButton>(_reply).onPressed, isNull);
      });
    });
  }

  testWidgets('a reply the parent does not allow: hint, nothing to send', (
    tester,
  ) async {
    final rig = ComposerTabletRig();
    rig.parent.viewerReplyPermission =
        ReplyPermission.REPLY_PERMISSION_NOT_ALLOWED;
    _stubCreate(rig);
    await rig.pump(
      tester,
      location: AppRouter.composeReplyPath(rig.parent.post.postId),
      width: 390,
      height: 844,
    );
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(tester.widget<AppPillButton>(_reply).onPressed, isNull);
  });

  testWidgets('text survives phone -> tablet dialog -> desktop -> phone', (
    tester,
  ) async {
    final rig = await _open(
      tester,
      width: 390,
      height: 900,
      flags: kComposerTabletFlags,
      cold: false,
    );
    await tester.enterText(find.byType(TextField), 'Still here');
    await tester.pump();
    for (final (width, presentation) in [
      (1024.0, ComposerPresentation.tabletDialog),
      (1440.0, ComposerPresentation.legacyDialog),
      (390.0, ComposerPresentation.fullScreen),
    ]) {
      await rig.resize(tester, width);
      expect(_presentation(tester), presentation);
      expect(find.text('Still here'), findsOneWidget, reason: '$width');
      expect(tester.widget<AppPillButton>(_reply).onPressed, isNotNull);
    }
    expect(rig.getPostCalls, 1, reason: 'one editor across the switches');
  });

  testWidgets('phone at text scale 2.0: the header grows, nothing clips', (
    tester,
  ) async {
    final rig = ComposerTabletRig();
    _stubCreate(rig);
    await rig.pump(tester, width: 390, height: 844, textScale: 2);
    await rig.push(tester, AppRouter.composeReplyPath(rig.parent.post.postId));
    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(_reply).bottom,
      lessThanOrEqualTo(tester.getRect(find.byType(PostCard)).top),
    );
  });

  testWidgets('the rail runs past "Replying to"', (tester) async {
    await _open(
      tester,
      width: 390,
      height: 844,
      flags: kComposerTabletFlags,
      cold: false,
    );
    final rail = find.descendant(
      of: find.byType(ConversationRow),
      matching: find.byType(ColoredBox),
    );
    expect(
      tester.getRect(rail.last).bottom,
      greaterThan(tester.getRect(find.text('Replying to @bob')).bottom),
    );
  });

  testWidgets('the legacy dialog adds no window inset to its footer', (
    tester,
  ) async {
    final rig = ComposerTabletRig();
    await rig.pump(
      tester,
      width: 900,
      height: 768,
      flags: kComposerFlagModes['neither']!,
      padding: const EdgeInsets.only(top: 24, bottom: 34),
    );
    await rig.push(tester, AppRouter.composeReplyPath(rig.parent.post.postId));
    expect(_presentation(tester), ComposerPresentation.legacyDialog);
    final dialog = tester.getRect(findReplyComposer());
    // The footer: 8 + 48 + 8 above the dialog's bottom edge, no more.
    expect(
      dialog.bottom - tester.getCenter(_reply).dy,
      closeTo(AppSpacing.sm + AppSpacing.minTapTarget / 2, 1),
    );
  });

  group('screenshots', () {
    for (final brightness in Brightness.values) {
      for (final c in _cases.take(3)) {
        testWidgets('${c.name} ${brightness.name}', (tester) async {
          await _open(
            tester,
            width: c.width,
            height: c.height,
            flags: c.flags,
            cold: c.cold,
            brightness: brightness,
          );
          await tester.enterText(
            find.byType(TextField),
            'Count me in. Meet at the gate?',
          );
          await tester.pump();
          await _capture(tester, '${c.name}-${brightness.name}');
        }, skip: !_screenshots);
      }
    }
  });
}
