import 'package:fixnum/fixnum.dart';

/// The largest generation or epoch the client holds: 2^53 - 1, the largest
/// integer a web number represents exactly. Anything above is refused.
const int kMaxPairComponent = 9007199254740991;

/// A conversation's (generation, epoch) position. Ordered by generation,
/// then epoch. Plain Dart ints, never 64-bit byte accessors (web).
class MlsPair implements Comparable<MlsPair> {
  const MlsPair(this.generation, this.epoch)
    : assert(generation >= 0 && generation <= kMaxPairComponent),
      assert(epoch >= 0 && epoch <= kMaxPairComponent);

  final int generation;
  final int epoch;

  /// The next epoch of the same generation.
  MlsPair get next => MlsPair(generation, epoch + 1);

  @override
  int compareTo(MlsPair other) {
    final g = generation.compareTo(other.generation);
    return g != 0 ? g : epoch.compareTo(other.epoch);
  }

  /// True when [pair] is above [mark]; an absent mark is below every pair.
  static bool above(MlsPair pair, MlsPair? mark) =>
      mark == null || pair.compareTo(mark) > 0;

  @override
  bool operator ==(Object other) =>
      other is MlsPair &&
      other.generation == generation &&
      other.epoch == epoch;

  @override
  int get hashCode => Object.hash(generation, epoch);

  @override
  String toString() => 'MlsPair($generation, $epoch)';
}

/// [v] as a pair component, or null when it is negative or above
/// [kMaxPairComponent].
int? pairComponentFromInt64(Int64 v) {
  if (v.isNegative) return null;
  if (v > Int64(kMaxPairComponent)) return null;
  return v.toInt();
}
