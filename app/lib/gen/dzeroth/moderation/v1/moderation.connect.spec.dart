//
//  Generated code. Do not modify.
//  source: dzeroth/moderation/v1/moderation.proto
//

import "package:connectrpc/connect.dart" as connect;
import "moderation.pb.dart" as dzerothmoderationv1moderation;

abstract final class ModerationService {
  /// Fully-qualified name of the ModerationService service.
  static const name = 'dzeroth.moderation.v1.ModerationService';

  /// Report a post or an account. Quota: 20 reports/day (quotas/{uid}, `reports` counter; 5/day for accounts younger
  /// than 24 h).
  /// target_type POST: target_id is a 19-digit post id; the post must be visible to the caller exactly as GetPost
  /// defines (missing, deleted, taken-down, blocked-author or non-ACTIVE-author => NOT_FOUND, one message for every
  /// cause). target_type ACCOUNT: target_id is a user id; visible exactly as GetProfile defines (missing, non-ACTIVE
  /// or blocked-the-caller => NOT_FOUND).
  /// Reporting your own post, account, message, list or community (one you own) => INVALID_ARGUMENT + VALIDATION field
  /// "target_id".
  /// note: optional, <= 500 code points after NFC and trim; control characters other than LF => VALIDATION "note".
  /// The report doc copies the reported post's text, author handle and media ids ("evidence"), so a later author
  /// delete does not destroy it. For target_type ACCOUNT the evidence is the profile as the reporter saw it: handle,
  /// display name, bio, location, website and avatar URL, copied from the profile
  /// the call already loads, so a link or image cannot be swapped before triage. While
  /// FEATURE_PROFILE_EXTRAS is globally off the reporter sees no website, so none is kept. Retention and access follow
  /// the post evidence: resolved + 90 days, never returned to any client.
  /// Idempotency: the report doc id is derived from (reporter, target_type, target_id), so the same reporter reporting
  /// the same target again is a success with already_reported=true, writing nothing and charging no quota, regardless of
  /// idempotency_key. idempotency_key (required, <= 64 chars) is still validated for contract uniformity.
  /// A new report creates the report doc and charges the quota; a replay does neither. No async work.
  static const reportContent = connect.Spec(
    '/$name/ReportContent',
    connect.StreamType.unary,
    dzerothmoderationv1moderation.ReportContentRequest.new,
    dzerothmoderationv1moderation.ReportContentResponse.new,
  );
}
