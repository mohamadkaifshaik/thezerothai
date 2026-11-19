import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pairs order by generation, then epoch', () {
    expect(const MlsPair(1, 9).compareTo(const MlsPair(2, 0)), lessThan(0));
    expect(const MlsPair(2, 1).compareTo(const MlsPair(2, 3)), lessThan(0));
    expect(const MlsPair(2, 3).compareTo(const MlsPair(2, 3)), 0);
    expect(const MlsPair(3, 0).compareTo(const MlsPair(2, 99)), greaterThan(0));
    expect(const MlsPair(2, 3), const MlsPair(2, 3));
    expect(const MlsPair(2, 3).hashCode, const MlsPair(2, 3).hashCode);
    expect(const MlsPair(2, 3).next, const MlsPair(2, 4));
  });

  test('above(p, null) is true: an absent mark is below every pair', () {
    expect(MlsPair.above(const MlsPair(0, 0), null), isTrue);
    expect(MlsPair.above(const MlsPair(1, 1), const MlsPair(1, 1)), isFalse);
    expect(MlsPair.above(const MlsPair(1, 2), const MlsPair(1, 1)), isTrue);
    expect(MlsPair.above(const MlsPair(1, 0), const MlsPair(1, 1)), isFalse);
  });

  test('toString prints only the numbers', () {
    expect(const MlsPair(4, 5).toString(), 'MlsPair(4, 5)');
  });

  test('a component above the web-safe maximum is refused', () {
    expect(
      () => MlsPair(0, kMaxPairComponent + 1),
      throwsA(isA<AssertionError>()),
    );
    expect(() => MlsPair(-1, 0), throwsA(isA<AssertionError>()));
  });

  test('pairComponentFromInt64(Int64(-1)) == null; above the maximum too', () {
    expect(pairComponentFromInt64(Int64(-1)), isNull);
    expect(pairComponentFromInt64(Int64(kMaxPairComponent) + 1), isNull);
    expect(pairComponentFromInt64(Int64(kMaxPairComponent)), kMaxPairComponent);
    expect(pairComponentFromInt64(Int64.ZERO), 0);
  });
}
