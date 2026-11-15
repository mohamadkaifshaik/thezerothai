import 'package:dzeroth/features/creator_insights/data/creator_insights_repository.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as pb;
import 'package:fixnum/fixnum.dart';
import 'package:mocktail/mocktail.dart';

class MockCreatorInsightsRepository extends Mock
    implements CreatorInsightsRepository {}

/// A response over [days] days: impressions i, engagements 2i, one follower a
/// day gained and (on day 0) one lost. [pct] sets both change fields; null
/// leaves them absent.
pb.GetCreatorInsightsResponse insightsResponse({
  int days = 28,
  double? pct = 12.5,
  int impressions = 1200,
  int engagements = 340,
  int gained = 9,
  int lost = 2,
  List<pb.CreatorTopPost>? top,
}) {
  final r = pb.GetCreatorInsightsResponse(
    windowDays: days,
    current: pb.CreatorInsightsTotals(
      impressions: Int64(impressions),
      engagements: Int64(engagements),
      followersGained: Int64(gained),
      followersLost: Int64(lost),
    ),
    previous: pb.CreatorInsightsTotals(impressions: Int64(1000)),
    days: [
      for (var i = 0; i < days; i++)
        pb.CreatorInsightsDay(
          date: '2026110${i % 10}',
          impressions: Int64(i),
          engagements: Int64(i * 2),
          followersGained: Int64(1),
          followersLost: Int64(i == 0 ? 1 : 0),
        ),
    ],
    topPosts:
        top ??
        [
          pb.CreatorTopPost(
            postId: '1234567890123456789',
            text: 'My best post',
            viewCount: Int64(5400),
            likeCount: Int64(12),
            replyCount: Int64(1),
          ),
        ],
  );
  if (pct != null) {
    r.impressionsChangePct = pct;
    r.engagementsChangePct = pct;
  }
  return r;
}

pb.GetCreatorInsightsResponse emptyInsights() => pb.GetCreatorInsightsResponse(
  windowDays: 28,
  current: pb.CreatorInsightsTotals(),
  previous: pb.CreatorInsightsTotals(),
);
