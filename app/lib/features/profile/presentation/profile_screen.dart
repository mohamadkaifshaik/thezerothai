import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../graph/data/graph_repository.dart';
import '../../graph/presentation/graph_feature_flags.dart';
import '../../onboarding/data/identity_repository.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import 'bloc/profile_cubit.dart';
import 'bloc/profile_state.dart';
import 'widgets/profile_header.dart';

/// `GetProfile(handle | user_id)` + (when the graph flag is on) the viewer's
/// relationship, rendered as [ProfileHeader]. Posts are still a placeholder
/// (ADR-0008 D13: the posts/profile-timeline plan adds the tabs and body).
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key, this.handle, this.userId})
    : assert(
        (handle == null) != (userId == null),
        'ProfileScreen takes exactly one of handle or userId',
      );

  /// Opens the profile by `@handle` (typed links, own profile tab).
  final String? handle;

  /// Opens the profile by id (post cards, mentions): immune to handle
  /// changes, since ChangeHandle frees old handles for others to claim.
  final String? userId;

  @override
  Widget build(BuildContext context) {
    return BlocProvider<ProfileCubit>(
      key: ValueKey('profile-cubit-${userId ?? handle}'),
      create: (context) => ProfileCubit(
        identityRepository: context.read<IdentityRepository>(),
        graphRepository: context.read<GraphRepository>(),
        handle: handle,
        userId: userId,
        graphEnabled: graphEnabledSnapshot(context),
        ownUserId: context.read<OnboardingBloc>().state.profile?.userId,
      )..load(),
      child: const _ProfileView(),
    );
  }
}

class _ProfileView extends StatelessWidget {
  const _ProfileView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: BlocBuilder<ProfileCubit, ProfileState>(
          buildWhen: (a, b) => a.profile?.handle != b.profile?.handle,
          builder: (context, state) {
            final handle =
                state.profile?.handle ??
                context.read<ProfileCubit>().requestedHandle;
            return Text(handle == null || handle.isEmpty ? '' : '@$handle');
          },
        ),
      ),
      body: SafeArea(
        child: BlocBuilder<ProfileCubit, ProfileState>(
          builder: (context, state) {
            return switch (state.status) {
              ProfileStatus.loading => const Center(
                child: CircularProgressIndicator(),
              ),
              ProfileStatus.notFound => const AppErrorView(
                error: NotFoundException("This account doesn't exist."),
              ),
              ProfileStatus.error => AppErrorView(
                error: state.error!,
                onRetry: () => context.read<ProfileCubit>().load(),
              ),
              ProfileStatus.ready => _ReadyProfile(state: state),
            };
          },
        ),
      ),
    );
  }
}

class _ReadyProfile extends StatelessWidget {
  const _ReadyProfile({required this.state});

  final ProfileState state;

  @override
  Widget build(BuildContext context) {
    final profile = state.profile!;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Center the column and cap its width on wide screens, so the
        // header never stretches edge-to-edge on tablet/desktop
        // (`flutter-feature` skill: LayoutBuilder breakpoints).
        final isWide = constraints.maxWidth >= AppBreakpoints.mobile;
        return SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: isWide ? AppBreakpoints.mobile : double.infinity,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ProfileHeader(
                    profile: profile,
                    isOwnProfile: state.isOwnProfile,
                    graphEnabled: state.graphEnabled,
                    relationship: state.relationship,
                    onRelationshipChanged: (relationship) => context
                        .read<ProfileCubit>()
                        .relationshipChanged(relationship),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Text(
                      "This profile's posts are coming soon.",
                      style: Theme.of(context).textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
