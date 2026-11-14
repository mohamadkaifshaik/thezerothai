import 'dart:convert';

import 'package:bloc_test/bloc_test.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/articles/domain/article.dart';
import 'package:dzeroth/features/articles/domain/articles_repository.dart';
import 'package:dzeroth/features/articles/presentation/articles_screen.dart';
import 'package:dzeroth/features/articles/presentation/widgets/article_image_block.dart';
import 'package:dzeroth/features/media/data/image_picker_service.dart';
import 'package:dzeroth/features/media/data/media_repository.dart';
import 'package:dzeroth/features/media/domain/image_processor.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/domain/reply_audience.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/failing_image_cache.dart';

// Article image blocks: the reader (matched, unmatched, flag off), the editor
// (Insert gated on article_images) and the flag-off round trip that must not
// delete images or unknown blocks.

const _imageId = '1111111111111111111';
const _missingId = '2222222222222222222';

const _unknown = {
  'kind': 'gallery',
  'runs': [],
  'items': [1, 2],
};

class _Onboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _Picker extends Mock implements ImagePickerService {}

class _Processor extends Mock implements ImageProcessor {}

class _Media extends Mock implements MediaRepository {}

common.MediaRef _ref() => common.MediaRef(
  mediaId: _imageId,
  url: 'https://cdn.example/m/full.jpg',
  thumbUrl: 'https://cdn.example/m/thumb.jpg',
  width: 1600,
  height: 900,
  contentType: 'image/jpeg',
);

class _Repo implements ArticlesRepository {
  _Repo({this.withMatch = true});
  final bool withMatch;
  final saved = <ArticleDraft>[];

  late final record = ArticleRecord(
    draft: ArticleDraft(
      id: 'draft',
      authorId: 'owner',
      title: 'Harbour notes',
      blocks: [
        ArticleBlock(
          kind: ArticleBlockKind.paragraph,
          runs: [ArticleTextRun(text: 'Body of the notes')],
        ),
        ArticleBlock(
          kind: ArticleBlockKind.image,
          mediaId: _imageId,
          altText: 'A harbour',
          caption: 'Evening light',
        ),
        ArticleBlock(kind: ArticleBlockKind.image, mediaId: _missingId),
        ArticleBlock.opaque(_unknown),
      ],
    ),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    images: withMatch ? {_imageId: _ref()} : const {},
  );

  @override
  bool get canChooseReplyAudience => false;

  @override
  Future<ArticleRecord> create() async => record;

  @override
  Future<ArticleRecord> get(String id) async => record;

  @override
  Future<ArticlePage> list({
    required bool published,
    String pageToken = '',
  }) async => ArticlePage([record]);

  @override
  Future<ArticleRecord> save(
    ArticleDraft draft, {
    required int expectedRevision,
  }) async {
    saved.add(draft);
    // A save answer carries no images.
    return ArticleRecord(
      draft: draft.revise(expectedRevision: expectedRevision),
      updatedAt: record.updatedAt,
    );
  }

  @override
  Future<void> delete(ArticleRecord article) async {}

  @override
  Future<ArticleRecord> publish(
    ArticleRecord article, {
    required String idempotencyKey,
    String caption = '',
    ReplyAudience replyAudience = ReplyAudience.everyone,
  }) async => article;
}

const _sizes = <String, Size>{
  'phone': Size(390, 844),
  'tablet': Size(1024, 768),
  'desktop': Size(1440, 900),
};

