import 'package:flutter_test/flutter_test.dart';
import 'package:locman/core/geo.dart';

void main() {
  group('Place.normalizeCode', () {
    test('normalizes case and surrounding whitespace', () {
      expect(Place.normalizeCode('de'), 'DE');
      expect(Place.normalizeCode(' nl '), 'NL');
    });

    test('normalizes UK to ISO code GB', () {
      expect(Place.normalizeCode('UK'), 'GB');
    });

    test('rejects empty and non-country values', () {
      expect(Place.normalizeCode(null), isNull);
      expect(Place.normalizeCode(''), isNull);
      expect(Place.normalizeCode('--'), isNull);
      expect(Place.normalizeCode('XX'), isNull);
      expect(Place.normalizeCode('ZZ'), isNull);
      expect(Place.normalizeCode('Germany'), isNull);
      expect(Place.normalizeCode('D1'), isNull);
    });
  });
}
