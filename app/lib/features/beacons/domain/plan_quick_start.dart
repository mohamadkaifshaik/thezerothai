import '../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'beacons_feature_flag.dart';

/// The quick "when" choices of the create form. Each maps to a start inside
/// the server's window (5 minutes to 30 days ahead); [custom] opens the date
/// and time pickers.
enum PlanQuickStart {
  now('Now'),
  tonight('Tonight'),
  tomorrow('Tomorrow'),
  weekend('Weekend'),
  custom('Custom');

  const PlanQuickStart(this.label);
  final String label;
}

/// The start a quick choice means at [now]; null for [PlanQuickStart.custom]
/// and for a choice that has no sensible start right now (Tonight after
/// 18:45).
DateTime? quickStartFor(PlanQuickStart quick, DateTime now) {
  switch (quick) {
    case PlanQuickStart.now:
      // Ten minutes out, on the next 5-minute mark: clear of the 5-minute
      // minimum even if the user takes a moment to post.
      final base = now.add(const Duration(minutes: 10));
      final minutes = ((base.minute + 4) ~/ 5) * 5;
      return DateTime(base.year, base.month, base.day, base.hour, minutes);
    case PlanQuickStart.tonight:
      final start = DateTime(now.year, now.month, now.day, 19);
      return start.isAfter(now.add(const Duration(minutes: 15))) ? start : null;
    case PlanQuickStart.tomorrow:
      return DateTime(now.year, now.month, now.day + 1, 10);
    case PlanQuickStart.weekend:
      for (var i = 0; i < 8; i++) {
        final start = DateTime(now.year, now.month, now.day + i, 10);
        if (start.weekday >= DateTime.saturday &&
            start.isAfter(now.add(const Duration(minutes: 15)))) {
          return start;
        }
      }
      return null;
    case PlanQuickStart.custom:
      return null;
  }
}

/// The optional choices of the last plan this session created, applied as the
/// next form's defaults (kept in memory only: nothing is stored).
class PlanFormMemory {
  PlanFormMemory();

  /// The one the create screen uses.
  static final session = PlanFormMemory();

  int durationMinutes = 60;
  int openSpots = 3;
  pb.BeaconCost cost = pb.BeaconCost.BEACON_COST_FREE;
  pb.ChatPreference chat = pb.ChatPreference.CHAT_PREFERENCE_QUIET;

  /// A community id; null for Public.
  String? communityId;

  void reset() {
    durationMinutes = 60;
    openSpots = 3;
    cost = pb.BeaconCost.BEACON_COST_FREE;
    chat = pb.ChatPreference.CHAT_PREFERENCE_QUIET;
    communityId = null;
  }

  /// Keeps in-range values only.
  void remember({
    required int durationMinutes,
    required int openSpots,
    required pb.BeaconCost cost,
    required pb.ChatPreference chat,
    required String? communityId,
  }) {
    if (kBeaconDurations.contains(durationMinutes)) {
      this.durationMinutes = durationMinutes;
    }
    if (openSpots >= kBeaconMinSpots && openSpots <= kBeaconMaxSpots) {
      this.openSpots = openSpots;
    }
    this.cost = cost;
    this.chat = chat;
    this.communityId = communityId;
  }
}
