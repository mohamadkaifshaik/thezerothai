import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'app_avatar.dart';
import 'app_surface.dart';

/// The signed-in user's card at the top of the [AppSideColumn].
class AppSideProfile {
  const AppSideProfile({
    required this.displayName,
    required this.handle,
    required this.avatarUrl,
    required this.onTap,
  });

  final String displayName;

  /// Without the leading `@`.
  final String handle;
  final String avatarUrl;
  final VoidCallback onTap;
}

/// One quick link in the [AppSideColumn]; only for destinations that exist.
class AppSideLink {
  const AppSideLink({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

/// The right-hand column of the desktop shell: the viewer's own [profile] card
/// (omitted when null: nothing is fetched here), the [sections] a feature
/// adds, and a list of [links]. Purely presentational: it reads no state and
/// makes no call; the caller passes what is already loaded. Scrolls when it
/// does not fit.
class AppSideColumn extends StatelessWidget {
  const AppSideColumn({
    super.key,
    this.header,
    this.profile,
    this.sections = const [],
    required this.links,
  });

  /// A widget above everything else: the search pill (W4-18). Presentational
  /// like the rest; its own gating is the caller's (null draws nothing).
  final Widget? header;

  final AppSideProfile? profile;

  /// Self-contained cards between the profile card and the links, top to
  /// bottom ("You might like" today; W4 adds "What's happening"). Each one owns
  /// its data, its gating and its bottom margin (the `AppSpacing.md` gap), and
  /// hides itself when it has nothing to show, so an empty section leaves no
  /// gap.
  final List<Widget> sections;
  final List<AppSideLink> links;

  @override
  Widget build(BuildContext context) {
    final card = profile;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header != null) ...[
            header!,
            const SizedBox(height: AppSpacing.md),
          ],
          if (card != null) ...[
            _ProfileCard(profile: card),
            const SizedBox(height: AppSpacing.md),
          ],
          ...sections,
          if (links.isNotEmpty)
            AppSurface(
              padding: const EdgeInsets.all(AppSpacing.xs),
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  children: [for (final link in links) _LinkRow(link: link)],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.profile});

  final AppSideProfile profile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final name = profile.displayName.trim();
    return AppSurface(
      padding: EdgeInsets.zero,
      child: Semantics(
        button: true,
        label:
            'Your profile, ${name.isEmpty ? '' : '$name, '}@${profile.handle}',
        excludeSemantics: true,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            onTap: profile.onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: AppSpacing.minTapTarget,
              ),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Row(
                  children: [
                    AppAvatar(url: profile.avatarUrl, radius: AppSpacing.lg),
                    const SizedBox(width: AppSpacing.sm + AppSpacing.xs),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (name.isNotEmpty)
                            Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall,
                            ),
                          Text(
                            '@${profile.handle}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.link});

  final AppSideLink link;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      minTileHeight: AppSpacing.minTapTarget,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      leading: Icon(link.icon, color: colors.onSurfaceVariant),
      title: Text(link.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: link.onTap,
    );
  }
}
