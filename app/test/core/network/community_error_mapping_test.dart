import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/network/connect_error_mapper.dart';
import 'package:dzeroth/features/communities/domain/communities_feature_flag.dart';
import 'package:dzeroth/features/communities/presentation/communities_error_messages.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:flutter_test/flutter_test.dart';

import '../../support/posts_fixtures.dart';

/// FORBIDDEN and COMMUNITY_STATE are mapped by
/// `metadata["reason"]`; the other community refusals ride the existing
/// reasons and their metadata names.
void main() {
  CommunityForbiddenException forbidden(Map<String, String> metadata) =>
      mapConnectError(
        serverError(
          connect.Code.permissionDenied,
          common.ErrorReason.ERROR_REASON_FORBIDDEN,
          metadata: metadata,
        ),
      ) as CommunityForbiddenException;

  CommunityStateException state(Map<String, String> metadata) =>
      mapConnectError(
        serverError(
          connect.Code.failedPrecondition,
          common.ErrorReason.ERROR_REASON_COMMUNITY_STATE,
          metadata: metadata,
        ),
      ) as CommunityStateException;

  group('FORBIDDEN', () {
    const expected = {
      'banned': CommunityForbiddenReason.banned,
      'not_member': CommunityForbiddenReason.notMember,
      'not_moderator': CommunityForbiddenReason.notModerator,
      'not_owner': CommunityForbiddenReason.notOwner,
      'not_creator': CommunityForbiddenReason.notCreator,
    };
    for (final entry in expected.entries) {
      test('reason ${entry.key} -> ${entry.value.name}, fixed text', () {
        final e = forbidden({'reason': entry.key});
        expect(e.reason, entry.value);
        expect(e.message, entry.value.userMessage);
        expect(e.message, isNot(contains('server says no')));
        expect(e.message, isNot(contains('restricted')));
      });
    }

    test('every known reason has its own text', () {
      final texts = {
        for (final r in CommunityForbiddenReason.values) r.userMessage,
      };
      expect(texts, hasLength(CommunityForbiddenReason.values.length));
    });

    for (final metadata in <Map<String, String>>[
      {'reason': 'a_new_reason'},
      {'reason': ''},
      <String, String>{},
    ]) {
      test(
        'unknown reason $metadata -> safe generic, not AccountRestricted',
        () {
          final mapped = mapConnectError(
            serverError(
              connect.Code.permissionDenied,
              common.ErrorReason.ERROR_REASON_FORBIDDEN,
              metadata: metadata,
            ),
          );
          expect(mapped, isA<CommunityForbiddenException>());
          expect(mapped, isNot(isA<AccountRestrictedException>()));
          expect(
            (mapped as CommunityForbiddenException).reason,
            CommunityForbiddenReason.unknown,
          );
          expect(mapped.message, "You can't do that in this community.");
        },
      );
    }
  });

  group('COMMUNITY_STATE', () {
    const expected = {
      'owner': CommunityStateReason.owner,
      'moderator': CommunityStateReason.moderator,
      'community_archived': CommunityStateReason.communityArchived,
    };
    for (final entry in expected.entries) {
      test('reason ${entry.key} -> ${entry.value.name}, fixed text', () {
        final e = state({'reason': entry.key});
        expect(e.reason, entry.value);
        expect(e.message, entry.value.userMessage);
        expect(e.message, isNot(contains('server says no')));
      });
    }

    for (final metadata in <Map<String, String>>[
      {'reason': 'a_new_reason'},
      <String, String>{},
    ]) {
      test('unknown reason $metadata -> safe generic, not ProfileRequired', () {
        final mapped = mapConnectError(
          serverError(
            connect.Code.failedPrecondition,
            common.ErrorReason.ERROR_REASON_COMMUNITY_STATE,
            metadata: metadata,
          ),
        );
        expect(mapped, isA<CommunityStateException>());
        expect(mapped, isNot(isA<ProfileRequiredException>()));
        expect(
          (mapped as CommunityStateException).reason,
          CommunityStateReason.unknown,
        );
      });
    }
  });

  group('errors that did not change', () {
    test('PERMISSION_DENIED without a detail is still AccountRestricted', () {
      expect(
        mapConnectError(
          connect.ConnectException(connect.Code.permissionDenied, 'no'),
        ),
        isA<AccountRestrictedException>(),
      );
    });

    test('FAILED_PRECONDITION without a detail is still ProfileRequired', () {
      expect(
        mapConnectError(
          connect.ConnectException(connect.Code.failedPrecondition, 'no'),
        ),
        isA<ProfileRequiredException>(),
      );
    });

    test('ACCOUNT_RESTRICTED and PROFILE_REQUIRED keep their types', () {
      expect(
        mapConnectError(
          serverError(
            connect.Code.permissionDenied,
            common.ErrorReason.ERROR_REASON_ACCOUNT_RESTRICTED,
          ),
        ),
        isA<AccountRestrictedException>(),
      );
      expect(
        mapConnectError(
          serverError(
            connect.Code.failedPrecondition,
            common.ErrorReason.ERROR_REASON_PROFILE_REQUIRED,
          ),
        ),
        isA<ProfileRequiredException>(),
      );
    });
  });

  group('the other community refusals (ADR-0031 N6)', () {
    test('PROTECTED_ACCOUNT', () {
      final e = mapConnectError(
        serverError(
          connect.Code.failedPrecondition,
          common.ErrorReason.ERROR_REASON_PROTECTED_ACCOUNT,
        ),
      );
      expect(e, isA<ProtectedAccountException>());
      expect(
        communitiesErrorMessage(e),
        "Protected accounts can't post in communities.",
      );
    });

    for (final limit in [
      kCommunitiesOwnedLimit,
      kCommunitiesJoinedLimit,
      kCommunityModeratorsLimit,
    ]) {
      test('LIMIT_REACHED $limit', () {
        final e = mapConnectError(
          serverError(
            connect.Code.failedPrecondition,
            common.ErrorReason.ERROR_REASON_LIMIT_REACHED,
            metadata: {'limit': limit},
          ),
        ) as LimitReachedException;
        expect(e.quota, limit);
        expect(communitiesErrorMessage(e), isNot(contains('limit for this')));
      });
    }

    test('QUOTA_EXCEEDED reads as the generic daily limit', () {
      final e = mapConnectError(
        serverError(
          connect.Code.resourceExhausted,
          common.ErrorReason.ERROR_REASON_QUOTA_EXCEEDED,
          metadata: {'quota': 'reports'},
        ),
      ) as QuotaExceededException;
      expect(
        communitiesErrorMessage(e),
        "You've hit today's limit for this action. It resets tomorrow.",
      );
    });

    for (final limit in [
      kCommunityMutationDailyLimit,
      kCommunityModActionsDailyLimit,
      kCommunityPostsPerCommunityDailyLimit,
    ]) {
      test('RATE_LIMITED $limit is a daily limit', () {
        final e = mapConnectError(
          serverError(
            connect.Code.resourceExhausted,
            common.ErrorReason.ERROR_REASON_RATE_LIMITED,
            metadata: {'limit': limit},
          ),
        ) as RateLimitedException;
        expect(e.limitName, limit);
        expect(e.isDaily, isTrue);
      });
    }

    test('FEATURE_DISABLED names communities', () {
      final e = mapConnectError(
        serverError(
          connect.Code.failedPrecondition,
          common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
          metadata: {'feature': kFeatureCommunities},
        ),
      ) as FeatureDisabledException;
      expect(e.feature, 'communities');
      expect(communitiesErrorMessage(e), "Communities aren't available yet.");
    });

    test('NOT_FOUND has one fixed text', () {
      final e = mapConnectError(
        connect.ConnectException(connect.Code.notFound, 'community not found'),
      );
      expect(e, isA<NotFoundException>());
      expect(
        communitiesErrorMessage(e),
        'This community is unavailable.',
      );
    });
  });

  group('communitiesErrorMessage', () {
    test('uses the fixed text of FORBIDDEN and COMMUNITY_STATE reasons', () {
      expect(
        communitiesErrorMessage(
          CommunityForbiddenException(CommunityForbiddenReason.banned),
        ),
        "You're banned from this community.",
      );
      expect(
        communitiesErrorMessage(
          CommunityStateException(CommunityStateReason.communityArchived),
        ),
        'This community is archived, so it is read-only.',
      );
    });

    test('an unrelated error is the generic last line', () {
      expect(
        communitiesErrorMessage(const UnknownApiException('boom')),
        'Something went wrong. Please try again.',
      );
      expect(
        communitiesErrorMessage(const AccountRestrictedException('x')),
        'Something went wrong. Please try again.',
      );
    });
  });
}
