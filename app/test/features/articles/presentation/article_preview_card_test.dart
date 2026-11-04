import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart';
import 'package:dzeroth/shared/widgets/post/article_preview_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  testWidgets('article snapshot opens the addressable reader', (tester) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            body: ArticlePreviewCard(
              article: ArticlePreview(
                articleId: 'a' * 32,
                title: 'Title',
                excerpt: 'Summary',
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/articles/:id',
          builder: (_, state) =>
              Scaffold(body: Text('reader ${state.pathParameters['id']}')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    expect(find.text('Summary'), findsOneWidget);
    await tester.tap(find.text('Title'));
    await tester.pumpAndSettle();
    expect(find.text('reader ${'a' * 32}'), findsOneWidget);
  });

  test(
    'article reader links survive authentication without accepting paths',
    () {
      final id = 'a' * 32;
      expect(
        AppRouter.deepLinkTarget(Uri.parse('/articles/$id')),
        '/articles/$id',
      );
      expect(
        AppRouter.deepLinkTarget(Uri.parse('/articles/$id/focus')),
        '/articles/$id/focus',
      );
      expect(AppRouter.deepLinkTarget(Uri.parse('/articles/%2Fetc')), isNull);
      expect(
        AppRouter.deepLinkTarget(Uri.parse('https://example.com/articles/$id')),
        isNull,
      );
    },
  );
}
