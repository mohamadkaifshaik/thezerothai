import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart';

import '../../core/theme/app_theme.dart';
import '../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'post_card.dart';

/// One optimistic row for a post or reply being sent: the text in a dimmed
/// [PostCard] with "Posting..." under it. Used by [PendingPostsSection]
/// (Home / own profile) and the thread screen's reply in flight.
///
/// [author] is the viewer's snapshot (from the onboarding profile); without
/// it the row shows the placeholder avatar. Without [createdAt] no relative
/// time is shown.
class PendingPostRow extends StatelessWidget {
  const PendingPostRow({
    super.key,
    required this.text,
    this.author,
    this.createdAt,
    this.now,
    this.thumbnails = const [],
    this.semanticsLabel = 'Sending your post',
  });

  final String text;
  final common.AuthorSnapshot? author;
  final DateTime? createdAt;
  final DateTime? now;

  /// On-device previews of attached photos, shown small under the text.
  final List<Uint8List> thumbnails;

  /// Announced for the row; null leaves the card's own text and the
  /// "Posting..." line to speak for it.
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final snapshot = author ?? common.AuthorSnapshot();
    final created = createdAt;
    final row = Opacity(
      opacity: 0.6,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PostCard(
            view: pb.PostView(
              post: pb.Post(
                postId: '',
                text: text,
                author: snapshot,
                createdAt: created == null
                    ? null
                    : Timestamp.fromDateTime(created.toUtc()),
              ),
            ),
            viewerUserId: snapshot.userId,
            graphActionsEnabled: false,
            now: now,
          ),
          if (thumbnails.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(
                left: AppSpacing.md,
                bottom: AppSpacing.sm,
              ),
              child: Row(
                children: [
                  for (final bytes in thumbnails)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(
                        end: AppSpacing.sm,
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        child: ExcludeSemantics(
                          child: Image.memory(
                            bytes,
                            width: AppSpacing.xxl,
                            height: AppSpacing.xxl,
                            fit: BoxFit.cover,
                            cacheWidth:
                                (AppSpacing.xxl *
                                        MediaQuery.devicePixelRatioOf(context))
                                    .ceil(),
                            gaplessPlayback: true,
                            errorBuilder: (_, _, _) => const SizedBox.square(
                              dimension: AppSpacing.xxl,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.md,
              bottom: AppSpacing.sm,
            ),
            child: Text(
              thumbnails.isEmpty
                  ? 'Posting...'
                  : thumbnails.length == 1
                  ? 'Posting with 1 photo...'
                  : 'Posting with ${thumbnails.length} photos...',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ],
      ),
    );
    final label = semanticsLabel;
    return label == null ? row : Semantics(label: label, child: row);
  }
}
