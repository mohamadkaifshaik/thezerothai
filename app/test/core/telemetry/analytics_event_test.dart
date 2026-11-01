import 'package:dzeroth/core/telemetry/analytics_event.dart';
import 'package:dzeroth/core/telemetry/usage_reporter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/recording_usage_analytics.dart';

void main() {
  test('post_created carries four fixed parameters: enum names and bools', () {
    const e = PostCreated(
      kind: PostKind.quote,
      media: PostMedia.gif,
      poll: false,
      scheduled: true,
    );
    expect(e.name, 'post_created');
    expect(e.parameters, {
      'kind': 'quote',
      'media': 'gif',
      'poll': 'false',
      'scheduled': 'true',
    });
  });

  test('follow and search_used carry one enum each', () {
    const follow = FollowMade(source: FollowSource.suggestions);
    expect(follow.name, 'follow');
    expect(follow.parameters, {'source': 'suggestions'});
    const search = SearchUsed(type: SearchType.hashtag);
    expect(search.name, 'search_used');
    expect(search.parameters, {'type': 'hashtag'});
  });

  test('every parameter value of every enum value is a plain word', () {
    final events = <AnalyticsEvent>[
      for (final k in PostKind.values)
        for (final m in PostMedia.values)
          PostCreated(kind: k, media: m, poll: true, scheduled: false),
      for (final s in FollowSource.values) FollowMade(source: s),
      for (final t in SearchType.values) SearchUsed(type: t),
    ];
    for (final e in events) {
      for (final v in e.parameters.values) {
        expect(v, matches(RegExp(r'^[a-z_]+$')));
      }
    }
  });

  test('the reporter forwards to the adapter and never throws', () async {
    final analytics = RecordingUsageAnalytics();
    UsageReporter.analytics(analytics)
        .log(const SearchUsed(type: SearchType.people));
    await Future<void>.value();
    expect(analytics.wire, ['search_used{type=people}']);

    final throwing = UsageReporter(
      log: (_) => throw StateError('boom'),
      screen: (_) async => throw StateError('boom'),
    );
    throwing.log(const SearchUsed(type: SearchType.people));
    throwing.screen('home');
    await Future<void>.value();
  });
}
