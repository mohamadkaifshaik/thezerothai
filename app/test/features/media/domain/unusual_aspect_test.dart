import 'package:dzeroth/features/media/domain/unusual_aspect.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  UnusualShape? shape(int w, int h, {bool gif = false}) =>
      unusualShapeOf(width: w, height: h, isGif: gif);

  test('the limit token is 20', () => expect(kUnusualAspectMax, 20));

  test('narrow: 1/19 and 1/20 are normal, 1/21 is unusual', () {
    expect(shape(100, 1900), isNull);
    expect(shape(100, 2000), isNull);
    expect(shape(100, 2100), UnusualShape.narrow);
    expect(shape(38, 2048), UnusualShape.narrow);
  });

  test('wide: 20 is normal, 21 is unusual', () {
    expect(shape(2000, 100), isNull);
    expect(shape(2100, 100), UnusualShape.wide);
  });

  test('ordinary and square photos are normal', () {
    expect(shape(800, 600), isNull);
    expect(shape(1080, 1350), isNull);
    expect(shape(500, 500), isNull);
  });

  test('a GIF is never unusual, nor an unknown size', () {
    expect(shape(38, 2048, gif: true), isNull);
    expect(shape(0, 2048), isNull);
    expect(shape(2048, 0), isNull);
  });
}
