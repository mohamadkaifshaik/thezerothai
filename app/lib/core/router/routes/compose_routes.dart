import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../theme/app_theme.dart';
import '../../../features/auth/presentation/widgets/auth_gate.dart';
import '../../../features/posts/domain/reply_start.dart';
import '../../../features/posts/presentation/bloc/post_sender.dart'
    show PostEditSeed;
import '../../../features/posts/presentation/composer_route.dart';
import '../../../features/posts/presentation/composer_screen.dart';
import '../../../features/posts/presentation/drafts_screen.dart';
import '../../../features/posts/presentation/post_photo_screen.dart';
import '../../../features/posts/presentation/reply_composer_screen.dart';
import '../../../features/posts/presentation/scheduled_posts_screen.dart';
import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../app_router.dart';

/// The reply composer route; see [AppRouter.composeReplyRoute].
GoRoute buildComposeReplyRoute() => GoRoute(
  path: '/compose/reply/:id',
  pageBuilder: (context, state) => CustomTransitionPage<pb.PostView>(
    key: state.pageKey,
    opaque: false,
    barrierColor: context.appColors.scrim,
    transitionsBuilder: (context, animation, secondary, child) =>
        FadeTransition(opacity: animation, child: child),
    child: AuthGate(
      child: ComposerRouteFrame(
        pageKey: state.pageKey,
        reply: true,
        semanticLabel: 'Reply',
        // The page's barrier is the scrim.
        drawScrim: false,
        editor: ReplyComposerScreen(
          postId: state.pathParameters['id']!,
          start: ReplyStart.parse(state.uri.queryParameters['start']),
        ),
      ),
    ),
  ),
);

/// A post's full-screen photo viewer.
GoRoute postPhotoRoute() => GoRoute(
  path: '/post/:id/photo/:index',
  builder: (context, state) => AuthGate(
    child: PostPhotoScreen(
      postId: state.pathParameters['id']!,
      index: int.tryParse(state.pathParameters['index'] ?? '') ?? 0,
    ),
  ),
);

/// The post and quote composer route; see [AppRouter.composeRoute].
GoRoute buildComposeRoute() => GoRoute(
  path: AppRouter.composePath,
  pageBuilder: (context, state) {
    final quote = state.uri.queryParameters['quote'] ?? '';
    final draft = state.uri.queryParameters['draft'] ?? '';
    final community = state.uri.queryParameters['community'] ?? '';
    final quoteId = _postIdPattern.hasMatch(quote) ? quote : '';
    // A failed background post being edited (the status row's Edit).
    final seed = state.extra is PostEditSeed
        ? state.extra as PostEditSeed
        : null;
    final plan = seed?.beaconId ?? state.uri.queryParameters['plan'] ?? '';
    // Only a well-formed plan id (19 digits) attaches a plan, and never to a
    // quote (the server refuses the pair).
    final planId = quoteId.isEmpty && _postIdPattern.hasMatch(plan) ? plan : '';
    return ComposerPage<void>(
      // What go_router's default `MaterialPage` carried.
      key: state.pageKey,
      name: state.name ?? state.path,
      arguments: <String, String>{
        ...state.pathParameters,
        ...state.uri.queryParameters,
      },
      restorationId: state.pageKey.value,
      child: AuthGate(
        child: ComposerRouteFrame(
          pageKey: state.pageKey,
          reply: false,
          semanticLabel: quoteId.isEmpty ? 'New post' : 'Quote',
          editor: ComposerScreen(
            // Only a well-formed community id (19 digits) preselects
            // one.
            communityId: _postIdPattern.hasMatch(community) ? community : '',
            // Only a well-formed post id (19 digits) starts a quote.
            quoteOfPostId: quoteId,
            // Only a well-formed draft id (16 lower-case hex) opens a
            // draft; an unknown one starts a new post (it never adopts
            // the id).
            draftId: _draftIdPattern.hasMatch(draft) ? draft : '',
            quotePreview: state.extra is pb.EmbeddedPost
                ? state.extra as pb.EmbeddedPost
                : null,
            planId: planId,
            edit: seed,
            planPreview: planId.isNotEmpty && state.extra is pb.BeaconPreview
                ? state.extra as pb.BeaconPreview
                : null,
          ),
        ),
      ),
    );
  },
);

final _postIdPattern = RegExp(r'^\d{19}$');
final _draftIdPattern = RegExp(r'^[0-9a-f]{16}$');

/// Scheduled posts and drafts, full screen outside the shell so they can be
/// pushed over the composer.
List<RouteBase> draftRoutes() => [
  // Full-screen, outside the shell, so it can be pushed over the composer.
  GoRoute(
    path: AppRouter.scheduledPostsPath,
    builder: (context, state) => const AuthGate(child: ScheduledPostsScreen()),
  ),
  GoRoute(
    path: AppRouter.draftsPath,
    builder: (context, state) => AuthGate(
      child: DraftsScreen(
        scheduledTab: state.uri.queryParameters['tab'] == 'scheduled',
        pickMode: state.extra == true,
      ),
    ),
  ),
];
