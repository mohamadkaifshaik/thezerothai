import '../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../../gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import '../../beacons/domain/beacon_labels.dart' show activityLabel;
import '../../../gen/dzeroth/beacons/v1/beacons.pbenum.dart'
    show BeaconActivity;

/// Server flag `dm_suggestions` (`FEATURE_DM_SUGGESTIONS`) in
/// `GetMe.enabled_features`: the picker's "Suggested" section
/// (`ListMessageSuggestions`). It also needs `messaging`.
const kFeatureDmSuggestions = 'dm_suggestions';

/// The most suggestions the picker asks for (the server caps at 20).
const kMessageSuggestionsLimit = 10;

/// The short subtitle of a suggestion, or null for a reason this build does
/// not know (the row then shows no reason rather than a wrong one).
///
/// The proto carries the plan's activity, not its title, so a plan reads
/// "Met on a coffee plan" (a generic "Met on a plan" for Other or unknown).
String? messageSuggestionReason(pb.MessageSuggestion s) {
  switch (s.reason) {
    case MessageSuggestionReason.MESSAGE_SUGGESTION_REASON_RECENT_CONVERSATION:
      return 'Recent conversation';
    case MessageSuggestionReason.MESSAGE_SUGGESTION_REASON_MET_ON_PLAN:
      final a = s.planActivity;
      final known =
          a != BeaconActivity.BEACON_ACTIVITY_UNSPECIFIED &&
          a != BeaconActivity.BEACON_ACTIVITY_OTHER &&
          activityLabel(a) != 'Plan';
      return known
          ? 'Met on a ${activityLabel(a).toLowerCase()} plan'
          : 'Met on a plan';
    case MessageSuggestionReason.MESSAGE_SUGGESTION_REASON_MUTUAL_FOLLOW:
      return 'You follow each other';
    case MessageSuggestionReason.MESSAGE_SUGGESTION_REASON_COMMUNITY_MEMBER:
      final name = s.communityName.trim();
      return name.isEmpty ? 'In a community you joined' : 'In $name';
    default:
      return null;
  }
}