Future<void> _open(
  WidgetTester tester, {
  required _Repo repo,
  required bool flag,
  required bool reader,
  Size size = const Size(390, 844),
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final onboarding = _Onboarding();
  whenListen(
    onboarding,
    const Stream<OnboardingState>.empty(),
    initialState: OnboardingState(
      status: OnboardingStatus.ready,
      enabledFeatures: {if (flag) kFeatureArticleImages},
    ),
  );
  await tester.pumpWidget(
    MultiRepositoryProvider(
      providers: [
        RepositoryProvider<ArticlesRepository>.value(value: repo),
        RepositoryProvider<ImagePickerService>.value(value: _Picker()),
        RepositoryProvider<ImageProcessor>.value(value: _Processor()),
        RepositoryProvider<MediaRepository>.value(value: _Media()),
      ],
      child: BlocProvider<OnboardingBloc>.value(
        value: onboarding,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: brightness == Brightness.dark ? appDarkTheme : appLightTheme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: ArticlesScreen(articleId: 'draft', reader: reader),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    // Set, never read: reading builds the real manager (path_provider).
    CachedNetworkImageProvider.defaultCacheManager = FailingImageCacheManager();
  });

  group('reader', () {
    testWidgets('a matched image renders and opens the viewer', (tester) async {
      await _open(tester, repo: _Repo(), flag: true, reader: true);
      expect(find.text('Body of the notes'), findsOneWidget);
      expect(find.text('Evening light'), findsOneWidget);
      // The unmatched block is a placeholder, the unknown kind is skipped.
      expect(find.text('Image unavailable'), findsOneWidget);
      expect(find.textContaining('gallery'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.bySemanticsLabel('A harbour'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close image'), findsOneWidget);
      await tester.tap(find.byTooltip('Close image'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close image'), findsNothing);
    });

    testWidgets('an unmatched image shows the placeholder, no error', (
      tester,
    ) async {
      await _open(
        tester,
        repo: _Repo(withMatch: false),
        flag: true,
        reader: true,
      );
      expect(find.byType(ArticleImagePlaceholder), findsNWidgets(2));
      expect(find.text('Body of the notes'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('flag off shows placeholders even with a match', (
      tester,
    ) async {
      await _open(tester, repo: _Repo(), flag: false, reader: true);
      expect(find.byType(ArticleImagePlaceholder), findsNWidgets(2));
      expect(find.text('Body of the notes'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('editor', () {
    Future<void> openInsert(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Insert'));
      await tester.pumpAndSettle();
    }

    testWidgets('Insert offers Image only when article_images is on', (
      tester,
    ) async {
      await _open(
        tester,
        repo: _Repo(),
        flag: true,
        reader: false,
        size: const Size(1440, 900),
      );
      await openInsert(tester);
      expect(find.text('Image'), findsOneWidget);
      expect(find.text('Divider'), findsOneWidget);
    });

    testWidgets('Insert hides Image when the flag is off', (tester) async {
      await _open(
        tester,
        repo: _Repo(),
        flag: false,
        reader: false,
        size: const Size(1440, 900),
      );
      await openInsert(tester);
      expect(find.text('Image'), findsNothing);
      expect(find.text('Divider'), findsOneWidget);
    });

    for (final flag in [true, false]) {
      testWidgets('re-save keeps image and unknown blocks (flag $flag)', (
        tester,
      ) async {
        final repo = _Repo();
        await _open(tester, repo: repo, flag: flag, reader: false);
        await tester.enterText(
          find.byKey(const Key('article-title')),
          'Harbour notes, edited',
        );
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(repo.saved, isNotEmpty);
        final body = jsonDecode(repo.saved.last.bodyJson) as List;
        expect(body.length, 4);
        expect(body[1], {
          'kind': 'image',
          'runs': [],
          'mediaId': _imageId,
          'altText': 'A harbour',
          'caption': 'Evening light',
        });
        expect(body[2]['mediaId'], _missingId);
        expect(body[3], _unknown);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('editing alt text and caption reaches the saved body', (
      tester,
    ) async {
      final repo = _Repo();
      await _open(tester, repo: repo, flag: true, reader: false);
      await tester.enterText(
        find.widgetWithText(TextField, 'Evening light'),
        'Dusk',
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      final body = jsonDecode(repo.saved.last.bodyJson) as List;
      expect(body[1]['caption'], 'Dusk');
      expect(body[1]['altText'], 'A harbour');
    });
  });

  group('layouts', () {
    for (final MapEntry(key: name, value: size) in _sizes.entries) {
      for (final flag in [true, false]) {
        for (final brightness in Brightness.values) {
          for (final scale in [1.0, 2.0]) {
            final label =
                '$name flag=$flag ${brightness.name} x$scale: no overflow';
            testWidgets('reader $label', (tester) async {
              await _open(
                tester,
                repo: _Repo(),
                flag: flag,
                reader: true,
                size: size,
                textScale: scale,
                brightness: brightness,
              );
              expect(find.byType(ArticleImagePlaceholder), findsWidgets);
              expect(tester.takeException(), isNull);
            });
            testWidgets('editor $label', (tester) async {
              await _open(
                tester,
                repo: _Repo(),
                flag: flag,
                reader: false,
                size: size,
                textScale: scale,
                brightness: brightness,
              );
              expect(find.text('Alt text (optional)'), findsWidgets);
              expect(tester.takeException(), isNull);
            });
          }
        }
      }
    }
  });
}
