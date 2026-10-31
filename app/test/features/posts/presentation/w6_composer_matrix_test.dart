import 'package:dzeroth/features/engagement/domain/engagement_feature_flag.dart';
import 'package:dzeroth/features/media/domain/media_feature_flag.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_attachment_rules.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/features/posts/presentation/widgets/composer_extras_buttons.dart';
import 'package:dzeroth/features/posts/presentation/widgets/draft_dialogs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_drafts_repository.dart';
import '../../../support/media_fixtures.dart';
import '../../../support/theme_harness.dart';
import '../../../support/w6_composer_rig.dart';

class _MockPostsRepository extends Mock implements PostsRepository {}

/// W6-19: the composer across the flag product (`polls` x `drafts` x `gif`,
/// with `engagement` and `media` on and off), the exclusions between poll,
/// photos, GIF and schedule, and the "Save post?" wording with a GIF.
///
/// The rig leaves a provider out when its flag is off, so a composer that
/// reads `DraftsRepository`, `GifSource` or `GifPreparer` without the flag
/// fails here with a `ProviderNotFoundException`.
void main() {
  setUpAll(registerMediaFallbacks);

  late _MockPostsRepository posts;
  late FakeDraftsRepository drafts;

  setUp(() {
    posts = _MockPostsRepository();
    drafts = FakeDraftsRepository();
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
  });

  Finder gifBtn() => find.byType(ComposerGifButton);
  Finder pollBtn() => find.byType(ComposerPollButton);
  Finder inner(Finder f) =>
      find.descendant(of: f, matching: find.byType(IconButton));
  Finder draftsBtn() => find.widgetWithText(TextButton, 'Drafts');
  Finder photoBtn() => find.widgetWithIcon(IconButton, Icons.image_outlined);
  Finder scheduleBtn() =>
      find.widgetWithIcon(IconButton, Icons.schedule_send_outlined);
  bool pressable(WidgetTester tester, Finder f) =>
      tester.widget<IconButton>(f).onPressed != null;

  group('flag product', () {
    for (final polls in [false, true]) {
      for (final draftsOn in [false, true]) {
        for (final gif in [false, true]) {
          for (final engagement in [false, true]) {
            for (final media in [false, true]) {
              final name =
                  'polls=$polls drafts=$draftsOn gif=$gif '
                  'engagement=$engagement media=$media';
              testWidgets(name, (tester) async {
                final features = {
                  kFeaturePosts,
                  kFeatureScheduledPosts,
                  if (polls) kFeaturePolls,
                  if (draftsOn) kFeatureDrafts,
                  if (gif) kFeatureGif,
                  if (engagement) kFeatureEngagement,
                  if (media) kFeatureMedia,
                };
                await pumpW6Composer(
                  tester,
                  posts: posts,
                  features: features,
                  drafts: drafts,
                );
                expect(tester.takeException(), isNull);
                // Poll: polls + engagement. GIF: gif + media (the GIF rides
                // the media pipeline). Drafts: drafts alone.
                expect(
                  pollBtn(),
                  polls && engagement ? findsOneWidget : findsNothing,
                );
                expect(gifBtn(), gif && media ? findsOneWidget : findsNothing);
                expect(photoBtn(), media ? findsOneWidget : findsNothing);
                expect(draftsBtn(), draftsOn ? findsOneWidget : findsNothing);
                // Typing never throws and, with drafts off, never writes.
                await tester.enterText(find.byType(TextField), 'hello');
                await tester.pump();
                expect(tester.takeException(), isNull);
                expect(drafts.autosaves, draftsOn ? 1 : 0);
              });
            }
          }
        }
      }
    }
  });

  group('exclusions', () {
    final features = {...kW6AllFlags, kFeatureScheduledPosts};

    testWidgets('an open poll disables photos, GIF and Schedule', (
      tester,
    ) async {
      await pumpW6Composer(
        tester,
        posts: posts,
        features: features,
        drafts: drafts,
      );
      expect(pressable(tester, photoBtn()), isTrue);
      expect(pressable(tester, scheduleBtn()), isTrue);
      await tester.tap(inner(pollBtn()));
      await tester.pumpAndSettle();
      expect(pressable(tester, photoBtn()), isFalse);
      expect(pressable(tester, inner(gifBtn())), isFalse);
      expect(pressable(tester, scheduleBtn()), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('removing the poll gives photos, GIF and Schedule back', (
      tester,
    ) async {
      await pumpW6Composer(
        tester,
        posts: posts,
        features: features,
        drafts: drafts,
      );
      await tester.tap(inner(pollBtn()));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Remove poll'));
      await tester.tap(find.text('Remove poll'));
      await tester.pumpAndSettle();
      expect(pressable(tester, photoBtn()), isTrue);
      expect(pressable(tester, scheduleBtn()), isTrue);
      expect(pressable(tester, inner(gifBtn())), isTrue);
    });
  });

  group('Save post? with attachments', () {
    Future<void> leave(WidgetTester tester) async {
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    }

    Future<W6ComposerRig> withGif(
      WidgetTester tester, {
      Set<String>? flags,
    }) async {
      final rig = await pumpW6Composer(
        tester,
        posts: posts,
        drafts: drafts,
        features: flags ?? kW6AllFlags,
      );
      rig.gifSource.next = imageBytes('a');
      await tester.tap(inner(gifBtn()));
      await tester.pumpAndSettle();
      return rig;
    }

    testWidgets('text + a GIF: the GIF line, not the photos line', (
      tester,
    ) async {
      await withGif(tester);
      await tester.enterText(find.byType(TextField), 'look at this');
      await tester.pump();
      await leave(tester);

      expect(find.text('Save post?'), findsOneWidget);
      expect(find.text(kDraftsGifNote), findsOneWidget);
      expect(find.text(kDraftsPhotosNote), findsNothing);
      expect(tester.takeException(), isNull);

      // Saving keeps the text and nothing of the GIF.
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(drafts.rows.single.text, 'look at this');
      expect(find.text('home page'), findsOneWidget);
    });

    testWidgets('text + photos: the photos line, not the GIF line', (
      tester,
    ) async {
      final rig = await pumpW6Composer(tester, posts: posts, drafts: drafts);
      rig.picker.next = [imageBytes('a')];
      await tester.tap(find.byTooltip('Add photos'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'look at this');
      await tester.pump();
      await leave(tester);
      expect(find.text(kDraftsPhotosNote), findsOneWidget);
      expect(find.text(kDraftsGifNote), findsNothing);
    });

    testWidgets('a GIF alone: "Your GIF will not be saved.", no draft', (
      tester,
    ) async {
      await withGif(tester);
      await leave(tester);
      expect(find.text('Discard this post?'), findsOneWidget);
      expect(find.text('Your GIF will not be saved.'), findsOneWidget);
      expect(find.text('Save post?'), findsNothing);
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(drafts.rows, isEmpty);
      expect(find.text('home page'), findsOneWidget);
    });

    testWidgets('drafts off, text + a GIF: no draft question, no write', (
      tester,
    ) async {
      await withGif(tester, flags: {...kW6AllFlags}..remove(kFeatureDrafts));
      await tester.enterText(find.byType(TextField), 'look');
      await tester.pump();
      await leave(tester);
      expect(find.text('Save post?'), findsNothing);
      expect(find.text('Your GIF will not be saved.'), findsOneWidget);
      expect(drafts.rows, isEmpty);
    });
  });

  group('responsive matrix with a GIF attached', () {
    forEachThemeAndWidth('Save post? with the GIF line fits', (
      tester,
      env,
    ) async {
      final rig = await pumpW6Composer(
        tester,
        posts: posts,
        drafts: drafts,
        size: env.size,
        brightness: env.brightness,
        textScale: env.textScale,
      );
      rig.gifSource.next = imageBytes('a');
      await tester.tap(inner(gifBtn()));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'look at this');
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text(kDraftsGifNote), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('GIF attached with a long emoji text fits', (
      tester,
      env,
    ) async {
      final rig = await pumpW6Composer(
        tester,
        posts: posts,
        drafts: drafts,
        size: env.size,
        brightness: env.brightness,
        textScale: env.textScale,
      );
      rig.gifSource.next = imageBytes('a');
      await tester.tap(inner(gifBtn()));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '🇮🇳' * 100);
      await tester.pump();
      expect(find.byTooltip('Remove GIF'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, textScales: kMatrixTextScalesLarge);
  });
}
