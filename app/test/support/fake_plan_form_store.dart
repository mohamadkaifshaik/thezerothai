import 'package:dzeroth/features/beacons/domain/plan_quick_start.dart';

/// An in-memory [PlanFormStore]: [saved] is what a restart would find.
class FakePlanFormStore implements PlanFormStore {
  FakePlanFormStore(this.saved);

  String? saved;
  Object? readError;
  Object? writeError;
  int reads = 0;
  final writes = <String>[];

  @override
  Future<String?> read() async {
    reads++;
    if (readError != null) throw readError!;
    return saved;
  }

  @override
  Future<void> write(String json) async {
    if (writeError != null) throw writeError!;
    writes.add(json);
    saved = json;
  }
}
