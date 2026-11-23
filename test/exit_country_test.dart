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

  group('confirmed country lock', () {
    test('does not infer a lock from an unverified node name', () {
      expect(confirmedCountryLock(enabled: true, locked: null, activeExit: null), isNull);
    });

    test('uses the explicit lock before the active exit observation', () {
      expect(
        confirmedCountryLock(enabled: true, locked: ' de ', activeExit: 'NL'),
        'DE',
      );
    });

    test('uses only a normalized, confirmed active exit when no lock exists', () {
      expect(confirmedCountryLock(enabled: true, locked: null, activeExit: ' nl '), 'NL');
      expect(confirmedCountryLock(enabled: true, locked: null, activeExit: 'unknown'), isNull);
    });

    test('does not constrain routing when the feature is disabled', () {
      expect(confirmedCountryLock(enabled: false, locked: 'DE', activeExit: 'NL'), isNull);
    });
  });
}
