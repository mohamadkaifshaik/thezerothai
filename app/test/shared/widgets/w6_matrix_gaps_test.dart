import 'package:dzeroth/features/posts/presentation/widgets/draft_dialogs.dart';
import 'package:dzeroth/shared/widgets/poll_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/poll_fixtures.dart';
import '../../support/theme_harness.dart';

/// W6-19: the widgets of W6 that had no 360 / 600 / 1200 x light / dark x
/// 1.0 / 1.3 / 2.0 matrix of their own: the compact poll embed and the
/// "Save post?" dialog with each of its notes.
void main() {
  group('PollEmbedSummary', () {
    forEachThemeAndWidth('compact line and read-only options fit', (
      tester,
      env,
    ) async {
      await pumpThemed(
        tester,
        SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: PollEmbedSummary(
              poll: pollOf(
                labels: ['A' * 25, '😀' * 25, 'مرحبا بالعالم الجميل', 'D'],
              ),
              now: kPollNow,
              showOptions: true,
              onOpen: () {},
            ),
          ),
        ),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Poll · 4 choices'), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('an ended poll fits', (tester, env) async {
      await pumpThemed(
        tester,
        PollEmbedSummary(
          poll: pollOf(closesIn: const Duration(hours: -1)),
          now: kPollNow,
        ),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);
      expect(find.textContaining('ended'), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);
  });

  group('SavePostDialog', () {
    for (final note in <String?>[null, kDraftsPhotosNote, kDraftsGifNote]) {
      forEachThemeAndWidth('note=${note ?? 'none'} fits, buttons are 48dp', (
        tester,
        env,
      ) async {
        SavePostChoice? answer;
        await pumpThemed(
          tester,
          Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async =>
                    answer = await showSavePostDialog(context, mediaNote: note),
                child: const Text('open'),
              ),
            ),
          ),
          brightness: env.brightness,
          size: env.size,
          textScale: env.textScale,
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.text('Save post?'), findsOneWidget);
        if (note != null) expect(find.text(note), findsOneWidget);
        expect(tester.takeException(), isNull);
        for (final label in ['Save', 'Discard', 'Keep editing']) {
          await tester.ensureVisible(find.text(label));
          final box = tester.getSize(
            find
                .ancestor(
                  of: find.text(label),
                  matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
                )
                .first,
          );
          expect(box.height, greaterThanOrEqualTo(48), reason: label);
        }
        await tester.tap(find.text('Keep editing'));
        await tester.pumpAndSettle();
        expect(answer, isNull, reason: 'Keep editing is not an answer');
      }, textScales: kMatrixTextScalesLarge);
    }
  });
}
