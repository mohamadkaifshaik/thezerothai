import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/widgets/app_error_view.dart';
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

  @override
  Widget build(BuildContext context) {
    if (_resolving) {
      return Scaffold(
        appBar: AppBar(title: Text('@${widget.handle}')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final error = _resolveError;
    if (error != null) {
      return Scaffold(
        appBar: AppBar(title: Text('@${widget.handle}')),
        body: AppErrorView(error: error, onRetry: _resolveUserId),
      );
    }

    final userId = _resolvedUserId!;
    final graphRepository = context.read<GraphRepository>();
    return DefaultTabController(
      length: 2,
      initialIndex: widget.initialTab == GraphListTab.followers ? 0 : 1,
      child: Scaffold(
        appBar: AppBar(
          title: Text('@${widget.handle}'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Followers'),
              Tab(text: 'Following'),
            ],
          ),
        ),
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
