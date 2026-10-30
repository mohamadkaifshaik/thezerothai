import 'package:connectrpc/connect.dart' as connect;
import 'package:fixnum/fixnum.dart' show Int64;
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/network/rate_limit_hold.dart';
import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/search/v1/search.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';
import '../../../support/messaging_fixtures.dart' show withDetail;

void main() {
  late Object Function(String procedure, Object input) answer;
  late FakeTransport transport;
  late RateLimitHold hold;
  late ConnectSearchRepository repo;

  setUp(() {
    answer = (_, _) => pb.SearchPeopleResponse();
    transport = FakeTransport((p, i) async => answer(p, i));
    hold = RateLimitHold();
    repo = ConnectSearchRepository(
      apiClient: ApiClient.withTransport(transport),
      rateLimitHold: hold,
    );
  });

  test('searchPeople maps the response and sends query and limit', () async {
    Object? seen;
    answer = (_, input) {
      seen = input;
      return pb.SearchPeopleResponse(unsupportedQuery: true);
    };
    final result = await repo.searchPeople('ab', limit: 3);
    expect(result.unsupportedQuery, isTrue);
    expect(result.users, isEmpty);
    final req = seen! as pb.SearchPeopleRequest;
    expect(req.query, 'ab');
    expect(req.limit, 3);
  });

  test(
    'searchPosts: empty token becomes null; tab and token are sent',
    () async {
      Object? seen;
      answer = (_, input) {
        seen = input;
        return pb.SearchPostsResponse(normalizedTag: 'go');
      };
      final page = await repo.searchPosts(
        '#Go',
        tab: pb.SearchTab.SEARCH_TAB_LATEST,
        pageToken: 'tok',
      );
      expect(page.nextPageToken, isNull);
      expect(page.normalizedTag, 'go');
      final req = seen! as pb.SearchPostsRequest;
      expect(req.tab, pb.SearchTab.SEARCH_TAB_LATEST);
      expect(req.pageToken, 'tok');
    },
  );

  test('getTrends: computedAt is null when unset', () async {
    answer = (_, _) => pb.GetTrendsResponse(
      trends: [pb.Trend(tag: 'go', postCount: Int64.ONE, rank: 1)],
    );
    final result = await repo.getTrends(prefix: 'g');
    expect(result.computedAt, isNull);
    expect(result.trends.single.tag, 'go');
  });

  group('error mapping', () {
    test('FEATURE_DISABLED -> SearchUnavailableException', () async {
      answer = (_, _) => throw withDetail(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        metadata: {'feature': 'search'},
      );
      await expectLater(
        repo.searchPeople('ab'),
        throwsA(
          isA<SearchUnavailableException>().having(
            (e) => e.feature,
            'feature',
            'search',
          ),
        ),
      );
    });

    test('VALIDATION -> SearchInvalidQueryException with the field', () async {
      answer = (_, _) => throw withDetail(
        connect.Code.invalidArgument,
        common.ErrorReason.ERROR_REASON_VALIDATION,
        metadata: {'field': 'query'},
      );
      await expectLater(
        repo.searchPeople('a'),
        throwsA(
          isA<SearchInvalidQueryException>().having(
            (e) => e.field,
            'field',
            'query',
          ),
        ),
      );
    });

    test('RATE_LIMITED -> SearchRateLimitedException, held, no RPC', () async {
      answer = (_, _) => throw withDetail(
        connect.Code.resourceExhausted,
        common.ErrorReason.ERROR_REASON_RATE_LIMITED,
        metadata: {'limit': 'search_daily'},
      );
      await expectLater(
        repo.searchPeople('ab'),
        throwsA(
          isA<SearchRateLimitedException>().having(
            (e) => e.isDaily,
            'isDaily',
            isTrue,
          ),
        ),
      );
      expect(transport.calledProcedures, hasLength(1));
      await expectLater(
        repo.getTrends(),
        throwsA(isA<SearchRateLimitedException>()),
      );
      expect(transport.calledProcedures, hasLength(1));
    });

    test('other errors pass through as AppException', () async {
      answer = (_, _) =>
          throw connect.ConnectException(connect.Code.unavailable, 'down');
      await expectLater(repo.searchPeople('ab'), throwsA(isA<AppException>()));
    });

    test('mapSearchError leaves unrelated objects alone', () {
      final other = StateError('x');
      expect(identical(mapSearchError(other), other), isTrue);
    });
  });
}
