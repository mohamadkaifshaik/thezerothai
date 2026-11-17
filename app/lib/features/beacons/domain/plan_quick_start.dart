import 'dart:async';
import 'dart:convert';

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

/// Where [PlanFormMemory] keeps its choices between launches. The app's
/// implementation is the drift settings table (`DatabasePlanFormStore`).
abstract class PlanFormStore {
  /// The saved JSON text; null when nothing was saved.
  Future<String?> read();

  /// Saves [json] for the signed-in account.
  Future<void> write(String json);
}

/// The settings key of the saved choices. Versioned in the key and in the
/// payload; the `account:` prefix makes sign-out and an account switch wipe it.
const kPlanFormMemoryKey = 'account:plans.form_memory.v1';
const _kVersion = 1;

/// The optional choices of the last plan created, applied as the next form's
/// defaults. Kept in memory and, with a [PlanFormStore] bound, across app
/// restarts (duration, spots, cost, chat and community audience only: never
/// the activity, title, place or time).
class PlanFormMemory {
  PlanFormMemory({PlanFormStore? store}) : _store = store;

  /// The one the create screen uses.
  static final session = PlanFormMemory();

  PlanFormStore? _store;
  Future<void>? _loading;
  var _generation = 0;
  var _loadDone = false;

  int durationMinutes = 60;
  int openSpots = 3;
  pb.BeaconCost cost = pb.BeaconCost.BEACON_COST_FREE;
  pb.ChatPreference chat = pb.ChatPreference.CHAT_PREFERENCE_QUIET;

  /// A community id; null for Public.
  String? communityId;

  /// Whether the saved choices were read (true when there is no store).
  bool get loaded => _store == null || _loadDone;

  /// Starts keeping choices in [store]; forgets what an earlier one loaded.
  void bind(PlanFormStore store) {
    _store = store;
    forget();
  }

  /// Stops keeping choices (app teardown); memory only again.
  void unbind() {
    _store = null;
    forget();
  }

  /// Back to the defaults and not loaded: the next [ensureLoaded] reads the
  /// store again. For sign-out and an account switch.
  void forget() {
    _generation++;
    _loading = null;
    _loadDone = false;
    reset();
  }

  /// Reads the saved choices once. Corrupt, missing or foreign-version data
  /// leaves the defaults; it never throws. A [forget] while it reads drops
  /// the result.
  Future<void> ensureLoaded() {
    final store = _store;
    if (store == null) return Future.value();
    return _loading ??= _load(store, _generation);
  }

  Future<void> _load(PlanFormStore store, int generation) async {
    String? raw;
    try {
      raw = await store.read();
    } on Object {
      raw = null;
    }
    if (generation != _generation) return;
    _loadDone = true;
    if (raw == null) return;
    try {
      final json = jsonDecode(raw);
      if (json is! Map || json['v'] != _kVersion) return;
      final costValue = json['cost'];
      final chatValue = json['chat'];
      final parsedCost = costValue is int
          ? pb.BeaconCost.valueOf(costValue)
          : null;
      final parsedChat = chatValue is int
          ? pb.ChatPreference.valueOf(chatValue)
          : null;
      final duration = json['duration'];
      final spots = json['spots'];
      final community = json['community'];
      remember(
        durationMinutes: duration is int ? duration : durationMinutes,
        openSpots: spots is int ? spots : openSpots,
        cost:
            parsedCost == null ||
                parsedCost == pb.BeaconCost.BEACON_COST_UNSPECIFIED
            ? cost
            : parsedCost,
        chat:
            parsedChat == null ||
                parsedChat == pb.ChatPreference.CHAT_PREFERENCE_UNSPECIFIED
            ? chat
            : parsedChat,
        communityId: community is String && community.isNotEmpty
            ? community
            : null,
      );
    } on Object {
      // Corrupt: keep the defaults.
    }
  }

  void reset() {
    durationMinutes = 60;
    openSpots = 3;
    cost = pb.BeaconCost.BEACON_COST_FREE;
    chat = pb.ChatPreference.CHAT_PREFERENCE_QUIET;
    communityId = null;
  }

  /// Keeps in-range values only, and with [save] writes them to the bound
  /// store (not awaited; a failed save is dropped).
  void remember({
    required int durationMinutes,
    required int openSpots,
    required pb.BeaconCost cost,
    required pb.ChatPreference chat,
    required String? communityId,
    bool save = false,
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
    final store = _store;
    if (!save || store == null) return;
    final json = jsonEncode({
      'v': _kVersion,
      'duration': this.durationMinutes,
      'spots': this.openSpots,
      'cost': this.cost.value,
      'chat': this.chat.value,
      'community': this.communityId,
    });
    // A save the user made counts as loaded: later reads must not overwrite.
    _loadDone = true;
    _loading ??= Future.value();
    unawaited(
      store.write(json).catchError((Object _) {
        // Not remembered; the plan itself is unaffected.
      }),
    );
  }
}
