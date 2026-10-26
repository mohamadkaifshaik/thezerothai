import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../../engagement/domain/engagement_feature_flag.dart';
import '../data/posts_repository.dart';
import '../domain/posts_feature_flag.dart';

/// Whether the viewer may START a quote (the repost sheet's "Quote" row and
/// `/compose?quote=<id>`; W2-11). All three must hold:
///
/// - `engagement` is in `GetMe.enabled_features` (the quote is a repost-style
///   action and the server derives it from engagement);
/// - `quotes` is in `GetMe.enabled_features` (`FEATURE_QUOTES`);
/// - the posts gate has not remembered a server FEATURE_DISABLED for `quotes`
///   this session (the server stays authoritative; `PostsFeatureGate`).
///
/// A non-reactive snapshot read, so it is safe after an `await` (the repost
/// sheet) and inside `build` of a route that is rebuilt on navigation.
/// Showing existing QUOTE/REPOST posts is never gated by it.
bool quoteCreationAllowed(BuildContext context) =>
    featureEnabledSnapshot(context, kFeatureEngagement) &&
    featureEnabledSnapshot(context, kPostsSubFeatureQuotes) &&
    context.read<PostsRepository>().subFeatureEnabled(kPostsSubFeatureQuotes);
