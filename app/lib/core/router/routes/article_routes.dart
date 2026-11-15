import 'package:go_router/go_router.dart';

import '../../../features/articles/presentation/articles_screen.dart';
import '../../../features/auth/presentation/widgets/auth_gate.dart';
import '../app_router.dart';

/// The article editor, preview, focus and reader routes.
List<RouteBase> articleRoutes() => [
  for (final suffix in [
    '',
    '/edit/:id',
    '/edit/:id/preview',
    '/edit/:id/focus',
    '/edit/:id/preview/focus',
  ])
    GoRoute(
      path: '${AppRouter.articlesPath}$suffix',
      builder: (context, state) => AuthGate(
        child: ArticlesScreen(
          articleId: state.pathParameters['id'],
          preview: suffix.contains('/preview'),
          focus: suffix.endsWith('/focus'),
        ),
      ),
    ),
  for (final suffix in ['', '/focus'])
    GoRoute(
      path: '/articles/:id$suffix',
      builder: (context, state) => AuthGate(
        child: ArticlesScreen(
          articleId: state.pathParameters['id'],
          reader: true,
          focus: suffix.isNotEmpty,
        ),
      ),
    ),
];
