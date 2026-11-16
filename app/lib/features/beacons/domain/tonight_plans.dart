import '../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;

/// The local hour at which "tonight" ends: a plan starting before 04:00 the
/// next morning still belongs to the evening that began the day before.
const kTonightEndsAtHour = 4;

/// The end of "tonight" for a viewer whose clock reads [now] (device local
/// time): 04:00 today while it is earlier than that (after midnight), else
/// 04:00 tomorrow.
DateTime tonightCutoff(DateTime now) {
  final local = now.toLocal();
  final today = DateTime(
    local.year,
    local.month,
    local.day,
    kTonightEndsAtHour,
  );
  return local.isBefore(today)
      ? today
      : DateTime(local.year, local.month, local.day + 1, kTonightEndsAtHour);
}

/// How many plans start tonight, and whether that is "at least" that many.
class TonightCount {
  const TonightCount(this.count, {this.atLeast = false});

  final int count;

  /// The page was full and every row of it is tonight (rows come ordered by
  /// start), so more may follow: shown as "N+".
  final bool atLeast;

  /// "14 plans", "20+ plans", "1 plan".
  String get phrase =>
      '$count${atLeast ? '+' : ''} '
      '${count == 1 && !atLeast ? 'plan' : 'plans'}';

  @override
  bool operator ==(Object other) =>
      other is TonightCount && other.count == count && other.atLeast == atLeast;

  @override
  int get hashCode => Object.hash(count, atLeast);
}

/// Counts the plans of a first Nearby page that are on tonight: not
/// cancelled or ended (the server's status; ENDED is never derived from the
/// clock here), and starting before [tonightCutoff]. A plan already under
/// way counts: it is on, and has not ended. [pageSize] is the limit the page
/// was asked with.
TonightCount countTonightPlans(
  List<pb.NearbyBeacon> items, {
  required DateTime now,
  required int pageSize,
}) {
  final cutoff = tonightCutoff(now);
  var tonight = 0;
  for (final item in items) {
    final b = item.view.beacon;
    if (b.status == pb.BeaconStatus.BEACON_STATUS_CANCELLED ||
        b.status == pb.BeaconStatus.BEACON_STATUS_ENDED) {
      continue;
    }
    if (b.startAt.toDateTime().toLocal().isBefore(cutoff)) tonight++;
  }
  final full = items.length >= pageSize;
  return TonightCount(tonight, atLeast: full && tonight == items.length);
}
