import 'dart:io';
import 'dart:ui' as ui;

import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:dzeroth/features/engagement/data/bookmarks_repository.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/bookmarks_cubit.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_cubit.dart';
import 'package:dzeroth/features/engagement/presentation/bookmarks_screen.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/shared/widgets/primitives/app_back_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/app_fonts.dart';
import '../../../support/bookmarks_fixtures.dart';
import '../../../support/context_pane_rig.dart';
import '../../../support/fake_transport.dart';

// Bookmarks from the dzeroth-mobile, tablet and desktop mocks: "Bookmarks"
// over the viewer's @handle at every width. The mock's History tab has no
// backend, so the tabs stay Bookmarks | Likes (behind likes_list).

const _screenshots = bool.fromEnvironment('EXPLORE_PEOPLE_SCREENSHOTS');

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_screenshots) return;
  await tester.runAsync(() async {
    final image = await captureImage(tester.element(find.byType(MaterialApp)));
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/artifacts/explore-people/$name.png');
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

class _MockEngagementRepository extends Mock implements EngagementRepository {}

class _MockPostsRepository extends Mock implements PostsRepository {}

Future<void> _open(
  WidgetTester tester,
  Size size, {
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  final server = FakeBookmarksServer();
  final repo = BookmarksRepository(
    apiClient: ApiClient.withTransport(FakeTransport(server.handle)),
    gate: ServiceFeatureGate(isEnabled: () => true),
    epoch: SessionEpoch(),
  );
  addTearDown(repo.dispose);
  final overlay = BookmarksCubit(repository: repo, viewRoute: '/bookmarks');
  addTearDown(overlay.close);
  final engagement = EngagementCubit(repository: _MockEngagementRepository());
  addTearDown(engagement.close);
  final posts = _MockPostsRepository();
  when(() => posts.subFeatureEnabled(any())).thenReturn(true);
  await ContextPaneRig().pump(
    tester,
    location: '/bookmarks',
    width: size.width,
    height: size.height,
    textScale: textScale,
    brightness: brightness,
    page: (path) => const BookmarksScreen(),
    wrap: (app) => MultiRepositoryProvider(
      providers: [
        RepositoryProvider<BookmarksRepository>.value(value: repo),
        RepositoryProvider<PostsRepository>.value(value: posts),
        RepositoryProvider<UnexpectedErrorReporter>.value(
          value: (error, stack) {},
        ),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider<EngagementCubit>.value(value: engagement),
          BlocProvider<BookmarksCubit>.value(value: overlay),
        ],
        child: app,
      ),
    ),
  );
}

void main() {
  setUpAll(() async {
    if (_screenshots) await loadAppFonts();
  });

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    testWidgets('$name: Bookmarks over the viewer handle', (tester) async {
      await _open(tester, size);
      final header = find.byType(AppBackHeader);
      expect(
        find.descendant(of: header, matching: find.text('Bookmarks')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: header, matching: find.text('@alice')),
        findsOneWidget,
      );
      expect(find.byTooltip('Back'), findsOneWidget);
    });
  }

  testWidgets('phone at text scale 2.0: nothing overflows', (tester) async {
    await _open(tester, _sizes['phone']!, textScale: 2);
    expect(tester.takeException(), isNull);
  });

  group('screenshots', () {
    for (final brightness in Brightness.values) {
      for (final MapEntry(key: name, value: size) in _sizes.entries) {
        testWidgets('bookmarks $name ${brightness.name}', (tester) async {
          await _open(tester, size, brightness: brightness);
          await _capture(tester, 'bookmarks-$name-${brightness.name}');
        }, skip: !_screenshots);
      }
    }
  });
}
