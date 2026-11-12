import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/articles/domain/article.dart';
import 'package:dzeroth/features/articles/domain/articles_repository.dart';
import 'package:dzeroth/features/articles/presentation/articles_screen.dart';
import 'package:dzeroth/features/media/data/image_picker_service.dart';
import 'package:dzeroth/features/media/data/media_repository.dart';
import 'package:dzeroth/features/media/domain/image_processor.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/domain/reply_audience.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/app_fonts.dart';

// The article editor from the dzeroth-mobile, tablet and desktop mocks: one
// set of actions at every width. The phone's header carries the word count
// and Publish (Preview and Focus mode in a menu, so it fits at 320 dp with
// large text) and its tools sit under the page; tablet and desktop have
// "Article" over "Draft · N words", Preview and Publish pills, and the tools
// in a pill under the header.

const _screenshots = bool.fromEnvironment('ARTICLE_SCREENSHOTS');

const _sizes = <String, Size>{
  'phone': Size(390, 844),
  'tablet': Size(1024, 768),
  'desktop': Size(1440, 900),
};

class _Onboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _Picker extends Mock implements ImagePickerService {}

class _Processor extends Mock implements ImageProcessor {}

class _Media extends Mock implements MediaRepository {}

class _Repo implements ArticlesRepository {
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
      ],
    ),
    updatedAt: DateTime.now().toUtc(),
  );

  @override
  bool get canChooseReplyAudience => true;

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
  }) async => ArticleRecord(
    draft: draft.revise(expectedRevision: expectedRevision),
    updatedAt: record.updatedAt,
  );

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

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_screenshots) return;
  await tester.runAsync(() async {
    final image = await captureImage(tester.element(find.byType(MaterialApp)));
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/artifacts/article/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    if (_screenshots) await loadAppFonts();
  });

  final picker = _Picker();

  Future<GoRouter> open(
    WidgetTester tester,
    Size size, {
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
        enabledFeatures: const {kFeatureUiShell, kFeatureUiTablet},
      ),
    );
    final router = GoRouter(
      initialLocation: '/compose/articles/edit/draft',
      routes: [
        GoRoute(
          path: '/home',
          builder: (_, _) => const Scaffold(body: Text('Home')),
        ),
        for (final suffix in [
          '/edit/:id',
          '/edit/:id/preview',
          '/edit/:id/focus',
        ])
          GoRoute(
            path: '/compose/articles$suffix',
            builder: (_, state) => ArticlesScreen(
              articleId: state.pathParameters['id'],
              preview: suffix.contains('/preview'),
              focus: suffix.endsWith('/focus'),
            ),
          ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<ArticlesRepository>.value(value: _Repo()),
          RepositoryProvider<ImagePickerService>.value(value: picker),
          RepositoryProvider<ImageProcessor>.value(value: _Processor()),
          RepositoryProvider<MediaRepository>.value(value: _Media()),
        ],
        child: BlocProvider<OnboardingBloc>.value(
          value: onboarding,
          child: MaterialApp.router(
            debugShowCheckedModeBanner: false,
            routerConfig: router,
            theme: brightness == Brightness.dark ? appDarkTheme : appLightTheme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  String path(GoRouter router) =>
      router.routerDelegate.currentConfiguration.uri.path;

  /// Opens a header action: a pill from 600 dp, the "More" menu on a phone.
  Future<void> press(
    WidgetTester tester,
    String label, {
    required bool phone,
  }) async {
    if (phone) {
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
    } else {
      await tester.tap(
        find.widgetWithText(AppPillButton, label).evaluate().isEmpty
            ? find.byTooltip(label)
            : find.widgetWithText(AppPillButton, label),
      );
    }
    await tester.pumpAndSettle();
  }

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    final phone = size.width < 600;

    group('$name (${size.width.toInt()} dp)', () {
      testWidgets('the look', (tester) async {
        await open(tester, size);
        expect(find.text('ARTICLE · DRAFT'), findsOneWidget);
        expect(find.text('Add cover image'), findsOneWidget);
        expect(find.text('Saved'), findsOneWidget);
        // Phone: the count alone and Preview in the menu; wide: the title,
        // its subtitle and a Preview pill.
        expect(find.text('4 words'), phone ? findsOneWidget : findsNothing);
        expect(
          find.text('Draft · 4 words'),
          phone ? findsNothing : findsOneWidget,
        );
        expect(find.text('Article'), phone ? findsNothing : findsOneWidget);
        expect(
          find.widgetWithText(AppPillButton, 'Preview'),
          phone ? findsNothing : findsOneWidget,
        );
        expect(find.widgetWithText(AppPillButton, 'Publish'), findsOneWidget);
        // The tools: under the page on a phone, above it otherwise.
        final bold = tester.getTopLeft(find.byTooltip('Bold')).dy;
        final title = tester
            .getTopLeft(find.byKey(const Key('article-title')))
            .dy;
        phone
            ? expect(bold, greaterThan(title))
            : expect(bold, lessThan(title));
        expect(tester.takeException(), isNull);
      });

      testWidgets('Preview opens the preview', (tester) async {
        final router = await open(tester, size);
        await press(tester, 'Preview', phone: phone);
        expect(path(router), '/compose/articles/edit/draft/preview');
      });

      testWidgets('Focus mode opens focus mode', (tester) async {
        final router = await open(tester, size);
        await press(tester, 'Focus mode', phone: phone);
        expect(path(router), '/compose/articles/edit/draft/focus');
      });

      testWidgets('Publish opens the publish dialog', (tester) async {
        await open(tester, size);
        await tester.tap(find.widgetWithText(AppPillButton, 'Publish'));
        await tester.pumpAndSettle();
        expect(find.text('Publish Article'), findsOneWidget);
      });

      testWidgets('Add cover image opens the picker', (tester) async {
        when(() => picker.pickImages(limit: 1))
            .thenAnswer((_) async => <Uint8List>[]);
        await open(tester, size);
        await tester.tap(find.text('Add cover image'));
        await tester.pumpAndSettle();
        verify(() => picker.pickImages(limit: 1)).called(1);
      });

      testWidgets('Add paragraph adds a field', (tester) async {
        await open(tester, size);
        final fields = find.byType(TextField).evaluate().length;
        await tester.ensureVisible(find.text('Add paragraph'));
        await tester.tap(find.text('Add paragraph'));
        await tester.pumpAndSettle();
        expect(find.byType(TextField).evaluate().length, fields + 1);
      });
    });
  }

  testWidgets('a phone at text scale 2.0 and 320 dp: nothing overflows', (
    tester,
  ) async {
    await open(tester, const Size(320, 640), textScale: 2);
    expect(tester.takeException(), isNull);
    expect(find.widgetWithText(AppPillButton, 'Publish'), findsOneWidget);
  });

  group('screenshots', () {
    for (final brightness in Brightness.values) {
      for (final MapEntry(key: name, value: size) in _sizes.entries) {
        testWidgets('$name ${brightness.name}', (tester) async {
          await open(tester, size, brightness: brightness);
          await _capture(tester, '$name-${brightness.name}');
        }, skip: !_screenshots);
      }
    }
  });
}
