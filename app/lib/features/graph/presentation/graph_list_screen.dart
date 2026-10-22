import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../shared/widgets/app_back_header.dart';
import '../../../shared/widgets/app_main_column.dart';
import '../../onboarding/data/identity_repository.dart';
import '../data/graph_repository.dart';
import 'bloc/user_list_cubit.dart';
import 'widgets/paged_user_list.dart';

enum GraphListTab { followers, following }

/// `/profile/:handle/followers` and `/profile/:handle/following`: one
/// screen, two tabs. The target's uid is normally passed via route `extra`
/// (the caller already has it, e.g. from `ProfileHeader`); if not, this
/// screen resolves it with one `GetProfile(handle)` call.
class GraphListScreen extends StatefulWidget {
  const GraphListScreen({
    super.key,
    required this.handle,
    this.userId,
    this.initialTab = GraphListTab.followers,
  });

  final String handle;
  final String? userId;
  final GraphListTab initialTab;

  @override
  State<GraphListScreen> createState() => _GraphListScreenState();
}

class _GraphListScreenState extends State<GraphListScreen> {
  String? _resolvedUserId;
  AppException? _resolveError;
  bool _resolving = true;

  @override
  void initState() {
    super.initState();
    if (widget.userId != null) {
      _resolvedUserId = widget.userId;
      _resolving = false;
    } else {
      _resolveUserId();
    }
  }

  Future<void> _resolveUserId() async {
    setState(() {
      _resolving = true;
      _resolveError = null;
    });
    try {
      final profile = await context.read<IdentityRepository>().getProfile(
        handle: widget.handle,
      );
      if (!mounted) return;
      setState(() {
        _resolvedUserId = profile.userId;
        _resolving = false;
      });
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() {
        _resolveError = e;
        _resolving = false;
      });
    }
  }

  /// Back to where the user came from; with no history (a deep link) to
  /// the profile whose people these are.
  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.profilePath(widget.handle));
    }
  }

  /// The page frame: main-column width, the back header and [body].
  Widget _frame({required Widget body, Widget? tabs}) {
    return Scaffold(
      body: SafeArea(
        child: AppMainColumn(
          child: Column(
            children: [
              AppBackHeader(title: '@${widget.handle}', onBack: _back),
              ?tabs,
              Expanded(child: body),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_resolving) {
      return _frame(body: const Center(child: CircularProgressIndicator()));
    }
    final error = _resolveError;
    if (error != null) {
      return _frame(
        body: AppErrorView(error: error, onRetry: _resolveUserId),
      );
    }

    final userId = _resolvedUserId!;
    final graphRepository = context.read<GraphRepository>();
    return DefaultTabController(
      length: 2,
      initialIndex: widget.initialTab == GraphListTab.followers ? 0 : 1,
      child: _frame(
        tabs: const _GraphTabBar(),
        body: TabBarView(
          children: [
            _GraphTab(
              key: ValueKey('followers-$userId'),
              emptyMessage: 'No followers yet.',
              fetchPage: ({required pageSize, required pageToken}) =>
                  graphRepository.listFollowers(
                    userId: userId,
                    pageSize: pageSize,
                    pageToken: pageToken,
                  ),
            ),
            _GraphTab(
              key: ValueKey('following-$userId'),
              emptyMessage: 'Not following anyone yet.',
              fetchPage: ({required pageSize, required pageToken}) =>
                  graphRepository.listFollowing(
                    userId: userId,
                    pageSize: pageSize,
                    pageToken: pageToken,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The Followers / Following switch. The selected tab is told apart by more
/// than colour: a bold label and a primary underline (the tab itself is
/// announced as selected).
class _GraphTabBar extends StatelessWidget {
  const _GraphTabBar();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TabBar(
      tabs: const [
        Tab(text: 'Followers'),
        Tab(text: 'Following'),
      ],
      labelColor: theme.colorScheme.onSurface,
      unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
      labelStyle: theme.textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w800,
      ),
      unselectedLabelStyle: theme.textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w500,
      ),
      indicatorColor: theme.colorScheme.primary,
      indicatorWeight: AppSpacing.xs,
      indicatorSize: TabBarIndicatorSize.tab,
      dividerColor: theme.colorScheme.outlineVariant,
      dividerHeight: 1,
    );
  }
}

/// One tab's list. Owns its [UserListCubit] (created on first build, so the
/// off-screen tab costs no request until it is opened, and closed on
/// dispose). Tabs stay alive so loaded pages are never refetched in-session.
class _GraphTab extends StatefulWidget {
  const _GraphTab({
    super.key,
    required this.fetchPage,
    required this.emptyMessage,
  });

  final FetchGraphPage fetchPage;
  final String emptyMessage;

  @override
  State<_GraphTab> createState() => _GraphTabState();
}

class _GraphTabState extends State<_GraphTab>
    with AutomaticKeepAliveClientMixin {
  late final UserListCubit _cubit = UserListCubit(fetchPage: widget.fetchPage)
    ..loadFirstPage();

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _cubit.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return PagedUserList(cubit: _cubit, emptyMessage: widget.emptyMessage);
  }
}
